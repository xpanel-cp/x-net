#!/usr/bin/env bash
# xnet-fix-banner.sh — make the SSH banner show each account's stats block, on
# an existing server, without waiting for a full panel upgrade.
#
# THE SYMPTOM: the text set in Advanced Settings → SSH global settings appears on
# login, but the block under it (Account / Expiry / Used / Traffic / Max Conn)
# never does.
#
# THE CAUSE: every earlier attempt printed that block into the SESSION — through
# a ForceCommand wrapper, /etc/ssh/sshrc, a PAM hook or /etc/profile.d. SSH-tunnel
# clients (HTTP Injector, NPV Tunnel, SocksIP) never open a session channel and
# never display session output, so none of it could ever reach them. What they DO
# display is the pre-auth banner — that is why the admin's text works.
#
# THE FIX: put the block in the banner. sshd can serve a different Banner per
# user via `Match User`, and it evaluates that match before sending the banner,
# so each account gets a file containing the admin's text plus its own stats.
# Same channel as the text that already works, therefore same reach: every
# protocol, every client.
#
# Run as root on the server, from the directory holding xnet-ssh-info:
#   bash xnet-fix-banner.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/xnet"
BANNER_FILE="/etc/ssh/xnet-banner.txt"
BANNER_DIR="/etc/ssh/xnet-banners"
INFO_SCRIPT="${INSTALL_DIR}/xnet-ssh-info"
GREET_SCRIPT="${INSTALL_DIR}/xnet-ssh-greet"
PROFILE_SCRIPT="/etc/profile.d/xnet-ssh-info.sh"
SSHRC="/etc/ssh/sshrc"
SUDOERS_FILE="/etc/sudoers.d/xnet-ssh-info"

[ "$(id -u)" = "0" ] || { echo "[xnet-fix-banner] must run as root"; exit 1; }

say() { echo "[xnet-fix-banner] $*"; }

say "========================================"
say "Step 1: install the stats helper"
if [ -f "${SCRIPT_DIR}/xnet-ssh-info" ]; then
  install -m 0755 "${SCRIPT_DIR}/xnet-ssh-info" "$INFO_SCRIPT"
  sed -i 's/\r$//' "$INFO_SCRIPT" 2>/dev/null || true
  chown root:root "$INFO_SCRIPT"; chmod 0755 "$INFO_SCRIPT"
  say "  installed $INFO_SCRIPT from ${SCRIPT_DIR}/xnet-ssh-info ✓"
elif grep -qs 'XNET_SSH_INFO_VERSION=2' "$INFO_SCRIPT"; then
  say "  $INFO_SCRIPT is already current ✓"
else
  say "  ERROR: xnet-ssh-info not found next to this script and the installed copy"
  say "         is outdated. Copy install/xnet-ssh-info to $INFO_SCRIPT and re-run."
  exit 1
fi

say ""
say "Step 2: trim the banner text"
if [ -f "$BANNER_FILE" ]; then
  trimmed="$(python3 -c "import io,sys; sys.stdout.write(io.open('$BANNER_FILE',encoding='utf-8',errors='replace').read().strip())")"
  if [ -z "$trimmed" ]; then
    say "  empty after strip — removing (banner disabled)"
    rm -f "$BANNER_FILE"
  else
    printf '%s\n' "$trimmed" > "$BANNER_FILE"
    chmod 644 "$BANNER_FILE"
    say "  trimmed OK: $(wc -l < "$BANNER_FILE") lines"
  fi
else
  say "  no banner file — set a banner in the panel first, then re-run"
fi

say ""
say "Step 3: retire the old session hooks"
for cfg in /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns; do
  [ -f "$cfg" ] || continue
  grep -qF "xnet-fc" "$cfg" || continue
  # Restore the plain /bin/cat these instances are configured with. Deleting the
  # line outright would leave them with no ForceCommand at all, handing
  # tunnel-only accounts a real interactive shell.
  sed -i -E 's|^[#[:space:]]*ForceCommand[[:space:]].*|ForceCommand /bin/cat|I' "$cfg"
  say "  $cfg: ForceCommand restored to /bin/cat"
done
if [ -f /etc/pam.d/dropbear ] && grep -qF "xnet-fc-pam" /etc/pam.d/dropbear; then
  sed -i '/xnet-fc-pam/d' /etc/pam.d/dropbear
  say "  /etc/pam.d/dropbear: pam_exec hook removed"
