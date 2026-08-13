#!/usr/bin/env bash
# xnet-diag-traffic.sh — find out why SSH accounts show little or no traffic.
# Read-only: this script changes nothing.
#
# Run as root on the server:
#   bash xnet-diag-traffic.sh
#
# It follows the accounting pipeline end to end and stops being useful at the
# first FAIL — that line is the answer.
#
#   kernel counters (nftables, keyed by Linux UID)
#        -> traffic_records          (per-username totals)
#        -> ssh_accounts.traffic_used_bytes   (what the panel and banner show)
set -uo pipefail

TABLE="xnet_accounting"
IN_SET="ssh_uids_input"
OUT_SET="ssh_uids_output"
SERVICE_USER="${SERVICE_USER:-xnet}"

# Optional first argument: focus section 8 on ONE account.
#   bash xnet-diag-traffic.sh koskesh1
FOCUS_USER="${1:-}"

fails=0
pass() { echo "  [ OK ] $*"; }
fail() { echo "  [FAIL] $*"; fails=$((fails+1)); }
note() { echo "         $*"; }
hdr()  { echo ""; echo "== $* =="; }

[ "$(id -u)" = "0" ] || { echo "must run as root"; exit 1; }

DB="$(python3 - <<'PY' 2>/dev/null
import sqlite3, os
def env_db():
    try:
        with open("/opt/xnet/.env", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.strip().startswith("DATABASE_PATH="):
                    return line.split("=",1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""
for p in [env_db(), "/opt/xnet/data/xnet.db", "/opt/xnet/xnet.db", "/var/lib/xnet/xnet.db"]:
    if p and os.path.isfile(p):
        try:
            sqlite3.connect(p, timeout=3).execute("SELECT 1 FROM ssh_accounts LIMIT 1")
            print(p); break
        except Exception:
            pass
PY
)"

hdr "1. nftables accounting infrastructure"
if ! command -v nft >/dev/null 2>&1; then
  fail "nft is not installed — kernel accounting cannot run at all"
  note "Fix: apt-get install -y nftables"
else
  pass "nft present ($(nft --version 2>/dev/null | head -1))"
  if nft list table inet "$TABLE" >/dev/null 2>&1; then
    pass "table inet $TABLE exists"
    for s in "$IN_SET" "$OUT_SET"; do
      if nft list set inet "$TABLE" "$s" >/dev/null 2>&1; then
        # The counter FLAG is the whole game: it can only be set when the set is
        # created, `add set` on an existing set is a silent no-op, and a set
        # without it reports every element as zero bytes forever.
        if nft -j list set inet "$TABLE" "$s" 2>/dev/null | grep -q '"counter"'; then
          pass "set $s exists WITH per-element counters"
        else
          fail "set $s exists but has NO counter flag — this is why usage is always 0"
          note "It can only be fixed by recreating the set. Restart the panel: the"
          note "collector now detects this and rebuilds the set automatically."
          note "Manual equivalent: nft delete set inet $TABLE $s   (then restart xnet)"
        fi
      else
        fail "set $s is MISSING — the panel never finished initialising accounting"
      fi
    done
    for pair in "input_accounting:$IN_SET" "output_accounting:$OUT_SET"; do
      ch="${pair%%:*}"; st="${pair##*:}"
      n="$(nft list chain inet "$TABLE" "$ch" 2>/dev/null | grep -c "skuid.*@$st")"
      case "${n:-0}" in
        1) pass "chain $ch has exactly 1 lookup rule" ;;
        0) fail "chain $ch has NO lookup rule — nothing is counted for that direction" ;;
        *) fail "chain $ch has $n duplicate lookup rules — every byte is counted ${n}x"
           note "Each panel restart used to append another copy. Restart the panel:"
           note "the collector now rebuilds the chain with exactly one rule." ;;
      esac
    done
  else
    fail "table inet $TABLE does NOT exist"
    note "The panel could not create it. Almost always a sudo problem: the panel"
    note "runs as '$SERVICE_USER' and shells out to 'sudo -n nft'."
    note "Check: sudo -u $SERVICE_USER sudo -n nft list ruleset >/dev/null; echo \$?"
  fi
fi

