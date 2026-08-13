#!/usr/bin/env bash
# xnet-diag-banner.sh — find out why the SSH banner shows but the per-account
# stats block does not. Read-only: this script changes nothing.
#
# Run as root on the server:
#   bash xnet-diag-banner.sh              # checks the first SSH account it finds
#   bash xnet-diag-banner.sh <username>   # checks a specific account
#
# It walks the chain a real login walks, in order, and stops being useful at the
# first FAIL — that line is the answer.
set -uo pipefail

WANT_USER="${1:-}"
INSTALL_DIR="/opt/xnet"
INFO="${INSTALL_DIR}/xnet-ssh-info"
GREET="${INSTALL_DIR}/xnet-ssh-greet"
BANNER_FILE="/etc/ssh/xnet-banner.txt"
SSHRC="/etc/ssh/sshrc"
BANNER_DIR="/etc/ssh/xnet-banners"
PROFILE_SCRIPT="/etc/profile.d/xnet-ssh-info.sh"
SUDOERS_FILE="/etc/sudoers.d/xnet-ssh-info"

fails=0
pass() { echo "  [ OK ] $*"; }
fail() { echo "  [FAIL] $*"; fails=$((fails+1)); }
note() { echo "         $*"; }
hdr()  { echo ""; echo "== $* =="; }

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

hdr "1. Which apply helper is installed"
if [ -f "${INSTALL_DIR}/xnet-ssh-apply" ]; then
  ver="$(grep -m1 -o 'XNET_SSH_APPLY_VERSION=[0-9]*' "${INSTALL_DIR}/xnet-ssh-apply" | head -1 | cut -d= -f2)"
  if [ "${ver:-0}" -ge 9 ] 2>/dev/null; then
    pass "xnet-ssh-apply is v${ver}"
  else
    fail "xnet-ssh-apply is v${ver:-unknown} — needs v9+"
    note "The fix is NOT deployed. Copy install/xnet-ssh-apply to ${INSTALL_DIR}/xnet-ssh-apply"
    note "(chmod 0755, strip CRs with: sed -i 's/\r\$//' ${INSTALL_DIR}/xnet-ssh-apply),"
    note "then re-save the banner in the panel — or just run xnet-fix-banner.sh."
  fi
else
  fail "${INSTALL_DIR}/xnet-ssh-apply is missing"
fi

hdr "2. Banner text (this part already works for you)"
if [ -s "$BANNER_FILE" ]; then
  pass "$BANNER_FILE exists ($(wc -l < "$BANNER_FILE") lines)"
else
  fail "$BANNER_FILE missing or empty — set a banner in the panel first"
fi
for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns; do
  [ -f "$cfg" ] || continue
  if grep -qiE "^Banner[[:space:]]" "$cfg"; then pass "Banner set in $cfg"; else fail "Banner NOT set in $cfg"; fi
done

hdr "3. Per-account banners — this is what actually delivers the block"
if [ -d "$BANNER_DIR" ] && [ -n "$(find "$BANNER_DIR" -name '*.txt' 2>/dev/null | head -1)" ]; then
  pass "$BANNER_DIR holds $(find "$BANNER_DIR" -name '*.txt' | wc -l) account banner(s)"
else
  fail "$BANNER_DIR is empty or missing"
  note "Nothing can show account details until these exist."
  note "Fix: /opt/xnet/xnet-ssh-info --write-banners   (or run xnet-fix-banner.sh)"
fi
# Each config backs a different transport, which is why one missing section
# looks like "works on SSH TCP only".
for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns; do
  case "$cfg" in
    */sshd_config)     proto="SSH TCP" ;;
    */sshd_config_ws)  proto="SSH WS / WS TLS" ;;
    */sshd_config_tls) proto="SSH TLS" ;;
    */sshd_config_dns) proto="SSH SlowDNS" ;;
  esac
  if [ ! -f "$cfg" ]; then
    note "$cfg absent — nothing serves $proto from a separate sshd here"
    continue
  fi
  if grep -qF "xnet per-account banners" "$cfg"; then
    n="$(grep -c '^Match User ' "$cfg")"
    pass "$proto: $cfg has the managed section ($n Match blocks)"
    # A config that sshd itself rejects is the usual reason a transport was
    # skipped, so surface it even when the section is present.
    if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
      "${SSHD_BIN:-/usr/sbin/sshd}" -t -f "$cfg" >/dev/null 2>&1 || \
        note "  (heads-up: 'sshd -t -f $cfg' fails — pre-existing, does not block the banner)"
    fi
    # Everything after a Match belongs to that block, so a global directive
    # below the section would be silently scoped to one account.
    if [ -n "$(sed -n '/xnet per-account banners (managed) <<</,$p' "$cfg" | tail -n +2 | grep -v '^[[:space:]]*$')" ]; then
      fail "$cfg has content AFTER the managed section — a global directive is trapped in a Match block"
      note "Fix: /opt/xnet/xnet-ssh-info --write-banners  (it re-appends the section last)"
    fi
  else
    fail "$proto: $cfg has NO managed Match section — that protocol shows plain text only"
    note "  Fix: $INFO --write-banners   (it now reports any config it cannot update)"
  fi