fi
if [ -f "$SSHRC" ]; then
  if grep -qF "xnet-managed-sshrc" "$SSHRC"; then
    rm -f "$SSHRC"; say "  $SSHRC removed (superseded by per-account banners)"
  elif grep -qF "xnet-ssh-greet" "$SSHRC"; then
    sed -i '/xnet-ssh-greet/d;/# xnet: per-account stats on login/d' "$SSHRC"
    say "  xnet hook removed from your existing $SSHRC"
  fi
fi
rm -f "${INSTALL_DIR}/xnet-fc" "${INSTALL_DIR}/xnet-fc-pam"
say "  done ✓"

say ""
say "Step 4: install the Dropbear hook (OpenSSH does not need one)"
cat > "$GREET_SCRIPT" <<'SHEOF'
#!/bin/sh
# xnet-ssh-greet — print the current SSH account's stats block on stdout.
# Callers redirect to stderr; see /etc/profile.d/xnet-ssh-info.sh.
INFO=/opt/xnet/xnet-ssh-info

# Dropbear sets LOGNAME for every session; $USER is not set on all distros, and
# `id -un` is the last resort.
_u="${1:-}"
[ -n "$_u" ] || _u="${LOGNAME:-${USER:-$(id -un 2>/dev/null)}}"
[ -n "$_u" ] || exit 0
[ "$_u" = "root" ] && exit 0

if [ "$(id -u)" = "0" ]; then
  [ -x "$INFO" ] || exit 0
  "$INFO" "$_u" stdout 2>/dev/null
else
  # Deliberately NOT gated on an -x test here: that test would run as the SSH
  # account, which may not be able to stat /opt/xnet at all, and failing it would
  # skip the sudo call that would have succeeded. Let sudo be the one to decide.
  #
  # Needs /etc/sudoers.d/xnet-ssh-info. sudo's own diagnostics are dropped so a
  # misconfiguration cannot corrupt a tunnel's stream; the reason goes to syslog.
  sudo -n "$INFO" "$_u" stdout 2>/dev/null || {
    command -v logger >/dev/null 2>&1 && logger -t xnet-ssh-greet -p authpriv.warning \
      "sudo -n $INFO failed for $_u — check /etc/sudoers.d/xnet-ssh-info"
  }
fi
exit 0
SHEOF
chown root:root "$GREET_SCRIPT"; chmod 0755 "$GREET_SCRIPT"
cat > "$PROFILE_SCRIPT" <<'SHEOF'
# xnet-ssh-info.sh — X-Net panel: per-account stats block on Dropbear logins.
#
# This file is SOURCED by /etc/profile, so it must never call `exit` — that
# would terminate the user's login shell. (It previously ran `exit 0` when
# SSH_CONNECTION was unset, which killed every console login and `su -`.)
#
# OpenSSH accounts receive their block in the pre-auth banner, so this hook is
# scoped to Dropbear by checking which daemon started the shell. Without that
# check an OpenSSH login would print the block twice.
if [ -n "$SSH_CONNECTION" ] && [ -x /opt/xnet/xnet-ssh-greet ]; then
	_xnet_parent=""
	[ -r "/proc/$PPID/comm" ] && _xnet_parent="$(cat "/proc/$PPID/comm" 2>/dev/null)"
	case "$_xnet_parent" in
		dropbear*) /opt/xnet/xnet-ssh-greet >&2 ;;
	esac
	unset _xnet_parent
fi
SHEOF
chmod 0644 "$PROFILE_SCRIPT"
# The Dropbear hook runs as the account, so /opt/xnet must be traversable —
# otherwise even `[ -x $GREET_SCRIPT ]` fails and it silently prints nothing.
# That would expose /opt/xnet/data/xnet.db (sqlite creates it 0644, and it holds
# admin password hashes), so lock the data directory down in the same pass.
chmod o+rx "$INSTALL_DIR" 2>/dev/null || true
if [ -d "${INSTALL_DIR}/data" ]; then
  chmod 0750 "${INSTALL_DIR}/data" 2>/dev/null || true
  find "${INSTALL_DIR}/data" -maxdepth 1 -type f -name 'xnet.db*' -exec chmod 0640 {} + 2>/dev/null || true
fi
[ -f "${INSTALL_DIR}/.env" ] && chmod 0600 "${INSTALL_DIR}/.env" 2>/dev/null || true
say "  greet + profile.d installed, permissions fixed ✓"