hdr "2. Can the panel user actually run nft?"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  if sudo -u "$SERVICE_USER" sudo -n nft list ruleset >/dev/null 2>&1; then
    pass "sudo -u $SERVICE_USER sudo -n nft works"
  else
    fail "'$SERVICE_USER' cannot run 'sudo -n nft'"
    note "Every counter read and every UID registration fails silently."
    note "Fix: ensure /etc/sudoers.d/xnet has the nft rule, then: visudo -c"
  fi
else
  note "no '$SERVICE_USER' user on this host — panel may run as root (fine)"
fi

hdr "3. Are the SSH accounts registered in the accounting sets?"
if [ -n "$DB" ]; then
  accounts="$(python3 - "$DB" <<'PY' 2>/dev/null
import sqlite3, sys
for (u,) in sqlite3.connect(sys.argv[1], timeout=3).execute(
        "SELECT username FROM ssh_accounts WHERE enabled = 1"):
    print(u)
PY
)"
else
  accounts=""
  fail "no panel DB found — cannot list accounts"
fi
in_elems="$(nft -j list set inet "$TABLE" "$IN_SET" 2>/dev/null)"
out_elems="$(nft -j list set inet "$TABLE" "$OUT_SET" 2>/dev/null)"
missing=0; present=0
for u in $accounts; do
  uid="$(id -u "$u" 2>/dev/null)"
  if [ -z "$uid" ]; then
    fail "account '$u' has no Linux user — it can neither log in nor be measured"
    continue
  fi
  if printf '%s' "$in_elems$out_elems" | grep -q "\"val\": *$uid\b"; then
    present=$((present+1))
  else
    missing=$((missing+1))
    fail "account '$u' (UID $uid) is NOT in the accounting sets — its traffic is not counted"
  fi
done
[ "$present" -gt 0 ] && pass "$present account(s) registered for accounting"
if [ "$missing" -gt 0 ]; then
  note "Fix: restart the panel (it re-syncs every enabled account at startup),"
  note "     then re-check. If they are still missing, section 2 is the cause."
fi

hdr "4. Are the kernel counters actually moving?"
total_bytes=0
if [ -n "$in_elems$out_elems" ]; then
  total_bytes="$(printf '%s' "$in_elems$out_elems" |
    grep -o '"bytes": *[0-9]*' | grep -o '[0-9]*' |
    awk '{s+=$1} END{print s+0}')"
fi
if [ "${total_bytes:-0}" -gt 0 ]; then
  pass "counters hold ${total_bytes} bytes in total"
else
  fail "every nftables counter reads 0 — the kernel is matching nothing"
  note "NOT necessarily a fault: nftables is only ONE of the two SSH paths, and"
  note "it is expected to read 0 on a host whose accounts are all Dropbear."
  note "What nftables IS and IS NOT able to count:"
  note "  Counted:     sockets OPENED BY the sshd child running as the account,"
  note "               i.e. the connections a port-forward/SOCKS tunnel makes"
  note "               outward to the destination sites."
  note "  NOT counted: the encrypted SSH connection to the client itself. That"
  note "               socket is accepted by the root sshd listener and the"
  note "               kernel copies sk_uid from the listener, so it stays UID 0"
  note "               no matter which account authenticated."
  note "  NOT counted: anything at all under Dropbear, which never runs a process"
  note "               as the account for a tunnel-only session. Those are"
  note "               measured by the socket-level collector — see section 5b."
  note "So: if section 5b passes and the panel shows usage, this FAIL is cosmetic."
  note ""
  note "Also verify TCP early demux, which is what lets the input hook see the"
  note "socket owner at all:  sysctl net.ipv4.tcp_early_demux   (should be 1)"
fi
ed="$(sysctl -n net.ipv4.tcp_early_demux 2>/dev/null || echo '?')"
if [ "$ed" = "1" ]; then pass "net.ipv4.tcp_early_demux = 1"
else fail "net.ipv4.tcp_early_demux = $ed — the input hook cannot read the socket owner, so download is never counted"
     note "Fix: sysctl -w net.ipv4.tcp_early_demux=1 (persist in /etc/sysctl.d/)"
fi

