#!/usr/bin/env bash
# xnet-verify-stability.sh — verify on a LIVE node that monitoring, expiry,
# quota and device/session management are not disconnecting healthy users.
#
# This is the on-node counterpart to the regression tests. The tests prove the
# decisions are correct in isolation; this measures the running system, where
# the account count, the connection count and the real client behaviour are what
# they are.
#
# It is STRICTLY READ-ONLY. It never creates, kills, locks or unlocks anything,
# so it is safe to run on a node carrying live users.
#
# Usage:
#   sudo ./xnet-verify-stability.sh              # 60-second observation window
#   sudo ./xnet-verify-stability.sh -w 300       # longer window (more reliable)
#
# Exit status: 0 if every check passed, 1 if any check failed.

set -uo pipefail

WINDOW=60
while getopts "w:h" opt; do
  case "$opt" in
    w) WINDOW="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "usage: $0 [-w seconds]" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
note() { printf '         %s\n' "$*"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "This script reads journald and /proc; run it with sudo." >&2
  exit 2
fi

# journalctl window helper. Both units are optional — a node may run the panel
# without sing-box, or vice versa.
jlog_panel() { journalctl -u xnet --since "$1" --no-pager 2>/dev/null; }
jlog_sb()    { journalctl -u sing-box --since "$1" --no-pager 2>/dev/null; }

SINCE="${WINDOW} seconds ago"
LONG_SINCE="1 hour ago"

head1 "X-NET stability verification (observation window: ${WINDOW}s)"
note "Started $(date -Is)"

# ---------------------------------------------------------------------------
head1 "1. Services"
for unit in xnet sing-box; do
  state="$(systemctl is-active "$unit" 2>/dev/null)"
  case "$state" in
    active)   ok "$unit is active" ;;
    inactive|failed) bad "$unit is $state" ;;
    *)        warn "$unit: $state (unit may not be installed on this node)" ;;
  esac
done

# ---------------------------------------------------------------------------
head1 "2. usermod storm (the SSH login-failure cause)"
# The fixed panel runs usermod only on a real state transition. Anything more
# than a handful in an hour means blocking is being re-applied on a timer, which
# is what made sshd/PAM contend for /etc/shadow and healthy logins fail.
UM_HOUR=$(jlog_panel "$LONG_SINCE" | grep -c 'usermod' || true)
if [ "$UM_HOUR" -le 20 ]; then
  ok "usermod mentions in the last hour: ${UM_HOUR} (transition-driven)"
else
  bad "usermod mentions in the last hour: ${UM_HOUR} — this looks like a per-pass storm"
  note "Expected: one per account state change. A number that scales with the"
  note "account count means the pre-fix build is still deployed."
fi

# Live check: usermod should essentially never be caught running.
CAUGHT=0
END=$((SECONDS+10))
while [ $SECONDS -lt $END ]; do
  if pgrep -x usermod >/dev/null 2>&1; then CAUGHT=$((CAUGHT+1)); fi
  sleep 0.2
done
if [ "$CAUGHT" -eq 0 ]; then
  ok "usermod was never observed running during a 10s sample"
else
  bad "usermod was running in ${CAUGHT}/50 samples — /etc/shadow is being rewritten continuously"
fi

# /etc/shadow lock should not be held.
if [ -e /etc/passwd.lock ] || [ -e /etc/shadow.lock ]; then
  warn "an account-database lock file is present right now (a usermod may be mid-flight)"
else
  ok "no /etc/passwd|shadow lock held"
fi

# ---------------------------------------------------------------------------
head1 "3. sing-box reloads (mass-disconnect events)"
# Every reload drops all tunnels. Over a quiet hour there should be none.
RELOADS=$(jlog_panel "$LONG_SINCE" | grep -c 'Core reloaded successfully' || true)
SB_STARTS=$(jlog_sb "$LONG_SINCE" | grep -c 'sing-box started' || true)
note "panel-initiated reloads in the last hour: ${RELOADS}"
note "sing-box start banners in the last hour:  ${SB_STARTS}"
if [ "$RELOADS" -le 4 ]; then
  ok "reload count is consistent with configuration changes only"
else
  bad "${RELOADS} reloads in an hour — every one disconnects all users"
  note "Expected causes: an inbound/client edit, a subscription expiring, a"
  note "quota batch. A reload every ~15s is the pre-fix expiry loop."
fi

# The specific pre-fix signature: a reload immediately after connections were
# force-closed for an expired client.
if jlog_panel "$LONG_SINCE" | grep -q 'force-closed .* will re-assert config'; then
  bad "found the pre-fix log line tying a connection kill to a config re-assert"
  note "This build still reloads sing-box because a session was killed."
else
  ok "no 'kill → re-assert config' coupling in the logs"
fi

KILLS=$(jlog_panel "$LONG_SINCE" | grep -c 'force-closed .* sing-box connection' || true)
if [ "$KILLS" -gt 0 ] && [ "$RELOADS" -le 4 ]; then
  ok "${KILLS} expired-client connection kill(s) happened WITHOUT driving reloads"
fi

# ---------------------------------------------------------------------------
head1 "4. max_login / device enforcement"
# A healthy node kills excess DEVICES occasionally. A kill/reconnect loop shows
# as the same account being reported over its limit again and again.
OVER=$(jlog_panel "$LONG_SINCE" | grep -oP '\[SSHMonitor\] \K\S+(?= has \d+ live session)' | sort | uniq -c | sort -rn || true)
if [ -z "$OVER" ]; then
  ok "no account reported over its device limit in the last hour"
