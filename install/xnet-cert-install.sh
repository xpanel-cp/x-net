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

domain="${1:-}"
if [ -z "$domain" ] || ! valid_domain "$domain"; then
  log "usage: xnet-cert-install <domain> | --remove <domain>"; exit 2
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
