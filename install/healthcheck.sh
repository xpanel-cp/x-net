#!/usr/bin/env bash
# ============================================================
#  X-Net Panel — Health & Subscription Test
#
#  Runs an end-to-end check of a running X-Net panel:
#    service, port, API health, frontend, login, protected APIs,
#    subscriptions (base64/json/clash), and sing-box traffic stats.
#
#  Usage:
#    sudo bash healthcheck.sh
#    bash healthcheck.sh --port 8080 --user admin --pass 'secret'
#    bash healthcheck.sh --host 203.0.113.10 --port 8080 --user admin --pass 'secret'
#
#  Flags (all optional — you will be prompted for missing ones):
#    --host HOST   Host/IP to test            (default: 127.0.0.1)
#    --port PORT   Panel port                 (default: from /opt/xnet/.env or 8080)
#    --user NAME   Admin username             (default: from .env or 'admin')
#    --pass PASS   Admin password             (prompted hidden if omitted)
#    --no-color    Disable colored output
# ============================================================

set -uo pipefail   # NOTE: not -e — we want to run every check and tally results.

# ----- args ------------------------------------------------------------------
HOST="127.0.0.1"
PORT=""
USER_NAME=""
PASS=""
USE_COLOR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --pass) PASS="${2:-}"; shift 2 ;;
    --no-color) USE_COLOR=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

if [ "$USE_COLOR" -eq 1 ]; then
  C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
  C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_BOLD='\033[1m'
else
  C_RESET=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_BOLD=''
fi

PASS_N=0; FAIL_N=0; WARN_N=0
ok()    { echo -e "  ${C_GRN}[PASS]${C_RESET} $*"; PASS_N=$((PASS_N+1)); }
bad()   { echo -e "  ${C_RED}[FAIL]${C_RESET} $*"; FAIL_N=$((FAIL_N+1)); }
warn()  { echo -e "  ${C_YLW}[WARN]${C_RESET} $*"; WARN_N=$((WARN_N+1)); }
note()  { echo -e "  ${C_BLU}[..]${C_RESET}  $*"; }
head()  { echo; echo -e "${C_BOLD}== $* ==${C_RESET}"; }

ENV_FILE="/opt/xnet/.env"

# ----- helpers ---------------------------------------------------------------
env_get() {
  # read KEY from /opt/xnet/.env if present
  local key="$1"
  [ -r "$ENV_FILE" ] || return 1
  local line; line="$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -n1)"
  [ -n "$line" ] || return 1
  echo "${line#*=}"
}

have() { command -v "$1" >/dev/null 2>&1; }

# HTTP GET; echoes status code, writes body to $BODY_FILE
BODY_FILE="$(mktemp)"
http_code() {
  # args: METHOD URL [extra curl args...]
  local method="$1" url="$2"; shift 2
  curl -s -o "$BODY_FILE" -w "%{http_code}" -X "$method" "$@" "$url" 2>/dev/null
}
cleanup() { rm -f "$BODY_FILE"; }
trap cleanup EXIT

# ----- resolve config --------------------------------------------------------
have curl || { echo "curl is required. Install it first (apt install -y curl / dnf install -y curl)."; exit 1; }

if [ -z "$PORT" ]; then PORT="$(env_get PORT || true)"; fi
if [ -z "$PORT" ]; then PORT="8080"; fi
if [ -z "$USER_NAME" ]; then USER_NAME="$(env_get ADMIN_USERNAME || true)"; fi
if [ -z "$USER_NAME" ]; then USER_NAME="admin"; fi
if [ -z "$PASS" ]; then
  # Try to reuse the password from .env (only readable as root).
  PASS="$(env_get ADMIN_PASSWORD || true)"
fi
if [ -z "$PASS" ]; then
  read -r -s -p "Admin password for '${USER_NAME}': " PASS; echo
fi

BASE="http://${HOST}:${PORT}"
JQ=0; have jq && JQ=1

