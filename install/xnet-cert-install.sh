#!/usr/bin/env bash
# ============================================================
#  xnet-cert-install — privileged helper that copies a Let's Encrypt
#  certificate from /etc/letsencrypt/live/<domain>/ into the panel's
#  cert directory (/etc/xnet/certs/<domain>.{crt,key}) with the right
#  ownership/permissions so the panel's dual-protocol TLS server can read
#  and serve it by SNI.
#
#  The panel (running as the unprivileged "xnet" user) cannot read
#  /etc/letsencrypt/live (root-only, mode 0700), so this step must run as
#  root. install.sh grants a NOPASSWD sudoers rule for exactly this script.
#
#  Usage:   sudo -n /opt/xnet/xnet-cert-install <domain>
#           sudo -n /opt/xnet/xnet-cert-install --remove <domain>
#           sudo -n /opt/xnet/xnet-cert-install --import <domain> <cert> <key>
#
#  --import installs a cert/key pair the panel already holds on disk, rather
#  than one certbot just issued. Two flows need it and neither can write to
#  $DEST directly (it is root-owned, and the panel is unprivileged):
#    * a manual upload of a cert/key pair the operator obtained elsewhere;
#    * a backup restore, which carries the PEMs in the archive.
#  Without it a restored panel had its certificate ROWS but none of the files,
#  so TLS silently fell back to nothing.
# ============================================================
set -uo pipefail

DEST="/etc/xnet/certs"
SERVICE_USER="xnet"

log() { echo "[xnet-cert-install] $*"; }

# Validate domain: letters, digits, dots, hyphens only (no path traversal).
valid_domain() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$1" != *".."* ]]
}

if [ "${1:-}" = "--remove" ]; then
  domain="${2:-}"
  if [ -z "$domain" ] || ! valid_domain "$domain"; then
    log "invalid domain"; exit 2
  fi
  # 1) Remove the panel-served copies.
  rm -f "$DEST/$domain.crt" "$DEST/$domain.key"
  log "removed $domain cert/key from $DEST"
  # 2) Fully delete the Let's Encrypt lineage (live/archive/renewal config) so no
  #    issued SSL files remain on the server. Best-effort; certbot may be absent.
  if command -v certbot >/dev/null 2>&1; then
    if certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1; then
      log "certbot lineage deleted for $domain"
    else
      log "certbot delete found no lineage for $domain (or already removed)"
    fi
  fi
  # 3) Defensive cleanup of any leftover letsencrypt dirs for this domain.
  rm -rf "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain" "/etc/letsencrypt/renewal/$domain.conf" 2>/dev/null || true
  log "fully removed all SSL files for $domain"
  exit 0
fi

if [ "${1:-}" = "--import" ]; then
  domain="${2:-}"
  src_cert="${3:-}"
  src_key="${4:-}"
  if [ -z "$domain" ] || ! valid_domain "$domain"; then
    log "invalid domain"; exit 2
  fi
  if [ ! -f "$src_cert" ] || [ ! -f "$src_key" ]; then
    log "source cert/key not found ($src_cert, $src_key)"; exit 3
  fi
  # Verify the pair actually belongs together before overwriting a working
  # certificate. Installing a mismatched pair takes TLS down for the domain,
  # and the failure only shows up on the next handshake — long after the
  # operator has moved on. openssl may be absent on a minimal box, in which
  # case we install without the check rather than refusing outright.
  #
  # The comparison is on the PUBLIC KEY, not on the RSA modulus. Modulus only
  # exists for RSA: on an ECDSA certificate `openssl x509 -modulus` fails, and
  # because its empty output was piped into `openssl md5` the failure came back
  # as a perfectly valid-looking hash of nothing. That defeated the emptiness
  # guards and rejected every EC pair as "certificate and key do not match" —
  # including correct ones, which is what most CAs now issue by default.
  # -pubkey/-pubout are algorithm-agnostic and behave the same for RSA, EC and
  # Ed25519.
  if command -v openssl >/dev/null 2>&1; then
    cert_pub="$(openssl x509 -noout -pubkey -in "$src_cert" 2>/dev/null)"
    key_pub="$(openssl pkey -pubout -in "$src_key" 2>/dev/null)"
    if [ -z "$cert_pub" ]; then
      log "certificate is not a readable X.509 PEM"; exit 4
    fi
    # An unreadable key (encrypted, or a format this openssl build cannot load)
    # yields no public key. That is not evidence of a mismatch, so it is not
    # treated as one — the panel already verified the pair with Go's
    # tls.X509KeyPair before calling us, and refusing here would block a
    # legitimate certificate on a tooling quirk.
    if [ -n "$key_pub" ] && [ "$cert_pub" != "$key_pub" ]; then
      log "certificate and key do not match"; exit 5
    fi
  fi
  mkdir -p "$DEST"
  install -m 0644 "$src_cert" "$DEST/$domain.crt"
  install -m 0640 "$src_key"  "$DEST/$domain.key"
  chown "${SERVICE_USER}:${SERVICE_USER}" "$DEST/$domain.crt" "$DEST/$domain.key" 2>/dev/null || true
  log "imported $domain -> $DEST/$domain.{crt,key}"
  exit 0
fi

domain="${1:-}"
if [ -z "$domain" ] || ! valid_domain "$domain"; then
  log "usage: xnet-cert-install <domain> | --remove <domain> | --import <domain> <cert> <key>"; exit 2
fi

LIVE="/etc/letsencrypt/live/$domain"
if [ ! -f "$LIVE/fullchain.pem" ] || [ ! -f "$LIVE/privkey.pem" ]; then
  log "certificate not found at $LIVE"; exit 3
fi

mkdir -p "$DEST"
install -m 0644 "$LIVE/fullchain.pem" "$DEST/$domain.crt"
install -m 0640 "$LIVE/privkey.pem"  "$DEST/$domain.key"
chown "${SERVICE_USER}:${SERVICE_USER}" "$DEST/$domain.crt" "$DEST/$domain.key" 2>/dev/null || true
log "installed $domain -> $DEST/$domain.{crt,key}"
exit 0
