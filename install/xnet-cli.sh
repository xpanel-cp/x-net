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
  # The endpoint is protected by a Bearer secret, so an unauthenticated probe
  # returns 401/403 — that still proves the API is UP (the panel collector holds
  # the matching secret). Only a connection failure means it is truly down.
  if command -v curl >/dev/null 2>&1; then
    clash_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:20091/connections" 2>/dev/null || echo 000)"
    case "$clash_code" in
      200|401|403)
        ok "sing-box Clash API (127.0.0.1:20091): reachable (HTTP ${clash_code}) — VPN traffic accounting works" ;;
      *)
        warn "sing-box Clash API (127.0.0.1:20091): NOT reachable (HTTP ${clash_code}) — VPN traffic will show 0"
        warn "  → ensure sing-box is running and its config has the clash_api block (regenerate from the panel)" ;;
    esac
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

# ---- 6) uninstall -----------------------------------------------------------
# do_uninstall completely removes X-NET and everything it installed/configured:
# the panel + CLI, sing-box, all managed SSH subsystems (Dropbear/Stunnel/UDPGW/
# SlowDNS), the per-protocol sshd instances, the panel-created Linux SSH users
# and their protocol groups, the service user, sudoers, the nftables accounting
# table, and the firewall rule for the panel port. It is intentionally careful
# NOT to damage the server: the main OpenSSH daemon (port 22) is preserved (only
# the X-Net AllowGroups restriction is reverted), real/login/system accounts are
# never deleted, and base packages (certbot, nftables, etc.) are left installed.
do_uninstall() {
  need_root

  echo
  echo -e "${C_RED}${C_BOLD}╔═════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_RED}${C_BOLD}║  X-NET — COMPLETE UNINSTALL (DESTRUCTIVE, IRREVERSIBLE)  ║${C_RESET}"
  echo -e "${C_RED}${C_BOLD}╚═════════════════════════════════════════════════════════╝${C_RESET}"
  echo "  This will permanently remove:"
  echo "   • The panel, its database and config (${INSTALL_DIR}), and the 'xnet' CLI"
  echo "   • sing-box + its config (/etc/sing-box, /var/lib/sing-box)"
  echo "   • Managed SSH subsystems (Dropbear, Stunnel/TLS, BadVPN/UDPGW, SlowDNS)"
  echo "   • Per-protocol sshd instances (WS/TLS/SlowDNS) and their configs"
  echo "   • ALL SSH users created by the panel + their protocol groups"
  echo "   • The 'xnet' service user, sudoers rules, and the nftables accounting table"
  echo "   • The firewall rule for the panel port"
  echo
  echo -e "  ${C_GRN}Preserved:${C_RESET} the main OpenSSH (port 22), your login/system accounts, and base packages."
  echo

  local ans
  read -r -p "  Are you sure you want to continue? (y/N): " ans
  ans="${ans:-n}"
  case "$ans" in
    y|Y|yes|YES) ;;
    *) warn "Uninstall cancelled."; return 0 ;;
  esac

  # Capture the panel port before we delete .env so we can close the firewall.
  local panel_port=""
  panel_port="$(env_get PORT)"; panel_port="${panel_port:-}"

  info "Stopping and removing X-Net services…"
  local svc
  for svc in xnet sing-box dropbear badvpn-udpgw slowdns sshd-ws sshd-tls sshd-dns; do
    systemctl stop "$svc"    >/dev/null 2>&1 || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${svc}.service" 2>/dev/null || true
  done
  # Stunnel is a distro package the panel only enabled+configured: stop/disable
  # it and drop our config, but leave the package installed.
  systemctl stop stunnel4    >/dev/null 2>&1 || true
  systemctl disable stunnel4 >/dev/null 2>&1 || true
  rm -f /etc/stunnel/xnet-ssh.conf 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Services stopped and unit files removed."

  # Revert the main-sshd hardening: remove ONLY the AllowGroups line the panel
  # added, validate, then restart sshd so port 22 returns to its prior policy.
  if [ -f /etc/ssh/sshd_config ]; then
    sed -i '/^[[:space:]]*AllowGroups[[:space:]][[:space:]]*ssh-tcp-users[[:space:]]*$/d' /etc/ssh/sshd_config
    if sshd -t >/dev/null 2>&1; then
      systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
      ok "Main sshd AllowGroups restriction reverted (port 22 restored)."
    else
      warn "sshd config check failed after edit — verify /etc/ssh/sshd_config manually."
    fi
  fi
  # Remove the dropbear PAM line the panel injected (if present).
  [ -f /etc/pam.d/dropbear ] && sed -i '/ssh-dropbear-users/d' /etc/pam.d/dropbear 2>/dev/null || true

  # Remove the panel-created SSH users. They are identified ONLY by membership in
  # the X-Net protocol groups, so real accounts are never touched. We additionally
  # protect root, the invoking sudo user, every currently logged-in user, the
  # 'xnet' service user, and any system account (UID < 1000).
  info "Removing panel-created SSH users…"
  local keep u uid victims=""
  keep="root ${SUDO_USER:-} xnet"
  for u in $(who 2>/dev/null | awk '{print $1}' | sort -u); do keep="$keep $u"; done
  is_protected() {
    local x="$1"
    case " $keep " in *" $x "*) return 0 ;; esac
    uid="$(id -u "$x" 2>/dev/null || echo 0)"
    [ "${uid:-0}" -lt 1000 ] && return 0
    return 1
  }
  local grp
  for grp in ssh-tcp-users ssh-ws-users ssh-tls-users ssh-slowdns-users ssh-dropbear-users; do
    for u in $(getent group "$grp" 2>/dev/null | awk -F: '{print $4}' | tr ',' ' '); do
      [ -n "$u" ] || continue
      is_protected "$u" && continue
      victims="${victims}${u}