done

hdr "4. SSH Dropbear"
note "Dropbear takes one global banner file (-b) and has no Match/per-user"
note "equivalent, so it cannot send a per-account banner the way OpenSSH does."
note "Its accounts get the plain text pre-auth, plus the block from the login"
note "shell hook below — which only clients that display session output show."
note "This is Dropbear's own mechanism and is intentional: Dropbear is an"
note "independent protocol here, not an OpenSSH variant. Nothing below is a"
note "fault to fix — only the profile.d hook is expected to deliver its block."
if [ -f "$PROFILE_SCRIPT" ] && grep -qF "xnet-ssh-greet" "$PROFILE_SCRIPT"; then
  pass "$PROFILE_SCRIPT calls xnet-ssh-greet"
else
  fail "$PROFILE_SCRIPT missing or has no xnet-ssh-greet hook (Dropbear shows text only)"
fi
if [ -f "$SSHRC" ] && grep -qF "xnet-ssh-greet" "$SSHRC"; then
  fail "$SSHRC still carries the retired hook — terminal clients would print the block twice"
  note "Fix: run xnet-fix-banner.sh, or delete the xnet-ssh-greet line from $SSHRC"
fi
for cfg in /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns; do
  [ -f "$cfg" ] || continue
  grep -qF "xnet-fc" "$cfg" && fail "$cfg still has the old xnet-fc ForceCommand"
done
# sshd parses its config once at startup, so a Match section only takes effect
# after a reload. A unit with no ExecReload cannot be reloaded at all — the file
# is right, the running daemon never sees it. This is the usual reason the block
# appears on SSH TCP and nowhere else.
for svc in ws tls dns; do
  unit="/etc/systemd/system/sshd-${svc}.service"
  [ -f "$unit" ] || continue
  if grep -q '^ExecReload=' "$unit"; then
    pass "sshd-${svc}.service can be reloaded"
  else
    fail "sshd-${svc}.service has NO ExecReload — config changes never reach it"
    note "  That daemon still serves the banner it read at startup."
    note "  Fix: re-save the SSH settings (xnet-ssh-apply repairs the unit), or:"
    note "    sed -i '/^ExecStart=/a ExecReload=/bin/kill -HUP \$MAINPID' $unit"
    note "    systemctl daemon-reload && systemctl kill -s HUP sshd-${svc}"
  fi
done
if systemctl list-timers xnet-ssh-banners.timer >/dev/null 2>&1 &&
   systemctl is-enabled xnet-ssh-banners.timer >/dev/null 2>&1; then
  pass "xnet-ssh-banners.timer enabled (traffic figures stay current)"
else
  fail "xnet-ssh-banners.timer not enabled — traffic figures will freeze between applies"
fi

hdr "4. Helper scripts and their permissions"
for f in "$INFO" "$GREET"; do
  if [ -x "$f" ]; then
    pass "$f exists ($(stat -c '%U:%G %a' "$f"))"
  else
    fail "$f missing or not executable"
  fi
done
# The hooks run as the SSH account, so /opt/xnet must be traversable by others.
mode="$(stat -c '%a' "$INSTALL_DIR" 2>/dev/null)"
case "$mode" in
  *[157]) pass "$INSTALL_DIR mode $mode is traversable by other users" ;;
  *)      fail "$INSTALL_DIR mode $mode blocks other users"
          note "An SSH account cannot even see $GREET, so the hook exits silently."
          note "Fix: chmod o+rx $INSTALL_DIR && chmod 0750 $INSTALL_DIR/data" ;;
esac
dbmode="$(stat -c '%a' "${INSTALL_DIR}/data/xnet.db" 2>/dev/null || echo '')"
case "$dbmode" in
  ""|*[0]) : ;;
  *[4567]) note "NOTE: ${INSTALL_DIR}/data/xnet.db is mode $dbmode (world-readable) — tighten to 0640" ;;
esac

hdr "5. python3"
if command -v python3 >/dev/null 2>&1; then
  pass "$(python3 -V 2>&1)"
