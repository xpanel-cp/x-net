#!/usr/bin/env bash
# xnet-fix-sudoers.sh — regenerate /etc/sudoers.d/xnet and say exactly why if
# it cannot be installed.
#
# Run as root:
#   bash xnet-fix-sudoers.sh            # diagnose + repair
#   bash xnet-fix-sudoers.sh --check    # diagnose only, change nothing
#
# WHY THIS EXISTS
# The panel runs as the unprivileged "xnet" user and does every privileged
# action through sudo: creating SSH accounts, restarting Dropbear/sshd, applying
# a port change. All of that depends on one file, /etc/sudoers.d/xnet.
#
# The installer generates that file, validates it with visudo, and — if
# validation fails — deletes it and moves on with a single warning. When no
# previous file existed, the result is a host where the panel has NO privileges
# at all. Every symptom then points somewhere else: accounts that cannot log in,
# ports that never change, services that never restart, each reporting
# "sudo: ... I'm afraid I can't do that". This script makes that one root cause
# visible and fixable on its own.
set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

SERVICE_USER="${SERVICE_USER:-xnet}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xnet}"
TARGET="/etc/sudoers.d/xnet"
TMP="/etc/sudoers.d/.xnet.tmp"   # dotted name => sudo ignores it while staging

pass() { echo "  [ OK ] $*"; }
fail() { echo "  [FAIL] $*"; }
note() { echo "         $*"; }
hdr()  { echo ""; echo "== $* =="; }

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

# ---------------------------------------------------------------------------
hdr "1. Current state"
# ---------------------------------------------------------------------------
if id -u "$SERVICE_USER" >/dev/null 2>&1; then
  pass "service user '$SERVICE_USER' exists"
else
  fail "service user '$SERVICE_USER' does not exist — run install.sh first"
  exit 1
fi

# sudo only reads the drop-in directory when it is included from /etc/sudoers.
if grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
  pass "/etc/sudoers includes /etc/sudoers.d"
else
  fail "/etc/sudoers does NOT include /etc/sudoers.d — nothing in that directory is read"
  note "Add this line to /etc/sudoers (via visudo):   @includedir /etc/sudoers.d"
fi

if [ -f "$TARGET" ]; then
  pass "$TARGET exists ($(wc -l < "$TARGET") rules), mode $(stat -c %a "$TARGET")"
else
  fail "$TARGET does NOT exist — the panel has no privileges at all"
fi
[ -f /etc/sudoers.d/.xnet.rejected ] &&
  note "a previously rejected version is kept at /etc/sudoers.d/.xnet.rejected"