hdr "5. Which transports reach which accounting path?"
note "SSH TCP        — direct to sshd; the sshd child runs AS the account, so its"
note "                 forwarded sockets ARE visible to the UID-keyed nftables."
note "WS / TLS / WS TLS / SlowDNS — the panel proxies these. The client's bytes"
note "                 arrive on a socket owned by '$SERVICE_USER', not by the"
note "                 account, so nftables cannot attribute them. Those are"
note "                 counted in-process by the panel's proxy collector instead."
note "Dropbear       — NOT the same shape as SSH TCP, despite the similar setup."
note "                 Dropbear only forks and setuids when it runs a SHELL or a"
note "                 command. A tunnel-only client (ssh -N / -D / -L, which is"
note "                 how these accounts are used) never asks for one, so NO"
note "                 process ever runs as the account and every socket stays"
note "                 owned by root. nftables matches on the socket owner's UID,"
note "                 so it measures EXACTLY 0 for such an account, forever."
note "                 The panel therefore also runs a socket-level collector"
note "                 ('ssh-sockets') that keys on the CONNECTION instead: it"
note "                 reads the live sockets from 'ss' and asks the daemon's"
note "                 auth log which account authenticated on each one."
note "                 Section 5b checks that path. It is the ONLY thing that can"
note "                 measure a Dropbear tunnel, so if section 5b fails, Dropbear"
note "                 accounts show 0 traffic and 0 online."

hdr "5b. Socket-level path (the only one that can see Dropbear tunnels)"
DROPBEAR_LOG="/var/log/xnet/dropbear.log"
SS_EST=""      # snapshot of established sockets, reused by section 8
SSH_PORTS=""   # ports an SSH daemon listens on

# ss_addr <n> — print the Nth address column of an `ss` row.
# Located by SHAPE, not by index: ss omits the State column when a state filter
# is given, and whether it does varies by iproute2 version, so a fixed field
# number is wrong on half the hosts. This mirrors exactly how the collector
# parses the same rows.
ss_addr() {
  awk -v want="$1" '{n=0; for(i=1;i<=NF;i++) if ($i ~ /:[0-9]+$/ && $i !~ /^users:/) {n++; if(n==want){print $i; next}}}'
}
ss_port() { ss_addr "$1" | sed 's/.*://'; }

# (a) can the panel read the live sockets, with byte counters?
if ! command -v ss >/dev/null 2>&1; then
  fail "'ss' is not installed — the socket-level collector cannot run at all"
  note "Fix: apt-get install -y iproute2"
else
  pass "ss present ($(ss -V 2>/dev/null))"
  # ss output is captured ONCE into a variable rather than piped into grep.
  # This script runs under `set -o pipefail`, and `ss … | grep -q` makes grep
  # exit on its first match, which SIGPIPEs ss (exit 141) and turns the whole
  # pipeline into a failure — so a host with plenty of sockets reported "no
  # established TCP sockets" while section 8 happily listed them. Capturing
  # first removes the race entirely, and the snapshot is reused below.
  SS_EST="$(ss -tinpH state established 2>/dev/null || true)"
  if printf '%s' "$SS_EST" | grep -Eq 'bytes_sent:|bytes_acked:'; then
    pass "ss -i reports per-socket byte counters"
  elif [ -n "$SS_EST" ]; then
    fail "ss -i reports no bytes_sent/bytes_acked — iproute2 is too old to measure sockets"
    note "Fix: apt-get install --only-upgrade iproute2"
  else
    note "no established TCP sockets right now — connect a client and re-run"
  fi
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    if sudo -u "$SERVICE_USER" sudo -n ss -tinpH state established >/dev/null 2>&1; then
      pass "'$SERVICE_USER' can run 'sudo -n ss'"
    else
      fail "'$SERVICE_USER' cannot run 'sudo -n ss' — it cannot see which process owns a socket"
      note "Fix: ensure /etc/sudoers.d/xnet has the ss rule, then: visudo -c"
    fi
  fi
fi

# (b) is the Dropbear listening port discoverable? Without it the collector
# cannot tell a client's own connection from the sockets that session forwards,
# and it refuses to guess.
SS_LISTEN="$(ss -tlnpH 2>/dev/null || true)"
# The exact set the collector computes: ports listened on by an SSH daemon.
SSH_PORTS="$(printf '%s\n' "$SS_LISTEN" |
             grep -E '"(dropbear|sshd|sshd-session)"' |
             ss_port 1 | sort -un | tr '\n' ' ')"