say ""
say "Step 5: install the sudoers rule (Dropbear hook needs it)"
SUDOERS_TMP="/etc/sudoers.d/.xnet-ssh-info.tmp"
cat > "$SUDOERS_TMP" <<'EOF'
# ---- X-Net Panel — SSH account stats ----
# /etc/profile.d/xnet-ssh-info.sh runs as the logging-in user on Dropbear
# sessions and needs this to read the panel DB. xnet-ssh-info is read-only in
# this mode: it prints the ssh_accounts row for the username it is handed.
Defaults!/opt/xnet/xnet-ssh-info !requiretty
ALL ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-info, /opt/xnet/xnet-ssh-info *
EOF
chmod 0440 "$SUDOERS_TMP"
if ! command -v visudo >/dev/null 2>&1 || visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
  mv -f "$SUDOERS_TMP" "$SUDOERS_FILE"; say "  $SUDOERS_FILE installed ✓"
else
  rm -f "$SUDOERS_TMP"; say "  ERROR: sudoers validation failed — Dropbear stats will not show"
fi

say ""
say "Step 6: set the global Banner directive"
if [ -f "$BANNER_FILE" ]; then
  for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns; do
    [ -f "$cfg" ] || continue
    if grep -qiE "^[#[:space:]]*Banner[[:space:]]" "$cfg"; then
      sed -i -E "s|^[#[:space:]]*Banner[[:space:]].*|Banner ${BANNER_FILE}|I" "$cfg"
    else
      echo "Banner ${BANNER_FILE}" >> "$cfg"
    fi
    say "  $cfg ✓"
  done
  # Dropbear takes its banner as a -b flag, not a config directive.
  if [ -f /etc/systemd/system/dropbear.service ] && ! grep -q '\-b ' /etc/systemd/system/dropbear.service; then
    sed -i "s|^\(ExecStart=.*dropbear.*\)$|\1 -b ${BANNER_FILE}|" /etc/systemd/system/dropbear.service
    systemctl daemon-reload
    say "  dropbear.service: -b flag added"
  fi
fi

say ""
say "Step 7: generate the per-account banners"
"$INFO_SCRIPT" --write-banners || say "  WARNING: generation failed (journalctl -t xnet-ssh-info)"
if [ -d "$BANNER_DIR" ]; then
  say "  $(find "$BANNER_DIR" -name '*.txt' | wc -l) account banner(s) in $BANNER_DIR ✓"
else
  say "  no per-account banners generated — check the banner text and the DB"
fi

say ""
say "Step 8: install the refresh timer (keeps traffic figures current)"
cat > /etc/systemd/system/xnet-ssh-banners.service <<'UNIT'
[Unit]
Description=X-Net: refresh per-account SSH banners
[Service]
Type=oneshot
ExecStart=/opt/xnet/xnet-ssh-info --write-banners
UNIT
cat > /etc/systemd/system/xnet-ssh-banners.timer <<'UNIT'
[Unit]
Description=X-Net: refresh per-account SSH banners every 2 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=15s
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now xnet-ssh-banners.timer >/dev/null 2>&1 \
  && say "  xnet-ssh-banners.timer enabled ✓" \
  || say "  WARNING: could not enable the timer — figures update only on apply"

say ""
say "Step 9: reload SSH daemons"
# reload, not restart: established tunnels survive a reload.
for unit in ssh sshd sshd-ws sshd-tls sshd-dns; do
  systemctl is-active "$unit" >/dev/null 2>&1 || continue
  systemctl reload "$unit" >/dev/null 2>&1 && say "  $unit reloaded ✓"
done
if systemctl is-active dropbear >/dev/null 2>&1; then
  systemctl restart dropbear >/dev/null 2>&1 && say "  dropbear restarted (needed for -b) ✓"
fi

say ""
say "Step 10: verify"
first="$(find "$BANNER_DIR" -name '*.txt' 2>/dev/null | head -1)"
if [ -n "$first" ]; then
  say "  this is exactly what an account will see on connect:"
  echo "  ---------------------------------------------------"
  sed 's/^/  /' "$first"
  echo "  ---------------------------------------------------"
  acct="$(basename "$first" .txt)"
  if grep -qs "Match User ${acct}\$" /etc/ssh/sshd_config; then
    say "  Match block for '$acct' present in sshd_config ✓"
  else
    say "  WARNING: no Match block for '$acct' in /etc/ssh/sshd_config"
  fi
else
  say "  no per-account banner was produced — run: bash xnet-diag-banner.sh"
fi

say ""
say "========================================"
say "DONE — reconnect with any account to verify."
say "If the block still does not appear, run: bash xnet-diag-banner.sh"