echo -e "${C_BOLD}X-Net health check${C_RESET}"
echo "  Target : $BASE"
echo "  User   : $USER_NAME"
[ "$JQ" -eq 1 ] || warn "jq not installed — JSON parsing is limited. (apt install -y jq / dnf install -y jq)"

# ----- 1. systemd service ----------------------------------------------------
head "1. Service"
if have systemctl; then
  state="$(systemctl is-active xnet 2>/dev/null || true)"
  if [ "$state" = "active" ]; then ok "xnet service is active"
  else bad "xnet service state: ${state:-unknown} (try: journalctl -u xnet -n 50 --no-pager)"; fi
else
  note "systemctl not available (Docker install?) — skipping service check"
fi

# ----- 2. listening ports ----------------------------------------------------
head "2. Listening ports"
if have ss; then
  if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then ok "panel port ${PORT} is listening"
  else bad "panel port ${PORT} is NOT listening"; fi
  if ss -ltn 2>/dev/null | grep -q ":20091 "; then ok "sing-box Clash API port 20091 is listening"
  else warn "sing-box Clash API port 20091 not listening (traffic stats will be degraded)"; fi
else
  note "ss not available — skipping port check"
fi

# ----- 3. API health ---------------------------------------------------------
head "3. API health"
code="$(http_code GET "$BASE/api/v1/ping")"
body="$(cat "$BODY_FILE")"
if [ "$code" = "200" ] && echo "$body" | grep -q '"status":"ok"'; then
  ok "GET /api/v1/ping → 200 ok"
else
  bad "GET /api/v1/ping → HTTP ${code} body=${body:0:120}"
fi

# ----- 4. frontend served ----------------------------------------------------
head "4. Frontend"
code="$(http_code GET "$BASE/")"
body="$(cat "$BODY_FILE")"
if [ "$code" = "200" ] && echo "$body" | grep -qi '<!doctype html\|<div id="root"\|<html'; then
  ok "GET / serves the SPA (HTML)"
else
  bad "GET / → HTTP ${code} (frontend not served? STATIC_DIR set?)"
fi

# ----- 5. login --------------------------------------------------------------
head "5. Login"
code="$(http_code POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d "{\"username\":\"${USER_NAME}\",\"password\":$(printf '%s' "$PASS" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')}")"
body="$(cat "$BODY_FILE")"
TOKEN=""
REQ2FA=0
if [ "$code" = "200" ]; then
  if [ "$JQ" -eq 1 ]; then
    TOKEN="$(echo "$body" | jq -r '.token // empty')"
    [ "$(echo "$body" | jq -r '.requires2fa // false')" = "true" ] && REQ2FA=1
  else
    TOKEN="$(echo "$body" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
    echo "$body" | grep -q '"requires2fa":true' && REQ2FA=1
  fi
  if [ -n "$TOKEN" ]; then ok "login succeeded, JWT issued"
  elif [ "$REQ2FA" -eq 1 ]; then warn "login requires 2FA (TOTP) — protected API checks will be skipped"
  else bad "login 200 but no token in response: ${body:0:140}"; fi
else
  bad "POST /api/auth/login → HTTP ${code} body=${body:0:140}"
fi

AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

# ----- 6. protected APIs -----------------------------------------------------
head "6. Protected APIs"
if [ -n "$TOKEN" ]; then
  for ep in "/api/inbounds" "/api/v1/subscribers" "/api/traffic/singbox/summary"; do
    code="$(http_code GET "$BASE$ep" "${AUTH[@]}")"
    if [ "$code" = "200" ]; then ok "GET $ep → 200"
    else bad "GET $ep → HTTP ${code}"; fi
  done
else
  note "no token — skipping protected API checks"
fi