if [ -n "$(printf '%s' "$SSH_PORTS" | tr -d ' ')" ]; then
  pass "SSH daemon listening port(s) visible to ss: $SSH_PORTS"
else
  fail "no SSH daemon listening port is visible to ss"
  note "Without this the collector cannot tell a client's own connection from"
  note "the sockets that session forwards, and it refuses to guess — so it"
  note "measures nothing at all. Check that dropbear/sshd is running."
fi

# (c) the auth log. This is the ONLY record of which account owns a root-held
# connection; without it nothing can be attributed.
auth_ok=0
if [ -f "$DROPBEAR_LOG" ]; then
  perm="$(stat -c '%a' "$DROPBEAR_LOG" 2>/dev/null)"
  if [ -r "$DROPBEAR_LOG" ] && sudo -u "$SERVICE_USER" test -r "$DROPBEAR_LOG" 2>/dev/null; then
    pass "$DROPBEAR_LOG exists and is readable by '$SERVICE_USER' (mode $perm)"
    auth_ok=1
  else
    fail "$DROPBEAR_LOG exists but '$SERVICE_USER' cannot read it (mode $perm)"
    note "Fix: chmod 0644 $DROPBEAR_LOG"
  fi
  if grep -q 'auth succeeded' "$DROPBEAR_LOG" 2>/dev/null; then
    pass "it contains authentication lines ($(grep -c 'auth succeeded' "$DROPBEAR_LOG" 2>/dev/null) so far)"
  else
    note "no 'auth succeeded' line yet — connect a Dropbear client and re-run"
  fi
else
  fail "$DROPBEAR_LOG does not exist — Dropbear is not logging where the panel reads"
  note "The unit must carry StandardError=append:$DROPBEAR_LOG."
  note "Fix: re-run the installer, or apply SSH settings from the panel."
  if [ -f /etc/systemd/system/dropbear.service.d/20-xnet-logging.conf ]; then
    note "The drop-in IS present — check 'systemctl status dropbear' for a rejected"
    note "directive (append: needs systemd 240+) and 'journalctl -u dropbear'."
  fi
fi
# The journal fallback is checked ALWAYS, not only when the file is missing.
# A present-but-stale log file is the trap: dropbear keeps writing to the
# journal until it is RESTARTED, so the file can exist, be readable, and hold
# one line from months ago while every live session is recorded only in the
# journal. Reporting "auth source OK" on file existence alone would hide that.
journal_ok=0
if id "$SERVICE_USER" >/dev/null 2>&1; then
  if sudo -u "$SERVICE_USER" journalctl -q -n1 -t dropbear >/dev/null 2>&1 &&
     [ -n "$(sudo -u "$SERVICE_USER" journalctl -q -n1 -t dropbear 2>/dev/null)" ]; then
    pass "'$SERVICE_USER' can read the journal directly (systemd-journal group)"
    journal_ok=1
  elif sudo -u "$SERVICE_USER" sudo -n journalctl -q -n1 -t dropbear >/dev/null 2>&1; then
    pass "'$SERVICE_USER' can read the journal via sudo (fallback)"
    journal_ok=1
  else
    note "'$SERVICE_USER' cannot read the journal — $DROPBEAR_LOG is the only source"
  fi
fi
if [ "$auth_ok" = "0" ] && [ "$journal_ok" = "0" ]; then
  fail "no auth source at all — Dropbear sessions CANNOT be attributed to an account"
  note "They will show 0 online and 0 traffic. Re-run the installer: it adds the"
  note "journalctl sudoers rule and makes dropbear log to $DROPBEAR_LOG."
fi
# Is dropbear ACTUALLY writing to the file, or still only to the journal? The
# directive only takes effect on RESTART, so a unit that carries it can still be
# logging nowhere the panel looks.
UNIT_TEXT="$(cat /etc/systemd/system/dropbear.service \
                 /etc/systemd/system/dropbear.service.d/*.conf 2>/dev/null || true)"