else
  fail "python3 not installed — xnet-ssh-info cannot run at all"
  note "Fix: apt-get install -y python3"
fi

hdr "6. Panel database"
DB="$(python3 - <<'PY' 2>/dev/null
import sqlite3, os
def env_db_path():
    try:
        with open("/opt/xnet/.env") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("DATABASE_PATH="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""
for p in [env_db_path(), "/opt/xnet/data/xnet.db", "/opt/xnet/xnet.db", "/var/lib/xnet/xnet.db"]:
    if p and os.path.isfile(p):
        try:
            sqlite3.connect(p, timeout=3).execute("SELECT 1 FROM ssh_accounts LIMIT 1")
            print(p); break
        except Exception:
            pass
PY
)"
if [ -n "$DB" ]; then
  pass "DB with an ssh_accounts table: $DB"
else
  fail "no readable DB with an ssh_accounts table"
  note "On a NODE (not the panel host) there is no ssh_accounts table — the stats"
  note "block can only work where the panel DB lives. That is expected."
fi

hdr "7. sudoers rule (the usual culprit)"
if [ -f "$SUDOERS_FILE" ]; then
  pass "$SUDOERS_FILE exists"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1 && pass "it passes visudo" || fail "it FAILS visudo — sudo may be ignoring it"
  fi
elif grep -rqs "xnet-ssh-info" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
  pass "an xnet-ssh-info rule exists elsewhere in /etc/sudoers.d"
else
  fail "no sudoers rule for xnet-ssh-info anywhere"
  note "This is the single most common cause: the hooks run unprivileged and"
  note "cannot read the DB. Run xnet-fix-banner.sh to install it."
fi

hdr "8. End-to-end test"
if [ -z "$WANT_USER" ] && [ -n "$DB" ]; then
  WANT_USER="$(python3 - "$DB" <<'PY' 2>/dev/null
import sqlite3, sys
try:
    r = sqlite3.connect(sys.argv[1], timeout=3).execute("SELECT username FROM ssh_accounts LIMIT 1").fetchone()
    if r: print(r[0])
except Exception:
    pass
PY
)"
fi
if [ -z "$WANT_USER" ]; then
  note "no account to test with — pass one: bash $0 <username>"
else
  echo "  account under test: $WANT_USER"
  echo ""
  echo "  --- the banner sshd will send this account (OpenSSH: tcp/ws/tls/dns) ---"
  acct_banner="${BANNER_DIR}/${WANT_USER}.txt"
  if [ -s "$acct_banner" ]; then
    sed 's/^/  /' "$acct_banner"
    if grep -q "Account   : ${WANT_USER}" "$acct_banner"; then
      pass "the account block is in the banner file"
    else
      fail "$acct_banner has no account block — only the plain text"
    fi
    if grep -qE "^Match User ${WANT_USER}\$" /etc/ssh/sshd_config; then
      pass "sshd_config selects it via Match User $WANT_USER"
    else
      fail "no 'Match User $WANT_USER' in /etc/ssh/sshd_config — sshd will send the global banner"
    fi
  else
    fail "$acct_banner missing"
    note "Fix: $INFO --write-banners"
  fi
  echo ""
  echo "  --- Dropbear path: as $WANT_USER (proves the sudoers rule works) ---"
  if id "$WANT_USER" >/dev/null 2>&1; then
    user_out="$(su -s /bin/sh -c "$GREET" "$WANT_USER" 2>&1)"
    if [ -n "$user_out" ]; then printf '%s\n' "$user_out" | sed 's/^/  /'; pass "unprivileged lookup produced output"
    else fail "unprivileged lookup produced NOTHING"
         note "Only affects Dropbear. Check section 7, then:"
         note "   journalctl -t xnet-ssh-greet -t xnet-ssh-info --since '5 min ago'"
    fi
  else
    fail "no Linux user '$WANT_USER' on this host"
    note "The account is provisioned on a different node. Run this script there —"
    note "banners are generated where the panel DB is, and read where the user is."
  fi
fi

hdr "Summary"
if [ "$fails" -eq 0 ]; then
  echo "  No failures found. The banner printed in section 8 is byte-for-byte what"
  echo "  sshd sends before authentication, so any client that shows the admin's"
  echo "  text will show the block too."
  echo ""
  echo "  If a real login still shows only the text, capture and send:"
  echo "    ssh -v <account>@<host> 2>&1 | head -40"
  echo "    journalctl -t xnet-ssh-info --since '10 min ago'"
else
  echo "  $fails check(s) failed — fix the first FAIL above, then re-run."
fi