# sudo silently ignores any file in sudoers.d whose name contains a dot or ends
# with '~' — a rule set in such a file is invisible with no error anywhere.
for f in /etc/sudoers.d/*; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in
    README) ;;
    *.*|*~) note "NOTE: '$b' is IGNORED by sudo (its name contains '.' or ends with '~')" ;;
  esac
done

echo
echo "  what '$SERVICE_USER' may run today:"
sudo -u "$SERVICE_USER" sudo -n -l 2>&1 | sed 's/^/         /' | head -12

# ---------------------------------------------------------------------------
hdr "2. Generating the rule set"
# ---------------------------------------------------------------------------
cat > "$TMP" <<'EOF'
# ---- X-Net Panel — sudoers rules ----
# SSH user management
xnet ALL=(root) NOPASSWD: /usr/sbin/useradd, /usr/sbin/usermod, /usr/sbin/userdel, /usr/sbin/chpasswd
xnet ALL=(root) NOPASSWD: /sbin/useradd, /sbin/usermod, /sbin/userdel, /sbin/chpasswd
xnet ALL=(root) NOPASSWD: /usr/bin/chpasswd, /usr/bin/pkill, /bin/pkill, /usr/bin/kill, /bin/kill
xnet ALL=(root) NOPASSWD: /usr/sbin/groupadd, /sbin/groupadd
# gpasswd: removes a user from a protocol group when its SSH method changes.
xnet ALL=(root) NOPASSWD: /usr/bin/gpasswd, /bin/gpasswd, /usr/sbin/gpasswd
# passwd: read-only account status (`passwd -S`) to verify an account can really
# authenticate. Password writes still go through chpasswd.
xnet ALL=(root) NOPASSWD: /usr/bin/passwd, /bin/passwd
# Live connection inspection: the peer IP of a connected SSH user, and the
# per-socket byte counters that are the ONLY way to measure a Dropbear
# tunnel-only session (it never runs a process as the account, so the UID-keyed
# kernel counters read 0 for it forever).
xnet ALL=(root) NOPASSWD: /usr/sbin/ss, /sbin/ss, /usr/bin/ss, /bin/ss
# Auth-log reading: a Dropbear tunnel session's authentication line is the only
# record of which account owns the connection. Without it such accounts show
# 0 online and 0 traffic. Read-only; journalctl cannot modify anything.
xnet ALL=(root) NOPASSWD: /usr/bin/journalctl, /bin/journalctl
# Firewall
xnet ALL=(root) NOPASSWD: /usr/sbin/nft, /sbin/nft
xnet ALL=(root) NOPASSWD: /usr/sbin/ufw, /usr/bin/ufw, /usr/bin/firewall-cmd, /bin/firewall-cmd
# systemctl daemon-reload (no service argument)
xnet ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload, /bin/systemctl daemon-reload
# Privileged helpers (trailing-arg wildcard is permitted by sudo)
xnet ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-apply, /opt/xnet/xnet-ssh-apply *
xnet ALL=(root) NOPASSWD: /opt/xnet/xnet-cert-install, /opt/xnet/xnet-cert-install *
# Any authenticated SSH user may read their own account stats.
# The Defaults !requiretty directive is not portable; omit it to keep the sudoers
# fragment valid across distributions.
ALL ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-info, /opt/xnet/xnet-ssh-info *
# TLS certificate management
xnet ALL=(root) NOPASSWD: /usr/bin/certbot, /usr/bin/certbot *, /bin/certbot, /bin/certbot *
# Panel self-restart via a transient unit
xnet ALL=(root) NOPASSWD: /usr/bin/systemd-run *, /bin/systemd-run *
EOF

# Explicit verb+service systemctl rules. A wildcard in the MIDDLE of the
# arguments (`systemctl * sshd`) is rejected by sudo and invalidates the WHOLE
# file, which is precisely how a host ends up with no rules at all.
{
  echo "# systemctl control for managed services (explicit verb+service)"
  for svc in sing-box sshd ssh ssh.socket sshd.socket sshd-ws sshd-tls sshd-dns xnet-ws dropbear stunnel4 badvpn-udpgw slowdns xnet; do
    for sc in /usr/bin/systemctl /bin/systemctl; do
      for verb in start stop restart reload status is-active enable disable; do
        echo "xnet ALL=(root) NOPASSWD: ${sc} ${verb} ${svc}"
      done
    done
  done
} >> "$TMP"

chmod 440 "$TMP"
pass "generated $(wc -l < "$TMP") rules"

# ---------------------------------------------------------------------------
hdr "3. Validating with visudo"
# ---------------------------------------------------------------------------
if out="$(visudo -cf "$TMP" 2>&1)"; then
  pass "visudo accepted the rule set"
  if [ "$CHECK_ONLY" = "1" ]; then
    rm -f "$TMP"
    note "--check given: nothing was installed."
    exit 0
  fi
  mv -f "$TMP" "$TARGET"
  chmod 440 "$TARGET"
  rm -f /etc/sudoers.d/.xnet.rejected 2>/dev/null || true
  pass "installed $TARGET"
else
  fail "visudo REJECTED the rule set — this is why the panel has no privileges:"
  printf '%s\n' "$out" | sed 's/^/         /'
  mv -f "$TMP" /etc/sudoers.d/.xnet.rejected 2>/dev/null || rm -f "$TMP"
  note "the rejected file is at /etc/sudoers.d/.xnet.rejected (sudo ignores that name)"
  note "send the lines above for analysis; nothing on this host was changed"
  exit 1
fi

# ---------------------------------------------------------------------------
hdr "4. Verifying the panel can actually use it"
# ---------------------------------------------------------------------------
ok_count=0; bad_count=0
check_cmd() {
  if sudo -u "$SERVICE_USER" sudo -n -l "$1" >/dev/null 2>&1; then
    pass "$SERVICE_USER may run $1"; ok_count=$((ok_count+1))
  else
    fail "$SERVICE_USER may NOT run $1"; bad_count=$((bad_count+1))
  fi
}
for c in useradd usermod chpasswd groupadd gpasswd passwd nft ss; do
  p="$(command -v "$c" 2>/dev/null)"; [ -n "$p" ] && check_cmd "$p"
done
[ -x "${INSTALL_DIR}/xnet-ssh-apply" ] && check_cmd "${INSTALL_DIR}/xnet-ssh-apply"
sc="$(command -v systemctl 2>/dev/null)"
[ -n "$sc" ] && check_cmd "$sc restart dropbear"

echo
if [ "$bad_count" -eq 0 ]; then
  echo "  DONE: $ok_count/$ok_count privileged commands are available to the panel."
  echo "  Re-apply the SSH settings from the panel — the port change should now work."
else
  echo "  $bad_count command(s) still unavailable. Send this output for analysis."
  exit 1
fi