if ! printf '%s' "$UNIT_TEXT" | grep -q 'append:'; then
  fail "the dropbear unit has no 'append:' logging directive"
  note "Fix: re-run the installer, then: systemctl restart dropbear"
elif [ -f "$DROPBEAR_LOG" ] && [ -z "$(find "$DROPBEAR_LOG" -newermt '-30 minutes' 2>/dev/null)" ]; then
  note "$DROPBEAR_LOG has not been written to in 30 minutes."
  note "     If clients ARE connecting, dropbear was never restarted after the"
  note "     directive was added and is still logging only to the journal."
  note "     Fix: systemctl restart dropbear"
fi

# (d) THE decisive check: run the collector's own algorithm and show its result.
#
# Everything above proves the ingredients exist. This proves they combine. The
# collector keeps only connections whose LOCAL port is a daemon listening port
# (a tunnel-only session also owns one socket per site the client is browsing,
# under the same root PID — counting those would bill the payload twice and
# report one "session" per open site), then asks the auth log which account
# owns each. A connection that survives the first step but not the second is
# unattributable: it is measured by nothing and shows as nobody.
note ""
note "what the collector actually sees right now:"
# Read the auth sources AS THE PANEL DOES — as '$SERVICE_USER', in the same
# order, with the same sudo fallback. Reading them as root (this script's own
# identity) would pass on a host where the panel itself can see nothing, which
# is precisely the failure worth catching: the file can exist and be current
# while the service user has no way to reach it.
_jargs="--no-pager -q -o short-iso --since"
AUTH_TEXT="$( { sudo -u "$SERVICE_USER" cat "$DROPBEAR_LOG" 2>/dev/null;
                sudo -u "$SERVICE_USER" journalctl $_jargs '6 hours ago' \
                     -t dropbear -t sshd -t sshd-session 2>/dev/null;
                sudo -u "$SERVICE_USER" sudo -n journalctl $_jargs '6 hours ago' \
                     -t dropbear -t sshd -t sshd-session 2>/dev/null; } || true)"
n_client=0; n_attr=0
while read -r ln; do
  [ -z "$ln" ] && continue
  case "$ln" in [!\ \	]*) ;; *) continue ;; esac   # skip `ss -i` continuation lines
  lport="$(printf '%s\n' "$ln" | ss_port 1)"
  [ -z "$lport" ] && continue
  case " $SSH_PORTS " in *" $lport "*) ;; *) continue ;; esac
  cpid="$(printf '%s' "$ln" | grep -oE 'pid=[0-9]+' | head -1 | sed 's/pid=//')"
  [ -z "$cpid" ] && continue
  n_client=$((n_client+1))
  peer="$(printf '%s\n' "$ln" | ss_addr 2)"

  # The collector's FIRST test, which this section used to skip: does a regular
  # user own the connection? That is the OpenSSH shape — the session runs AS the
  # account, so nftables measures it by UID and the socket-level collector
  # deliberately leaves it alone. Reporting those as UNATTRIBUTED (as this did)
  # marked a perfectly healthy SSH TCP account as broken.
  owner=""
  for p in $(printf '%s' "$ln" | grep -oE 'pid=[0-9]+' | sed 's/pid=//'); do
    u="$(stat -c '%U' "/proc/$p" 2>/dev/null)"
    uid="$(id -u "$u" 2>/dev/null || echo 0)"
    if [ "${uid:-0}" -ge 1000 ] && [ "${uid:-0}" -lt 65534 ]; then owner="$u"; break; fi
  done
  if [ -n "$owner" ]; then
    n_attr=$((n_attr+1))
    printf '         %-22s pid=%-8s -> %s (measured by UID / nftables)\n' "$peer" "$cpid" "$owner"
    continue
  fi

  who="$(printf '%s\n' "$AUTH_TEXT" |
         grep -E "\[$cpid\].*auth succeeded for '" |
         tail -1 | sed "s/.*auth succeeded for '\([^']*\)'.*/\1/")"
  if [ -n "$who" ]; then
    n_attr=$((n_attr+1))
    printf '         %-22s pid=%-8s -> %s (measured by socket / auth log)\n' "$peer" "$cpid" "$who"
  else
    printf '         %-22s pid=%-8s -> UNATTRIBUTED\n' "$peer" "$cpid"
  fi