# ----- 7. subscriptions ------------------------------------------------------
head "7. Subscriptions"
SUB_UUID=""
if [ -n "$TOKEN" ]; then
  code="$(http_code GET "$BASE/api/v1/subscribers" "${AUTH[@]}")"
  body="$(cat "$BODY_FILE")"
  if [ "$code" = "200" ]; then
    if [ "$JQ" -eq 1 ]; then
      SUB_UUID="$(echo "$body" | jq -r '.subscribers[0].uuid // empty')"
      COUNT="$(echo "$body" | jq -r '.subscribers | length')"
      note "subscribers found: ${COUNT:-0}"
    else
      SUB_UUID="$(echo "$body" | sed -n 's/.*"uuid":"\([0-9a-fA-F-]\{36\}\)".*/\1/p' | head -n1)"
    fi
  fi
fi

if [ -z "$SUB_UUID" ]; then
  warn "no subscriber found to test (create a client/subscriber in the panel, then re-run)"
else
  note "testing subscription for uuid=${SUB_UUID}"

  # base64 (default)
  code="$(http_code GET "$BASE/api/v1/sub/$SUB_UUID")"
  body="$(cat "$BODY_FILE")"
  if [ "$code" = "200" ] && [ -n "$body" ]; then
    decoded=""
    if have base64; then decoded="$(printf '%s' "$body" | base64 -d 2>/dev/null || true)"; fi
    if echo "$decoded" | grep -qE '(vless|vmess|trojan|ss|hysteria|tuic)://'; then
      ok "base64 subscription decodes to valid links"
      note "first link: $(echo "$decoded" | head -n1 | cut -c1-70)…"
    else
      warn "base64 subscription returned 200 but no recognizable link after decode (maybe no enabled inbound)"
    fi
  else
    bad "GET /api/v1/sub/{uuid} (base64) → HTTP ${code}"
  fi

  # json (sing-box)
  code="$(http_code GET "$BASE/api/v1/sub/$SUB_UUID?format=json")"
  body="$(cat "$BODY_FILE")"
  if [ "$code" = "200" ] && echo "$body" | grep -q '{'; then ok "json (sing-box) subscription → 200"
  else bad "json subscription → HTTP ${code}"; fi

  # clash
  code="$(http_code GET "$BASE/api/v1/sub/$SUB_UUID?format=clash")"
  if [ "$code" = "200" ]; then ok "clash subscription → 200"
  else bad "clash subscription → HTTP ${code}"; fi

  # Subscription-Userinfo header
  hdr="$(curl -s -D - -o /dev/null "$BASE/api/v1/sub/$SUB_UUID" 2>/dev/null | grep -i 'Subscription-Userinfo' || true)"
  if [ -n "$hdr" ]; then ok "Subscription-Userinfo header present"; note "$(echo "$hdr" | tr -d '\r')"
  else warn "Subscription-Userinfo header missing"; fi
fi

# invalid uuid → expect 404
code="$(http_code GET "$BASE/api/v1/sub/00000000-0000-0000-0000-000000000000")"
if [ "$code" = "404" ]; then ok "invalid subscription uuid → 404 (correct)"
else warn "invalid subscription uuid → HTTP ${code} (expected 404)"; fi

# ----- 8. sing-box core & traffic accounting ----------------------------------
head "8. Sing-box core & traffic accounting"

# 8a. sing-box service
if have systemctl; then
  sb_state="$(systemctl is-active sing-box 2>/dev/null || true)"
  if [ "$sb_state" = "active" ]; then ok "sing-box service is active"
  else bad "sing-box service state: ${sb_state:-unknown}"; fi
fi

# 8b. sing-box version check (minimum 1.11 for Clash API /connections)
if have sing-box; then
  sb_ver="$(sing-box version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)"
  if [ -z "$sb_ver" ]; then
    sb_ver="$(sing-box version 2>/dev/null | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\./) print $i}' | head -1)"
  fi
  sb_major="$(echo "$sb_ver" | cut -d. -f1)"
  sb_minor="$(echo "$sb_ver" | cut -d. -f2)"
  if [ -n "$sb_major" ] && [ "$sb_major" -ge 1 ] 2>/dev/null && [ "$sb_minor" -ge 11 ] 2>/dev/null; then
    ok "sing-box version: v${sb_ver} (meets minimum 1.11)"
  else
    bad "sing-box version: v${sb_ver} — too old (need >= 1.11 for /connections metadata)"
  fi
