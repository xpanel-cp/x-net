#!/usr/bin/env bash
# ============================================================
#  xnet — X-NET Panel management CLI
#
#  Installed to /usr/local/bin/xnet by install.sh. Run `xnet`
#  (as root) on the server for an interactive management menu:
#    1) Install / repair prerequisites
#    2) Update the panel (latest release)
#    3) Panel port & login-path settings
#    4) Project health check
#    5) Restart services (panel / sing-box)
#
#  Non-interactive subcommands are also supported, e.g.:
#    xnet update | xnet health | xnet deps | xnet config | xnet restart
# ============================================================

set -Eeuo pipefail

INSTALL_DIR="/opt/xnet"
ENV_FILE="${INSTALL_DIR}/.env"
REPO="xpanel-cp/x-net"
ONLINE_INSTALLER="https://raw.githubusercontent.com/${REPO}/main/install/xnet.sh"

C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "${C_BLU}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GRN}[✓]${C_RESET} $*"; }
warn() { echo -e "${C_YLW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

need_root() { [ "$(id -u)" -eq 0 ] || { err "Please run as root:  sudo xnet"; exit 1; }; }

# env_get KEY → prints the value of KEY from .env (empty if absent).
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-
}

# env_set KEY VALUE → upsert KEY=VALUE in .env, preserving other lines.
env_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  local found=0
  if [ -f "$ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$key="*) echo "$key=$val"; found=1 ;;
        *) echo "$line" ;;
      esac
    done < "$ENV_FILE" > "$tmp"
  fi
  [ "$found" -eq 1 ] || echo "$key=$val" >> "$tmp"
  install -m 600 "$tmp" "$ENV_FILE"
  chown xnet:xnet "$ENV_FILE" 2>/dev/null || true
  rm -f "$tmp"
}

detect_ip() {
  local ip
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-<server-ip>}"
}

# ---- 1) prerequisites -------------------------------------------------------
# free_apt_lock recovers from a stuck/stale dpkg lock (orphaned apt from an
# interrupted run) so `xnet deps` never fails with "Could not get lock".
free_apt_lock() {
  command -v apt-get >/dev/null 2>&1 || return 0
  local waited=0 max_wait=90
  while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f 'unattended-upgr' >/dev/null 2>&1; do
    [ "$waited" -eq 0 ] && info "Waiting for another apt/dpkg process to finish (up to ${max_wait}s)…"
    [ "$waited" -ge "$max_wait" ] && break
    sleep 3; waited=$((waited + 3))
  done
  if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
    warn "A stuck apt/dpkg process is holding the lock — terminating it."
    systemctl stop unattended-upgrades >/dev/null 2>&1 || true
    pkill -9 -x apt-get 2>/dev/null || true
    pkill -9 -x dpkg 2>/dev/null || true
    pkill -9 -f 'unattended-upgr|apt.systemd' 2>/dev/null || true
    sleep 1
  fi
  if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
  fi
}

do_deps() {
  need_root
  info "Installing / repairing prerequisites…"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    free_apt_lock
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y curl wget openssl jq iproute2 libcap2-bin sudo tar ca-certificates cron procps net-tools uuid-runtime nftables conntrack certbot >/dev/null 2>&1 \
      || warn "Some apt packages failed to install."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget openssl jq iproute libcap sudo tar ca-certificates cronie procps-ng net-tools nftables conntrack-tools certbot >/dev/null 2>&1 || warn "Some dnf packages failed."
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y curl wget openssl jq iproute libcap sudo tar ca-certificates cronie procps-ng net-tools nftables conntrack-tools certbot >/dev/null 2>&1 || warn "Some yum packages failed."
  else
    warn "No supported package manager found."
  fi
  command -v certbot >/dev/null 2>&1 && ok "certbot present — SSL issuance available." || warn "certbot still missing."
  command -v nft >/dev/null 2>&1 && ok "nftables present — SSH traffic accounting available." || warn "nftables (nft) still missing — Direct SSH traffic won't be measured."
  command -v sing-box >/dev/null 2>&1 && ok "sing-box present ($(sing-box version 2>/dev/null | head -n1))." || warn "sing-box not found — re-run the installer to install it."
  ok "Prerequisite check complete."
}

# ---- 2) update --------------------------------------------------------------
do_update() {
  need_root
  info "Updating the panel from the latest release…"
  if command -v curl >/dev/null 2>&1; then
    bash <(curl -fsSL "$ONLINE_INSTALLER") "${1:-}"
  else
    err "curl is required to update. Install it first:  xnet deps"
    return 1
  fi
}

# ---- 3) port & login path ---------------------------------------------------
do_config() {
  need_root
  local cur_port cur_path
  cur_port="$(env_get PORT)"; cur_port="${cur_port:-8080}"
  cur_path="$(env_get WEB_BASE_PATH)"
  local ip; ip="$(detect_ip)"

  echo
  echo -e "${C_BOLD}Panel access settings${C_RESET}"
  echo -e "  Current URL : http://${ip}:${cur_port}/${cur_path}"
  echo

  read -r -p "  New port [${cur_port}] (Enter to keep): " new_port
  new_port="${new_port:-$cur_port}"
  if ! echo "$new_port" | grep -qE '^[0-9]+$' || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
    err "Invalid port."; return 1
  fi

  echo "  Login path: 8–12 chars, English letters and digits only."
  echo "  (leave empty to serve at root, or type 'gen' for a random one)"
  read -r -p "  New login path [${cur_path}] (Enter to keep): " new_path
  if [ -z "${new_path+x}" ]; then new_path="$cur_path"; fi
  new_path="${new_path:-$cur_path}"
  if [ "$new_path" = "gen" ]; then
    local n=$(( 8 + RANDOM % 5 ))
    new_path="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$n")"
  fi
  if [ -n "$new_path" ]; then
    if ! echo "$new_path" | grep -qE '^[A-Za-z0-9]{8,12}$'; then
      err "Login path must be 8–12 characters, English letters and digits only."; return 1
    fi
  fi

  env_set PORT "$new_port"
  env_set WEB_BASE_PATH "$new_path"
  ok "Saved. New URL: http://${ip}:${new_port}/${new_path}"

  # Reopen firewall for the new port (best-effort).
  if command -v ufw >/dev/null 2>&1; then ufw allow "${new_port}/tcp" >/dev/null 2>&1 || true; fi
  if command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true; fi

  read -r -p "  Restart the panel now to apply? [Y/n]: " yn
  case "${yn:-Y}" in
    [nN]*) warn "Not restarted. Run 'xnet restart' or 'systemctl restart xnet' to apply." ;;
    *) systemctl restart xnet && ok "Panel restarted." || err "Restart failed; check: journalctl -u xnet -n 30" ;;
  esac
}