done <<EOF
$SS_EST
EOF
if [ "$n_client" -eq 0 ]; then
  note "         (no client connection on an SSH port right now — connect and re-run)"
elif [ "$n_attr" -eq "$n_client" ]; then
  pass "all $n_client live SSH connection(s) resolve to an account — the path works"
  note "Those accounts must show that many online sessions and growing traffic."
else
  fail "$((n_client - n_attr)) of $n_client live SSH connection(s) are UNATTRIBUTED"
  note "Those are root-held (Dropbear) connections with no auth-log line. Their"
  note "traffic is measured by nothing and they show as 0 online. It happens when"
  note "dropbear started logging to $DROPBEAR_LOG only AFTER"
  note "they connected. Reconnect those clients and re-run; if it persists, the"
  note "log line format is not being recognised — send section 5b to support."
fi

# (e) what the panel actually decided.
if command -v journalctl >/dev/null 2>&1; then
  echo "  panel log for the socket-level collector:"
  journalctl -u xnet --since '30 min ago' 2>/dev/null |
    grep -iE 'ssh-sockets|socket-level|SSHAuth' | tail -8 | sed 's/^/    /'
  note "(no lines usually means the collector never initialised — see (a) above)"
fi

hdr "6. Database side of the pipeline"
if [ -n "$DB" ]; then
  python3 - "$DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=3)
try:
    tr = db.execute("SELECT COUNT(*), COALESCE(SUM(total_bytes),0) FROM traffic_records").fetchone()
    print("  traffic_records : %d row(s), %d bytes total" % tr)
except Exception as e:
    print("  traffic_records : unavailable (%s)" % e)
rows = db.execute(
    "SELECT username, traffic_used_bytes, traffic_limit_bytes, last_connection_at "
    "FROM ssh_accounts ORDER BY traffic_used_bytes DESC LIMIT 10").fetchall()
print("  ssh_accounts (top 10 by usage):")
for u, used, limit, last in rows:
    print("    %-20s used=%-14d limit=%-14d last_seen=%s" % (u, used or 0, limit or 0, last or "never"))
PY
  note ""
  note "Reading it: kernel counters > 0 but traffic_records at 0 means the quota"
  note "worker is not draining them (check the panel log for [QuotaWorker])."
  note "traffic_records > 0 but ssh_accounts at 0 means the username in the"
  note "counter does not match any ssh_accounts.username."
else
  fail "no panel DB — cannot inspect the database side"
fi

hdr "7. Panel log"
if command -v journalctl >/dev/null 2>&1; then
  echo "  last accounting-related lines:"
  journalctl -u xnet --since '30 min ago' 2>/dev/null |
    grep -iE 'quotaworker|nftables|traffic|Registered SSH user|could not resolve' |
    tail -15 | sed 's/^/    /'
  note "(nothing above usually means the traffic engine never started)"
fi

# ---------------------------------------------------------------------------
# Per-account deep dive. Traffic accounting and the online-session count are
# two different mechanisms that happen to fail together for the same reason:
# both need a process running as the ACCOUNT's own Linux user.
#
#   traffic : nftables matches on the socket owner's UID, so the account's UID
#             must be in the accounting sets AND its forwarded sockets must be
#             opened by a process running as that UID.
#   online  : the monitor scans `ps` for sshd/dropbear processes NOT owned by
#             root and attributes them by username.
#
# An account that authenticates but whose session never runs as that user shows
# zero for both — which is exactly the "connects and works, but nothing is
# measured" symptom.
# ---------------------------------------------------------------------------
hdr "8. Per-account deep dive${FOCUS_USER:+ — $FOCUS_USER}"
if [ -z "$FOCUS_USER" ]; then
  note "Re-run with an account name for this section, e.g.:"
  note "    bash $(basename "$0") koskesh1"