else
  note "accounts reported over their limit (count username):"
  echo "$OVER" | sed 's/^/           /'
  TOP=$(echo "$OVER" | head -1 | awk '{print $1}')
  # The report itself is throttled to one line per account per minute, so more
  # than ~60 in an hour is impossible; a sustained 60 means permanently over.
  if [ "${TOP:-0}" -ge 55 ]; then
    warn "one account has been over its limit continuously for the whole hour"
    note "Check whether it is genuinely shared (several distinct IPs in the log"
    note "line) or a single client whose parallel connections should share a slot."
  else
    ok "over-limit reports are intermittent, not a sustained loop"
  fi
fi

# The single-IP case must never be killed under the device rule.
if jlog_panel "$LONG_SINCE" | grep -q 'all from .* one client opening several parallel connections'; then
  SINGLE_IP_KILLS=$(jlog_panel "$LONG_SINCE" | grep -c 'over device limit' || true)
  if [ "$SINGLE_IP_KILLS" -eq 0 ]; then
    ok "single-IP multi-connection clients were reported but never killed"
  else
    warn "a single-IP client was reported AND kills occurred — verify the kills"
    note "belong to a different, genuinely distinct device."
  fi
fi

# ---------------------------------------------------------------------------
head1 "5. Monitoring cadence and database pressure"
CAD=$(jlog_panel "$LONG_SINCE" | grep -oP 'Device-limit enforcement running every \K\S+' | tail -1)
[ -n "$CAD" ] && note "device-limit cadence reported by the panel: $CAD"

# WAL growth is the visible symptom of per-pass writes.
DB=""
for cand in /opt/xnet/data/xnet.db /opt/xnet/xnet.db /var/lib/xnet/xnet.db; do
  [ -f "$cand" ] && DB="$cand" && break
done
if [ -z "$DB" ]; then
  warn "could not locate the panel database; skipping WAL check"
else
  WAL="${DB}-wal"
  if [ -f "$WAL" ]; then
    S1=$(stat -c %s "$WAL")
    sleep "$WINDOW"
    S2=$(stat -c %s "$WAL")
    GROWTH=$(( (S2 - S1) ))
    RATE=$(( GROWTH / WINDOW ))
    note "WAL grew ${GROWTH} bytes over ${WINDOW}s (~${RATE} B/s)"
    # An idle panel should write almost nothing now that presence updates are
    # change-gated. Sustained six-figure growth means per-pass writes are back.
    if [ "$RATE" -lt 20000 ]; then
      ok "database write pressure is low"
    else
      bad "WAL is growing ~${RATE} B/s — presence rows are likely being rewritten every pass"
    fi
  else
    sleep "$WINDOW"
    ok "no WAL file growth to measure (database idle)"
  fi
  # The index the per-username writes depend on.
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$DB" "PRAGMA index_list('ssh_accounts');" 2>/dev/null | grep -q 'idx_ssh_accounts_username'; then
      ok "idx_ssh_accounts_username is present"
    else
      bad "idx_ssh_accounts_username is MISSING — per-username writes are full table scans"
    fi
  fi
fi

# ---------------------------------------------------------------------------
head1 "6. Panel CPU"
PID=$(systemctl show -p MainPID --value xnet 2>/dev/null)
if [ -n "${PID:-}" ] && [ "$PID" != "0" ] && [ -d "/proc/$PID" ]; then
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ U1 S1 _ < "/proc/$PID/stat"
  sleep 5
  read -r _ _ _ _ _ _ _ _ _ _ _ _ _ U2 S2 _ < "/proc/$PID/stat"
  HZ=$(getconf CLK_TCK)
  CPU=$(( ( (U2 - U1) + (S2 - S1) ) * 100 / (HZ * 5) ))
  note "panel CPU over 5s: ~${CPU}% of one core"
  if [ "$CPU" -lt 25 ]; then
    ok "panel CPU is within a normal idle/monitoring range"
  else
    warn "panel CPU is ${CPU}% — check the poll intervals in the log banner"
  fi
else
  warn "could not read the panel PID; skipping CPU sample"
fi

# ---------------------------------------------------------------------------
head1 "Manual scenarios to confirm by hand"
cat <<'EOF'
  These need a real client and cannot be asserted from logs alone. Run each and
  watch `journalctl -u xnet -f` while you do.

   a) One SSH account, ONE device, several parallel connections
      Expect: online count rises to the number of connections; NO kill lines;
              the account is reported as one device.
   b) Change the client's IP (toggle mobile data / flight mode)
      Expect: the new address connects immediately. No "over device limit" for
              it, and no wait. There must be NO sing-box reload.
   c) max_login = 1, then connect a SECOND, genuinely different device
      Expect: the second device's sessions are dropped on the next pass and
              STAY dropped; the first device is untouched throughout.
   d) Let one account expire (set expire_date in the past)
      Expect: exactly ONE "Core reloaded successfully"; other users' tunnels
              recover immediately and no further reloads follow.
   e) Exhaust one SSH account's quota
      Expect: "ENFORCING BLOCK", its sessions die, and it CANNOT reconnect
              (this is the part that never worked before). Other accounts stay up.
   f) Reset that account's traffic from the panel
      Expect: the account can log in again immediately — no leftover lock.
   g) Several sing-box clients hitting quota together
      Expect: exactly ONE reload for the whole group.
EOF

# ---------------------------------------------------------------------------
head1 "Result"
printf '  passed: %d   failed: %d   warnings: %d\n' "$PASS" "$FAIL" "$WARN"
if [ "$FAIL" -gt 0 ]; then
  echo "  One or more invariants FAILED — see the [FAIL] lines above."
  exit 1
fi
echo "  All automated checks passed."
exit 0