else
  bad "sing-box binary not found in PATH"
fi

# 8c. Clash API reachable
clash_resp="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:20091/connections 2>/dev/null || echo "000")"
if [ "$clash_resp" = "200" ]; then
  ok "Clash API /connections → 200"
  # Show connection count
  conn_count="$(curl -s http://127.0.0.1:20091/connections 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('connections') or []))" 2>/dev/null || echo "?")"
  note "Active connections: ${conn_count}"
else
  bad "Clash API /connections → HTTP ${clash_resp} (sing-box not running or port 20091 blocked)"
fi

# 8d. sing-box config validation (no deprecated dns outbound)
SB_CFG="/etc/sing-box/config.json"
if [ -f "$SB_CFG" ]; then
  if grep -q '"type".*"dns"' "$SB_CFG" 2>/dev/null; then
    bad "sing-box config contains deprecated 'dns' outbound (removed in 1.13) — regenerate via panel"
  else
    ok "sing-box config has no deprecated dns outbound"
  fi
  if grep -q "clash_api" "$SB_CFG" 2>/dev/null; then
    ok "sing-box config has clash_api block"
  else
    bad "sing-box config missing clash_api block (traffic stats will not work)"
  fi
else
  warn "sing-box config not found at ${SB_CFG}"
fi

# 8e. xnet traffic endpoints (requires auth token)
if [ -n "$TOKEN" ]; then
  # Debug endpoint — shows collector cache and live connections
  code="$(http_code GET "$BASE/api/traffic/singbox/debug" "${AUTH[@]}")"
  if [ "$code" = "200" ]; then
    ok "traffic debug endpoint → 200"
    if [ "$JQ" -eq 1 ]; then
      debug_body="$(curl -s "$BASE/api/traffic/singbox/debug" -H "Authorization: Bearer $TOKEN")"
      cache_clients="$(echo "$debug_body" | jq -r '.cache.clients // 0')"
      debug_conns="$(echo "$debug_body" | jq -r '.connectionCount // 0')"
      note "Collector cache: ${cache_clients} clients, ${debug_conns} live connections"
    fi
  else
    bad "traffic debug endpoint → HTTP ${code}"
  fi

  # Realtime endpoint
  code="$(http_code GET "$BASE/api/traffic/singbox/realtime" "${AUTH[@]}")"
  case "$code" in
    200) ok "realtime traffic → 200 (live data available)" ;;
    503) warn "realtime traffic → 503 (no fresh data — is sing-box running with Clash API?)" ;;
    *)   bad "realtime traffic → HTTP ${code}" ;;
  esac

  # Online users endpoint
  code="$(http_code GET "$BASE/api/traffic/singbox/online" "${AUTH[@]}")"
  if [ "$code" = "200" ]; then
    ok "online users endpoint → 200"
    if [ "$JQ" -eq 1 ]; then
      online_count="$(curl -s "$BASE/api/traffic/singbox/online" -H "Authorization: Bearer $TOKEN" | jq '.users | length')"
      note "Online users: ${online_count}"
    fi
  else
    bad "online users endpoint → HTTP ${code}"
  fi
else
  note "no token — skipping traffic/debug/online checks"
fi

# ----- summary ---------------------------------------------------------------
head "Summary"
echo -e "  ${C_GRN}PASS: ${PASS_N}${C_RESET}   ${C_YLW}WARN: ${WARN_N}${C_RESET}   ${C_RED}FAIL: ${FAIL_N}${C_RESET}"
echo
if [ "$FAIL_N" -eq 0 ]; then
  echo -e "${C_GRN}${C_BOLD}Panel looks healthy.${C_RESET}"
  [ "$WARN_N" -gt 0 ] && echo -e "${C_YLW}Review warnings above (often just sing-box not running or no subscribers yet).${C_RESET}"
  exit 0
else
  echo -e "${C_RED}${C_BOLD}Some checks failed.${C_RESET} Inspect logs:  journalctl -u xnet -n 50 --no-pager"
  exit 1
fi