else
  u="$FOCUS_USER"

  # --- the Linux user --------------------------------------------------------
  if ! id "$u" >/dev/null 2>&1; then
    fail "'$u' has NO Linux user — it can be neither measured nor logged in"
  else
    uid="$(id -u "$u")"
    pass "Linux user exists: uid=$uid groups=$(id -nG "$u" 2>/dev/null)"

    # Shell and home matter for Dropbear specifically. Dropbear forks and
    # setuids ONLY to run a shell; if that fork cannot execute, no process ever
    # runs as the account, so neither the online count nor the UID-keyed byte
    # counters can see the session — while the tunnel itself keeps working.
    shell="$(getent passwd "$u" | cut -d: -f7)"
    home="$(getent passwd "$u" | cut -d: -f6)"
    note "passwd entry : shell=$shell home=$home"
    if [ ! -x "$shell" ]; then
      fail "shell '$shell' is missing or not executable — Dropbear cannot fork a session as this user"
    else
      pass "shell '$shell' is executable"
    fi
    if [ ! -d "$home" ]; then
      fail "home directory '$home' does not exist (useradd -m may have failed during a bulk import)"
    else
      pass "home directory exists"
    fi
    # The UID resolver only caches regular accounts; a UID outside this window
    # can never be mapped back to a username, so its counters are unattributable.
    if [ "$uid" -lt 1000 ] || [ "$uid" -ge 65534 ]; then
      fail "UID $uid is outside the 1000..65533 range the panel's UID resolver caches"
      note "     Its kernel counters can never be attributed back to '$u'."
    fi
    # --- registered for accounting? ------------------------------------------
    if printf '%s' "$in_elems$out_elems" | grep -q "\"val\": *$uid\b"; then
      pass "UID $uid IS registered in the accounting sets"
      pu="$(nft -j list set inet "$TABLE" "$IN_SET" 2>/dev/null |
            tr '{' '\n' | grep -A6 "\"val\": *$uid\b" | grep -o '"bytes": *[0-9]*' |
            grep -o '[0-9]*' | head -1)"
      po="$(nft -j list set inet "$TABLE" "$OUT_SET" 2>/dev/null |
            tr '{' '\n' | grep -A6 "\"val\": *$uid\b" | grep -o '"bytes": *[0-9]*' |
            grep -o '[0-9]*' | head -1)"
      note "kernel counters: upload=${pu:-0} bytes  download=${po:-0} bytes"
      if [ "${pu:-0}" = "0" ] && [ "${po:-0}" = "0" ]; then
        note "both nftables counters are ZERO for this account."
        note "     Expected for a Dropbear account: no process runs as '$u', so no"
        note "     socket carries its UID. Its traffic is measured by the"
        note "     socket-level collector instead — check section 5b and the"
        note "     'live connections' block below."
        note "     For an SSH TCP account this IS the fault: either no session"
        note "     ran as '$u', or it forwarded nothing."
      fi
    else
      fail "UID $uid is NOT in the accounting sets — traffic cannot be counted"
      note "     The panel re-registers every account at startup and every 2 min."
      note "     If it stays missing, check section 2 (can the panel run nft?)."
    fi
  fi

  # --- live sessions ---------------------------------------------------------
  note ""
  note "processes currently owned by '$u' (this is what the online count reads):"
  ps -eo user=,pid=,lstart=,args= 2>/dev/null | awk -v U="$u" '$1==U' | sed 's/^/         /'
  n_proc="$(ps -eo user= 2>/dev/null | grep -cx "$u" || true)"
  if [ "${n_proc:-0}" -eq 0 ]; then
    note "         (none)"
    note "no process runs as '$u' right now. Under Dropbear that is NORMAL even"
    note "     with clients connected — it setuids only to run a shell — which is"
    note "     why the panel also tracks sessions by connection (next block)."
  else
    pass "$n_proc process(es) run as '$u'"
  fi

  # --- live connections attributed by the socket-level path -------------------
  # This is what the panel counts for a Dropbear account: the client's own
  # connections, matched to '$u' through the auth log. Forwarded sockets share
  # the same root PID and are deliberately excluded here, exactly as the panel
  # excludes them.
  note ""
  note "live connections attributed to '$u' (what online/traffic now read):"
  # PIDs come from BOTH sources the panel uses, because an account has only one
  # of them depending on its method. An OpenSSH account's session runs AS the
  # account, so its PIDs are simply the processes it owns — listing only the
  # auth-log PIDs (the Dropbear path) printed nothing at all for SSH TCP
  # accounts, making a working account look dead.
  auth_pids="$( { cat "$DROPBEAR_LOG" 2>/dev/null;
                  journalctl --since '2 hours ago' -t dropbear -t sshd -t sshd-session --no-pager -q 2>/dev/null; } |
                grep -E "auth succeeded for '$u'|Accepted [a-z]+ for $u " |
                grep -oE '\[[0-9]+\]' | tr -d '[]' | sort -u | tr '\n' ' ')"
  owned_pids="$(ps -u "$u" -o pid= 2>/dev/null | tr -d ' ' | tr '\n' ' ')"
  auth_pids="$(printf '%s %s' "$auth_pids" "$owned_pids" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' ')"
  if [ -z "$(printf '%s' "$auth_pids" | tr -d ' ')" ]; then
    note "         (no authentication ever logged for this account)"
  else
    n_conn=0
    for p in $auth_pids; do
      # Only the CLIENT's own connection counts. A tunnel-only session owns one
      # socket per site the client is browsing, all under this same root PID —
      # listing those would show a random destination server as the user's
      # session and make one connected client look like dozens. The client's
      # connection is the one whose LOCAL port is the daemon's listening port.
      while read -r ln; do
        [ -z "$ln" ] && continue
        case "$ln" in [!\ \	]*) ;; *) continue ;; esac
        printf '%s' "$ln" | grep -q "pid=$p," || continue
        lport="$(printf '%s\n' "$ln" | ss_port 1)"
        case " $SSH_PORTS " in *" $lport "*) ;; *) continue ;; esac
        n_conn=$((n_conn+1))
        printf '         pid=%-8s %s <- %s\n' "$p" \
          "$(printf '%s\n' "$ln" | ss_addr 1)" "$(printf '%s\n' "$ln" | ss_addr 2)"
      done <<EOF