"
    done
  done
  victims="$(printf '%s' "$victims" | sed '/^$/d' | sort -u)"
  local removed=0
  if [ -n "$victims" ]; then
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      userdel -r "$u" >/dev/null 2>&1 || userdel "$u" >/dev/null 2>&1 || true
      removed=$((removed + 1))
    done <<EOF
$victims
EOF
  fi
  ok "Removed ${removed} panel SSH user(s)."

  # Remove the protocol groups and the service user.
  for grp in ssh-tcp-users ssh-ws-users ssh-tls-users ssh-slowdns-users ssh-dropbear-users; do
    groupdel "$grp" >/dev/null 2>&1 || true
  done
  userdel -r xnet >/dev/null 2>&1 || userdel xnet >/dev/null 2>&1 || true

  # Remove files, directories, binaries and symlinks the panel installed.
  info "Removing files and directories…"
  rm -rf "${INSTALL_DIR}" 2>/dev/null || true
  rm -f  /usr/local/bin/xnet /usr/local/bin/xnet-ssh-apply \
         /usr/local/bin/sing-box /usr/local/bin/badvpn-udpgw /usr/local/bin/dns-server 2>/dev/null || true
  rm -rf /etc/sing-box /var/lib/sing-box 2>/dev/null || true
  rm -rf /etc/xnet /etc/ssl/xnet 2>/dev/null || true
  rm -f  /etc/ssh/sshd_config_ws /etc/ssh/sshd_config_tls /etc/ssh/sshd_config_dns 2>/dev/null || true
  rm -f  /etc/dropbear/dropbear_rsa_host_key /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null || true
  rm -f  /etc/sudoers.d/xnet /etc/sudoers.d/xnet-ssh-apply 2>/dev/null || true
  ok "Filesystem artifacts removed."

  # Remove the nftables traffic-accounting table created by the panel.
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet xnet_accounting >/dev/null 2>&1 || true
    ok "nftables accounting table removed."
  fi

  # Close the firewall rule for the panel port (best-effort).
  if [ -n "$panel_port" ]; then
    if command -v ufw >/dev/null 2>&1; then ufw delete allow "${panel_port}/tcp" >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --remove-port="${panel_port}/tcp" >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    ok "Firewall rule for panel port ${panel_port} removed."
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true

  echo
  ok "X-NET has been completely uninstalled."
  echo "  Note: base packages (certbot, nftables, dropbear, stunnel4, …) and the main"
  echo "  OpenSSH daemon were intentionally left untouched. Per-protocol inbound ports"
  echo "  opened from the panel may still have firewall rules — review with:"
  echo "    ufw status   /   firewall-cmd --list-ports"
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
    echo -e "  6) ${C_RED}Uninstall X-NET (remove everything)${C_RESET}"
    echo "  0) Exit"
    read -r -p "  Choose: " c
    case "$c" in
      1) do_deps ;;
      2) do_update ;;
      3) do_config ;;
      4) do_health ;;
      5) do_restart ;;
      6) do_uninstall ;;
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
  uninstall|remove|purge)    do_uninstall ;;
  ""|menu)                   menu ;;
  -h|--help|help)
    echo "Usage: xnet [deps|update|config|health|restart|uninstall] (no args = interactive menu)"
    ;;
  *)
    err "Unknown command: $1"; echo "Run 'xnet help' for usage."; exit 1 ;;
esac