# ---- 4) health check --------------------------------------------------------
do_health() {
  need_root
  echo -e "${C_BOLD}=== X-NET health check ===${C_RESET}"
  local port path ip
  port="$(env_get PORT)"; port="${port:-8080}"
  path="$(env_get WEB_BASE_PATH)"
  ip="$(detect_ip)"

  for svc in xnet sing-box; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "service ${svc}: active"
    else
      warn "service ${svc}: NOT active"
    fi
  done

  command -v certbot >/dev/null 2>&1 && ok "certbot: installed" || warn "certbot: missing (SSL issuance unavailable)"
  command -v nft >/dev/null 2>&1 && ok "nftables (nft): installed" || warn "nftables (nft): missing (Direct SSH traffic not measured)"
  command -v ps >/dev/null 2>&1 && ok "ps (procps): installed" || warn "ps (procps): missing (SSH online count = 0)"
  command -v sing-box >/dev/null 2>&1 && ok "sing-box binary: present" || warn "sing-box binary: missing"
  [ -f "${INSTALL_DIR}/xnet-server" ] && ok "panel binary: present" || warn "panel binary: missing"
  [ -d "${INSTALL_DIR}/dist" ] && ok "frontend dist: present" || warn "frontend dist: missing"
  [ -f "${INSTALL_DIR}/data/xnet.db" ] && ok "database: present" || warn "database: missing"

  # Clash API reachability — the source of VPN (sing-box) per-client traffic.
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "http://127.0.0.1:20091/connections" >/dev/null 2>&1; then
      ok "sing-box Clash API (127.0.0.1:20091): reachable — VPN traffic accounting works"
    else
      warn "sing-box Clash API (127.0.0.1:20091): NOT reachable — VPN traffic will show 0"
      warn "  → ensure sing-box is running and its config has the clash_api block (regenerate from the panel)"
    fi
  fi

  # Local API ping.
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/v1/ping" >/dev/null 2>&1; then
      ok "API ping: OK (port ${port})"
    else
      warn "API ping: failed on port ${port}"
    fi
  fi

  # Run the bundled deep healthcheck if present (installed as 'healthcheck',
  # falling back to the .sh name).
  local hc=""
  for cand in "${INSTALL_DIR}/healthcheck" "${INSTALL_DIR}/healthcheck.sh"; do
    [ -x "$cand" ] && { hc="$cand"; break; }
  done
  if [ -n "$hc" ]; then
    echo
    info "Running deep health check (${hc})…"
    bash "$hc" || true
  fi
  echo
  echo -e "  Panel URL: http://${ip}:${port}/${path}"
}

# ---- 5) restart -------------------------------------------------------------
do_restart() {
  need_root
  local target="${1:-}"
  if [ -z "$target" ]; then
    echo "  1) panel (xnet)"
    echo "  2) sing-box"
    echo "  3) both"
    read -r -p "  Restart which? [1]: " r; r="${r:-1}"
    case "$r" in 1) target=xnet ;; 2) target=sing-box ;; 3) target=both ;; *) target=xnet ;; esac
  fi
  case "$target" in
    xnet)     systemctl restart xnet && ok "panel restarted." ;;
    sing-box) systemctl restart sing-box && ok "sing-box restarted." ;;
    both)     systemctl restart sing-box || true; systemctl restart xnet && ok "panel + sing-box restarted." ;;
    *)        err "Unknown target: $target" ;;
  esac
}

menu() {
  while true; do
    echo
    echo -e "${C_BOLD}╔════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║            X-NET Management CLI             ║${C_RESET}"
    echo -e "${C_BOLD}╚════════════════════════════════════════════╝${C_RESET}"
    echo "  1) Install / repair prerequisites"
    echo "  2) Update the panel (latest release)"
    echo "  3) Panel port & login-path settings"
    echo "  4) Project health check"
    echo "  5) Restart services (panel / sing-box)"
    echo "  0) Exit"
    read -r -p "  Choose: " c
    case "$c" in
      1) do_deps ;;
      2) do_update ;;
      3) do_config ;;
      4) do_health ;;
      5) do_restart ;;
      0|q|Q) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

case "${1:-}" in
  deps|prereq|prerequisites) do_deps ;;
  update|upgrade)            shift || true; do_update "${1:-}" ;;
  config|port|path)          do_config ;;
  health|healthcheck|check)  do_health ;;
  restart)                   shift || true; do_restart "${1:-}" ;;
  ""|menu)                   menu ;;
  -h|--help|help)
    echo "Usage: xnet [deps|update|config|health|restart] (no args = interactive menu)"
    ;;
  *)
    err "Unknown command: $1"; echo "Run 'xnet help' for usage."; exit 1 ;;
esac