$SS_EST
EOF
    done
    if [ "$n_conn" -eq 0 ]; then
      note "         (authenticated in the past, nothing connected right now)"
    else
      pass "$n_conn live connection(s) — this is the account's online count"
    fi
  fi

  # --- what the daemons logged ----------------------------------------------
  note ""
  note "recent authentications for '$u':"
  journalctl -u ssh -u sshd -u sshd-ws -u sshd-tls -u sshd-dns -u dropbear \
    --since '2 hours ago' --no-pager 2>/dev/null |
    grep -iE "$u" | tail -12 | sed 's/^/         /'

  # --- what the panel stored -------------------------------------------------
  if [ -n "$DB" ]; then
    note ""
    note "database rows for '$u':"
    python3 - "$DB" "$u" <<'PY' 2>/dev/null | sed 's/^/         /'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=3); u = sys.argv[2]
r = db.execute("SELECT method, port, enabled, status, traffic_used_bytes, "
               "online_sessions, COALESCE(last_connection_at,'never') "
               "FROM ssh_accounts WHERE username=?", (u,)).fetchone()
print("ssh_accounts    : %s" % (r,) if r else "ssh_accounts    : NO ROW")
try:
    t = db.execute("SELECT uid, rx_bytes, tx_bytes, total_bytes, source "
                   "FROM traffic_records WHERE username=?", (u,)).fetchone()
    print("traffic_records : %s" % (t,) if t else "traffic_records : NO ROW (nothing was ever accumulated)")
except Exception as e:
    print("traffic_records : unavailable (%s)" % e)
PY
  fi
fi

hdr "Summary"
if [ "$fails" -eq 0 ]; then
  echo "  Pipeline looks healthy. Both SSH paths are in play, and which one"
  echo "  measures an account depends on its daemon:"
  echo "    SSH TCP  -> nftables, counting the sockets the sshd child opens as"
  echo "                the account. The SSH channel itself is never counted."
  echo "    Dropbear -> the socket-level collector, counting the client's own"
  echo "                connection. That figure INCLUDES SSH framing overhead,"
  echo "                so it reads a few percent above the payload."
else
  echo "  $fails check(s) failed — fix the first FAIL above, then re-run."
  echo "  A section-1..4 failure only affects SSH TCP accounts; a section-5b"
  echo "  failure is what makes Dropbear accounts show 0 online and 0 traffic."
fi
