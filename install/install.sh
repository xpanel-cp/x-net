#!/usr/bin/env bash
# ============================================================
#  X-Net Panel — Installer (pre-built artifacts)
#  No Go/Node required — installs from compiled binary + frontend.
#
#  Fresh install: prompts for admin credentials + port
#  Upgrade: preserves .env + database, updates binary/frontend/scripts
#
#  Usage:  sudo bash install.sh
# ============================================================

set -Eeuo pipefail

# ----- pretty output helpers -------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_BOLD='\033[1m'
info()  { echo -e "${C_BLU}[i]${C_RESET} $*"; }
ok()    { echo -e "${C_GRN}[✓]${C_RESET} $*"; }
warn()  { echo -e "${C_YLW}[!]${C_RESET} $*"; }
err()   { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

trap 'err "Installation aborted on line $LINENO."' ERR

# ----- globals ---------------------------------------------------------------
INSTALL_DIR="/opt/xnet"
SERVICE_USER="xnet"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
PASSWORD_GENERATED="false"
PANEL_PORT=""
# Port the panel serves PUBLIC subscription links on, separate from the admin
# panel port so a link handed to a customer never advertises the panel address.
# Must match handlers.DefaultSubPort in the backend.
SUB_PORT="${XNET_SUB_PORT:-2096}"
# Where the PANEL moves to when the operator picks SUB_PORT for it. The
# subscription port is the one that ends up in customers' links, so it is the
# one that stays put.
PANEL_PORT_FALLBACK="2057"
JWT_SECRET=""
WEB_BASE_PATH=""
ACCESS_IP=""
IS_UPGRADE="false"
NODE_ROLE="panel"
AGENT_ALLOWED_CIDRS=""
NODE_API_KEY=""
NODE_SECRET_KEY=""
NODE_ID=""
# Pinned sing-box core version installed/verified by install_singbox.
SINGBOX_VERSION="1.13.13"
# X-NET ships a PREBUILT sing-box core that already includes the with_v2ray_api
# build tag (required for authoritative per-UUID V2Ray Stats accounting — the
# official upstream release binaries do NOT include it). We download it from this
# release instead of building from source, so no Go toolchain is needed on the
# server. The asset is named sing-box-linux-<arch>.zip.
SINGBOX_CORE_REPO="https://github.com/xpanel-cp/sing-box"

# ----- Central Session Manager (co-located, localhost-only) -------------------
# The panel's Session Manager page talks to a local xnet-session-manager service
# over its HMAC-signed /admin HTTP surface. The installer runs that service on
# 127.0.0.1 only (never exposed off-box), generates the admin/node secrets, and
# wires the panel .env (SESSION_MANAGER_*) so the feature works out of the box.
SM_BIN="/usr/local/bin/xnet-session-manager"
SM_ENV_FILE="/etc/xnet/session-manager.env"
SM_HTTP_ADDR="127.0.0.1:8081"    # admin/JSON surface the panel connects to (loopback)
# Manager gRPC LISTEN address. Default loopback (single-server). For a MULTI-NODE
# deployment where remote agents must reach this manager, export before install:
#   XNET_SM_GRPC_BIND=0.0.0.0:50051   (and open :50051 in the firewall)
SM_GRPC_BIND="${XNET_SM_GRPC_BIND:-127.0.0.1:50051}"
# Address the LOCAL node uses to reach the manager (loopback is always correct on
# the panel host itself, even when the manager also binds a public interface).
SM_GRPC_ENDPOINT="${XNET_SM_GRPC_ENDPOINT:-127.0.0.1:50051}"
SM_ACTOR_ID="panel-1"            # panel admin actor id (pairs with XNET_SM_ADMIN_SECRETS)
SM_URL="http://127.0.0.1:8081"   # panel SESSION_MANAGER_URL
SM_ADMIN_SECRET=""               # generated on fresh install, reused on upgrade
SM_NODE_SECRET=""                # generated on fresh install, reused on upgrade
SM_NODE_ID=""
# Canonical path the systemd unit's ExecStart and the panel's .env
# (SINGBOX_BINARY_PATH) both point at. ensure_singbox_canonical_path guarantees
# a working binary exists here regardless of where the package manager put it.
SINGBOX_BIN="/usr/local/bin/sing-box"

# ----- preflight -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run as root: sudo bash install.sh"

# Verify artifacts exist
[ -f "$SCRIPT_DIR/xnet-server" ] || die "xnet-server binary not found in $SCRIPT_DIR"
[ -d "$SCRIPT_DIR/dist" ] || die "dist/ frontend not found in $SCRIPT_DIR"
[ -f "$SCRIPT_DIR/xnet-ssh-apply" ] || die "xnet-ssh-apply script not found in $SCRIPT_DIR"

# Detect if this is an upgrade
if [ -f "${INSTALL_DIR}/.env" ]; then
  IS_UPGRADE="true"
fi

# ----- helpers ---------------------------------------------------------------
gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '/+=' | cut -c1-20
  else
    head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20
  fi
}

gen_jwt() {
  if command -v openssl >/dev/null 2>&1; then
    JWT_SECRET="$(openssl rand -base64 48)"
  else
    JWT_SECRET="$(head -c 48 /dev/urandom | base64)"
  fi
}

# gen_base_path produces a random secret URL path segment for the panel login
# (8–12 chars, English letters + digits only) so the panel is not reachable at
# the bare host:port. Manageable later from Core Settings → panel config.
gen_base_path() {
  local n
  # Random length in [8,12].
  n=$(( 8 + RANDOM % 5 ))
  if command -v openssl >/dev/null 2>&1; then
    WEB_BASE_PATH="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-"$n")"
  else
    WEB_BASE_PATH="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-"$n")"
  fi
  # Guarantee minimum length even if the random source was sparse.
  while [ "${#WEB_BASE_PATH}" -lt 8 ]; do
    WEB_BASE_PATH="${WEB_BASE_PATH}$(head -c 8 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
  done
  WEB_BASE_PATH="$(echo "$WEB_BASE_PATH" | cut -c1-"$n")"
}

detect_ip() {
  ACCESS_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ACCESS_IP" ]; then
    ACCESS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [ -n "$ACCESS_IP" ] || ACCESS_IP="<server-ip>"
}

# ----- interactive prompts (fresh install only) ------------------------------
prompt_credentials() {
  echo
  echo -e "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo -e "${C_BOLD}  Panel Administrator Account${C_RESET}"
  echo -e "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  echo
  # Admin username — allow ONLY English letters, digits, dot, underscore and
  # hyphen. Anything else (spaces, non-English characters, or stray non-UTF-8
  # bytes from a paste) is rejected and the prompt repeats. This is required
  # because systemd refuses to load the whole .env if any value is not valid
  # UTF-8, which silently stops the panel service (Result: resources).
  local uname_leftover
  while true; do
    read -r -p "  Admin username (default: admin): " ADMIN_USERNAME
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    uname_leftover="$(printf '%s' "$ADMIN_USERNAME" | LC_ALL=C tr -d 'A-Za-z0-9._-')"
    if [ -z "$uname_leftover" ]; then
      break
    fi
    warn "Username may contain only English letters, digits, and . _ - (no spaces or other characters). Please try again."
  done

  local p1 p2 pw_leftover
  while true; do
    read -r -s -p "  Admin password (leave empty to auto-generate): " p1; echo
    if [ -z "$p1" ]; then
      ADMIN_PASSWORD="$(gen_password)"
      PASSWORD_GENERATED="true"
      ok "A strong password was generated automatically."
      break
    fi
    # Allow only printable ASCII (English letters, digits, standard symbols) —
    # no spaces, control characters, or non-English characters — for the same
    # systemd/.env UTF-8 reason as the username.
    pw_leftover="$(printf '%s' "$p1" | LC_ALL=C tr -d '!-~')"
    if [ -n "$pw_leftover" ]; then
      warn "Password may contain only English letters, digits, and standard symbols (no spaces or non-English characters). Try again."
      continue
    fi
    read -r -s -p "  Confirm password: " p2; echo
    if [ "$p1" != "$p2" ]; then
      warn "Passwords do not match. Try again."
      continue
    fi
    if [ "${#p1}" -lt 6 ]; then
      warn "Password too short (minimum 6 characters). Try again."
      continue
    fi
    ADMIN_PASSWORD="$p1"
    break
  done
}

prompt_port() {
  echo
  echo -e "${C_BOLD}  Panel Port${C_RESET}"
  local p
  while true; do
    read -r -p "  Panel port (1-65535, default 8080): " p
    p="${p:-8080}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      warn "Invalid port. Enter a number between 1 and 65535."
      continue
    fi
    # The public subscription listener owns SUB_PORT. If the operator picks it
    # for the panel, both would try to bind the same port and one would lose —
    # silently, in a log nobody reads. Move the PANEL aside instead of refusing
    # the input: the subscription port is the one customers see in their links,
    # so it is the one that should stay predictable.
    if [ "$p" = "$SUB_PORT" ]; then
      warn "Port ${p} is reserved for subscription links; using ${PANEL_PORT_FALLBACK} for the panel instead."
      p="$PANEL_PORT_FALLBACK"
    fi
    PANEL_PORT="$p"
    break
  done
  ok "Panel port: $PANEL_PORT"
}

# ----- node role (panel vs agent) --------------------------------------------
prompt_role() {
  echo
  echo -e "${C_BOLD}  Node Role${C_RESET}"
  echo -e "    ${C_BOLD}panel${C_RESET} — Control Plane: owns the database, admin UI, dispatches to agents."
  echo -e "    ${C_BOLD}agent${C_RESET} — Data Plane: applies provisioning from the panel to this host only."
  local r
  while true; do
    read -r -p "  Node role (panel/agent, default panel): " r
    r="$(echo "${r:-panel}" | tr '[:upper:]' '[:lower:]')"
    if [ "$r" != "panel" ] && [ "$r" != "agent" ]; then
      warn "Invalid role. Enter 'panel' or 'agent'."
      continue
    fi
    NODE_ROLE="$r"
    break
  done
  ok "Node role: $NODE_ROLE"

  if [ "$NODE_ROLE" = "agent" ]; then
    echo
    echo -e "  ${C_BOLD}Agent IP whitelist (optional)${C_RESET}"
    echo -e "  Comma-separated CIDRs allowed to reach /api/agent/* (e.g. the panel IP:"
    echo -e "  203.0.113.5/32,10.0.0.0/24). Leave empty to allow any source IP (HMAC still required)."
    read -r -p "  AGENT_ALLOWED_CIDRS: " AGENT_ALLOWED_CIDRS
    AGENT_ALLOWED_CIDRS="$(echo "$AGENT_ALLOWED_CIDRS" | tr -d ' ')"

    # Generate this agent's HMAC identity (token + secret). The operator copies
    # these EXACT values into the panel when registering this node, so both
    # sides share the same secret. Startup upserts a matching nodes row from the
    # NODE_API_KEY / NODE_SECRET_KEY written to .env.
    NODE_API_KEY="xnetnode_$(rand_hex 16)"
    NODE_SECRET_KEY="$(rand_hex 32)"
    NODE_ID="node-agent-self"
    ok "Generated this agent's node credentials (shown again at the end)."
  fi
}

# rand_hex N prints a lowercase hex string of 2*N characters.
rand_hex() {
  local n="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$n"
  else
    head -c "$n" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ----- install system dependencies -------------------------------------------
# free_apt_lock recovers from a busy/stale dpkg lock so install / upgrade /
# reinstall never fail with "Could not get lock /var/lib/dpkg/lock-frontend".
# It first waits a bounded time for any legitimately-running apt/dpkg to finish;
# if one is still holding the lock after the timeout (e.g. an orphaned apt-get
# left by an interrupted previous run, PPID=1), it terminates the stuck process,
# removes the stale lock files, and repairs any half-configured dpkg state.
free_apt_lock() {
  command -v apt-get >/dev/null 2>&1 || return 0
  # Proactively stop the background updaters that hold the dpkg lock on freshly
  # booted servers (the #1 cause of "could not install" during our run). Stop the
  # services AND their timers so they can't re-arm mid-install.
  systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  local waited=0 max_wait=180
  while pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1 || pgrep -f 'unattended-upgr' >/dev/null 2>&1; do
    [ "$waited" -eq 0 ] && info "Waiting for another apt/dpkg process to finish (up to ${max_wait}s)…"
    [ "$waited" -ge "$max_wait" ] && break
    sleep 3; waited=$((waited + 3))
  done
  # Still holding after the wait → treat as stuck and take over.
  if pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; then
    warn "A stuck apt/dpkg process is holding the lock — terminating it to continue."
    systemctl stop unattended-upgrades >/dev/null 2>&1 || true
    pkill -9 -x apt-get 2>/dev/null || true
    pkill -9 -x dpkg 2>/dev/null || true
    pkill -9 -f 'unattended-upgr|apt.systemd' 2>/dev/null || true
    sleep 1
  fi
  # No apt/dpkg is running now: clear any stale lock files and repair dpkg.
  if ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
    rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
          /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a >/dev/null 2>&1 || true
  fi
}

# apt_install installs packages robustly: it frees the dpkg lock first and tells
# apt itself to WAIT up to 5 min for the lock (DPkg::Lock::Timeout) instead of
# failing instantly when a background updater is mid-run. Returns apt's status.
apt_install() {
  free_apt_lock
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "$@" >/dev/null 2>&1
}

# prompt_timezone lets the operator CHOOSE the server timezone during a fresh
# install (the panel is multi-language — fa/ru/en/zh — so we must not force one
# region on everyone). The chosen value drives how imported-user expiry dates
# (X-Panel/Shahan) are interpreted. Non-interactive installs: set XNET_TIMEZONE
# to skip the menu entirely (XNET_TIMEZONE=skip leaves the clock unchanged).
prompt_timezone() {
  # Explicit env wins — no prompt (works for piped / unattended installs).
  if [ -n "${XNET_TIMEZONE:-}" ]; then
    PANEL_TIMEZONE="$XNET_TIMEZONE"
    ok "Timezone from XNET_TIMEZONE: $PANEL_TIMEZONE"
    return 0
  fi
  echo
  echo -e "${C_BOLD}  Server Timezone${C_RESET}"
  echo -e "  Used to interpret imported-user expiry dates (X-Panel / Shahan)."
  echo -e "    ${C_BOLD}1${C_RESET}) Asia/Tehran      (Iran)   ${C_BOLD}[default]${C_RESET}"
  echo -e "    ${C_BOLD}2${C_RESET}) UTC"
  echo -e "    ${C_BOLD}3${C_RESET}) Europe/Moscow    (Russia)"
  echo -e "    ${C_BOLD}4${C_RESET}) Asia/Shanghai    (China)"
  echo -e "    ${C_BOLD}5${C_RESET}) Asia/Dubai"
  echo -e "    ${C_BOLD}6${C_RESET}) Europe/Istanbul"
  echo -e "    ${C_BOLD}7${C_RESET}) Custom (enter an IANA name, e.g. Europe/Berlin)"
  echo -e "    ${C_BOLD}8${C_RESET}) Keep the current server timezone (don't change)"
  local c
  read -r -p "  Choose [1-8, default 1]: " c
  case "${c:-1}" in
    1) PANEL_TIMEZONE="Asia/Tehran" ;;
    2) PANEL_TIMEZONE="UTC" ;;
    3) PANEL_TIMEZONE="Europe/Moscow" ;;
    4) PANEL_TIMEZONE="Asia/Shanghai" ;;
    5) PANEL_TIMEZONE="Asia/Dubai" ;;
    6) PANEL_TIMEZONE="Europe/Istanbul" ;;
    7)
      local tzc
      read -r -p "  Enter IANA timezone: " tzc
      PANEL_TIMEZONE="$(echo "$tzc" | tr -d ' ')"
      [ -n "$PANEL_TIMEZONE" ] || PANEL_TIMEZONE="Asia/Tehran"
      ;;
    8) PANEL_TIMEZONE="skip" ;;
    *) PANEL_TIMEZONE="Asia/Tehran" ;;
  esac
  ok "Timezone selection: $PANEL_TIMEZONE"
}

# configure_timezone APPLIES the chosen timezone (PANEL_TIMEZONE, falling back to
# the XNET_TIMEZONE env var). It is intentionally a NO-OP when neither is set —
# so an upgrade never changes the operator's existing clock unless they ask. A
# value of "skip" leaves the clock unchanged; an unknown zone is refused rather
# than breaking the clock. Idempotent and non-fatal.
configure_timezone() {
  local tz="${PANEL_TIMEZONE:-${XNET_TIMEZONE:-}}"
  if [ -z "$tz" ]; then
    return 0  # nothing chosen (e.g. upgrade without env) — leave clock as-is
  fi
  if [ "$tz" = "skip" ]; then
    info "Timezone left unchanged (keeping the current server timezone)."
    return 0
  fi
  if [ ! -e "/usr/share/zoneinfo/$tz" ]; then
    warn "Timezone '$tz' not found in /usr/share/zoneinfo — leaving the clock unchanged."
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl set-timezone "$tz" >/dev/null 2>&1; then
      ok "Server timezone set to ${tz}."
    else
      warn "Could not set timezone to ${tz} (timedatectl failed) — continuing."
    fi
  else
    warn "timedatectl not available — set the timezone manually to ${tz}."
  fi
}

install_deps() {
  info "Installing required system packages…"
  # Package sets:
  #   core   — always required for the panel/agent to run and self-manage.
  #   ssl    — certbot (+cron for auto-renew) so the panel can issue Let's
  #            Encrypt certificates via the TLS/Certificates page (the
  #            "certbot is not installed" error means this set was missing).
  #   tools  — helpers used by traffic accounting / SSH session monitoring (ps),
  #            networking, and CA roots for outbound HTTPS.
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    free_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null 2>&1 || true
    # Best-effort: a transient apt error (stale repo, network) must NOT abort the
    # whole install. We verify the critical tools below instead. apt_install waits
    # for the dpkg lock so a background updater can't make these fail.
    apt_install curl wget openssl jq iproute2 libcap2-bin sudo tar ca-certificates cron procps net-tools uuid-runtime nftables conntrack \
      || warn "apt-get reported an issue installing core packages; continuing and verifying below."
    apt_install certbot \
      || warn "apt-get could not install certbot; SSL issuance will be unavailable until it is installed."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl wget openssl jq iproute libcap sudo tar ca-certificates cronie procps-ng net-tools nftables conntrack-tools >/dev/null 2>&1 \
      || warn "dnf reported an issue installing core packages; continuing and verifying below."
    dnf install -y certbot >/dev/null 2>&1 \
      || warn "dnf could not install certbot; SSL issuance will be unavailable until it is installed."
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y curl wget openssl jq iproute libcap sudo tar ca-certificates cronie procps-ng net-tools nftables conntrack-tools >/dev/null 2>&1 \
      || warn "yum reported an issue installing core packages; continuing and verifying below."
    yum install -y certbot >/dev/null 2>&1 \
      || warn "yum could not install certbot; SSL issuance will be unavailable until it is installed."
  else
    warn "Could not detect package manager. Ensure curl, openssl, jq, setcap, sudo, and certbot are installed."
  fi

  # Soft verification (non-fatal here; the setcap requirement is enforced later
  # in deploy_files). Tells the operator exactly what to install if anything is
  # still missing rather than aborting cryptically.
  local missing=""
  for bin in curl openssl jq tar; do
    command -v "$bin" >/dev/null 2>&1 || missing="${missing} ${bin}"
  done
  if ! command -v setcap >/dev/null 2>&1; then
    missing="${missing} setcap(libcap2-bin/libcap)"
  fi
  if [ -n "${missing}" ]; then
    warn "Missing tools:${missing}. Install them and re-run if the install fails later."
  fi

  # certbot is required only for SSL issuance (TLS/Certificates page). Warn — but
  # never abort — so a server without it still installs and runs the panel.
  if command -v certbot >/dev/null 2>&1; then
    ok "certbot present ($(command -v certbot)) — SSL issuance available."
  else
    warn "certbot is NOT installed — issuing Let's Encrypt certificates from the panel will fail."
    warn "  Install it manually:  apt-get install -y certbot   (or)   dnf install -y certbot"
  fi

  # Traffic-accounting prerequisites:
  #   • nft (nftables) — kernel-level per-user byte counters for Direct SSH
  #     (the panel runs `sudo -n nft`; sudoers already grants it).
  #   • ps (procps)    — SSH online-session counting.
  #   • sing-box Clash API on 127.0.0.1:20091 — VPN per-client traffic (no extra
  #     package; just sing-box running with the clash_api block the panel writes).
  if command -v nft >/dev/null 2>&1; then
    ok "nftables present ($(command -v nft)) — SSH traffic accounting available."
  else
    warn "nftables (nft) is NOT installed — Direct SSH traffic will not be measured."
    warn "  Install it manually:  apt-get install -y nftables   (or)   dnf install -y nftables"
  fi
  command -v ps >/dev/null 2>&1 || warn "ps (procps) missing — SSH online-session counts will be 0."
  ok "System dependencies ready."
}

persist_tcp_early_demux() {
  if [ "$(uname -s)" != "Linux" ]; then
    return 0
  fi
  if ! command -v sysctl >/dev/null 2>&1; then
    warn "sysctl not available; cannot persist net.ipv4.tcp_early_demux."
    return 0
  fi

  if sysctl -w net.ipv4.tcp_early_demux=1 >/dev/null 2>&1; then
    ok "Enabled net.ipv4.tcp_early_demux=1 for kernel socket-owner accounting."
  else
    warn "Could not enable net.ipv4.tcp_early_demux=1. Direct SSH download accounting may be incomplete."
  fi

  local sysctl_file="/etc/sysctl.d/99-xnet.conf"
  mkdir -p "$(dirname "$sysctl_file")"
  if [ -f "$sysctl_file" ]; then
    if grep -q '^net\.ipv4\.tcp_early_demux=' "$sysctl_file" 2>/dev/null; then
      sed -i 's/^net\.ipv4\.tcp_early_demux=.*/net.ipv4.tcp_early_demux=1/' "$sysctl_file"
    else
      echo 'net.ipv4.tcp_early_demux=1' >> "$sysctl_file"
    fi
  else
    echo 'net.ipv4.tcp_early_demux=1' > "$sysctl_file"
  fi
  ok "Persisted net.ipv4.tcp_early_demux=1 to $sysctl_file."
}


# ensure_session_gate_pam registers the admission gate in the PAM account stack
# so a login that would exceed max_login is refused during authentication rather
# than killed a few seconds after it succeeds.
#
# It is added to /etc/pam.d/sshd, which every OpenSSH instance the panel runs
# authenticates through (the main daemon and the ws/tls/dns instances share the
# service name). Dropbear is NOT covered: Debian and Ubuntu build it against
# shadow rather than PAM, so there is no hook to attach to and Dropbear accounts
# stay on the panel's after-the-fact enforcement.
#
# Idempotent: the line is added once, and a copy of the original stack is kept
# because a broken PAM file locks every login out and the operator needs
# something to restore from over a console.
ensure_session_gate_pam() {
  local gate="${INSTALL_DIR}/xnet-session-gate"
  local pamfile="/etc/pam.d/sshd"
  [ -f "$gate" ] || return 0
  if [ ! -f "$pamfile" ]; then
    warn "$pamfile not found — SSH session admission gate not registered."
    return 0
  fi

  if grep -q "xnet-session-gate" "$pamfile" 2>/dev/null; then
    ok "SSH session admission gate already registered in PAM."
    return 0
  fi

  cp -a "$pamfile" "${pamfile}.xnet-backup" 2>/dev/null || true
  {
    echo ""
    echo "# X-NET: refuse a login that would exceed the account's max_login."
    echo "account required pam_exec.so quiet ${gate}"
  } >> "$pamfile"
  ok "SSH session admission gate registered in PAM (${pamfile})."
}

# ----- system log rotation ----------------------------------------------------
# Bound the growth of the system logs the panel is the heaviest writer to.
#
# Every privileged action the panel takes goes through `sudo`, and sudo writes a
# session-open and a session-close line to /var/log/auth.log for each one. A
# build that ran hundreds of sudo calls per second therefore wrote auth.log (and
# syslog, which mirrors it) at a rate no default policy anticipates. Both files
# reached several GB, the filesystem hit 100%, and the panel then could not even
# open its database: SQLite could not create the -shm file WAL mode needs and
# failed with an opaque "disk I/O error (4874)".
#
# The write amplification itself is fixed in the backend. This is the second line
# of defence, so a future misbehaving writer costs disk space instead of taking
# the node down.
#
# Everything here is additive and idempotent, and NOTHING here rotates, deletes
# or truncates a log: logrotate is only ever invoked with -d (debug/dry-run),
# which changes nothing. Existing logs are left exactly as they are.
#
# The three paths below are overridable ONLY so the logic can be exercised
# against a throwaway filesystem; installs always use the defaults.
XNET_LOGROTATE_DIR="${XNET_LOGROTATE_DIR:-/etc/logrotate.d}"
XNET_LOGROTATE_CONF="${XNET_LOGROTATE_CONF:-/etc/logrotate.conf}"
XNET_LOGROTATE_FILE="${XNET_LOGROTATE_DIR}/xnet-system-logs"
XNET_LOGROTATE_TARGETS="${XNET_LOGROTATE_TARGETS:-/var/log/auth.log /var/log/syslog}"

# lr_ensure_installed makes logrotate available, installing it only when a
# package manager is present. Returns non-zero when logrotate cannot be used.
lr_ensure_installed() {
  if command -v logrotate >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    info "logrotate not present — installing…"
    apt_install logrotate || true
  fi
  command -v logrotate >/dev/null 2>&1
}

# lr_paths_managed_elsewhere prints every log path that the CURRENT logrotate
# configuration already handles, EXCLUDING our own file.
#
# Excluding our own file is what makes the check meaningful on a re-run: without
# it, the second install would see the paths covered (by us) and could never tell
# that apart from the system covering them. The exclusion is done by dry-running
# a throwaway copy of the configuration rather than by touching /etc, so an
# interrupted run cannot leave the real configuration modified.
#
# `logrotate -d` is a dry run: it neither rotates logs nor runs postrotate
# scripts nor writes its state file (which is redirected anyway).
lr_paths_managed_elsewhere() {
  local tmpdir conf f
  tmpdir="$(mktemp -d 2>/dev/null)" || return 1
  mkdir -p "$tmpdir/d"
  for f in "$XNET_LOGROTATE_DIR"/*; do
    [ -f "$f" ] || continue
    [ "$f" = "$XNET_LOGROTATE_FILE" ] && continue
    cp "$f" "$tmpdir/d/" 2>/dev/null || true
  done
  conf="$tmpdir/logrotate.conf"
  # Reproduce the global section without its include line, then point the copy at
  # our filtered directory.
  if [ -f "$XNET_LOGROTATE_CONF" ]; then
    sed 's#^[[:space:]]*include[[:space:]].*##' "$XNET_LOGROTATE_CONF" > "$conf" 2>/dev/null || : > "$conf"
  else
    : > "$conf"
  fi
  printf 'include %s\n' "$tmpdir/d" >> "$conf"
  logrotate -d -s "$tmpdir/state" "$conf" 2>&1 | sed -n 's/^considering log //p' | sort -u
  rm -rf "$tmpdir"
}

# lr_grep_managed_elsewhere is the fallback used when the dry run cannot be
# produced (very old logrotate, or a configuration it refuses to parse). It reads
# the files directly, with comments stripped so a commented-out example is not
# mistaken for a live rule.
#
# A false positive here means "we leave this path alone", which is the safe
# direction: a log rotated by nobody wastes space, a log rotated by two rules can
# lose data.
lr_grep_managed_elsewhere() {
  local path="$1" f
  for f in "$XNET_LOGROTATE_CONF" "$XNET_LOGROTATE_DIR"/*; do
    [ -f "$f" ] || continue
    [ "$f" = "$XNET_LOGROTATE_FILE" ] && continue
    if sed 's/#.*//' "$f" 2>/dev/null | grep -qF "$path"; then
      return 0
    fi
  done
  return 1
}

configure_logrotate() {
  if [ "$(uname -s)" != "Linux" ]; then
    return 0
  fi
  info "Configuring log rotation…"

  if ! lr_ensure_installed; then
    warn "logrotate is unavailable and could not be installed — skipping log rotation setup."
    warn "System logs will not be size-bounded on this host."
    return 0
  fi

  # What the rest of the system already rotates.
  local managed uncovered=() covered=() path
  managed="$(lr_paths_managed_elsewhere 2>/dev/null)"

  for path in $XNET_LOGROTATE_TARGETS; do
    if [ -n "$managed" ]; then
      # Exact match, or a glob rule that logrotate expanded to this path.
      if printf '%s\n' "$managed" | grep -qxF "$path"; then
        covered+=("$path")
        continue
      fi
    elif lr_grep_managed_elsewhere "$path"; then
      covered+=("$path")
      continue
    fi
    uncovered+=("$path")
  done

  if [ "${#covered[@]}" -gt 0 ]; then
    info "Already rotated by the system's own policy: ${covered[*]}"
  fi

  # Self-healing: if the distribution (or the admin) has since taken over every
  # path we added, our file is now a SECOND rule for those logs. Two rules
  # rotating one file is worse than none, so ours is withdrawn.
  if [ "${#uncovered[@]}" -eq 0 ]; then
    if [ -f "$XNET_LOGROTATE_FILE" ]; then
      rm -f "$XNET_LOGROTATE_FILE"
      ok "System policy now covers these logs — removed the redundant ${XNET_LOGROTATE_FILE}."
    else
      ok "Logrotate already configured"
    fi
    return 0
  fi

  # Write (or rewrite) our file for exactly the paths nothing else handles.
  local tmp
  tmp="$(mktemp 2>/dev/null)" || { warn "Could not create a temporary file — skipping log rotation setup."; return 0; }
  {
    echo "# Managed by the X-NET installer. Regenerated on every install/upgrade."
    echo "#"
    echo "# Covers only the system logs that no other logrotate configuration on"
    echo "# this host already handles, so a log is never rotated by two rules."
    echo "# If the distribution later takes one of these over, the installer"
    echo "# removes it from here automatically."
    for path in "${uncovered[@]}"; do
      echo "$path"
    done
    echo "{"
    echo "    weekly"
    echo "    rotate 4"
    echo "    compress"
    echo "    delaycompress"
    echo "    missingok"
    echo "    notifempty"
    echo "}"
  } > "$tmp"

  # Nothing to do if the file is already byte-identical — keeps re-runs silent
  # and leaves the mtime alone.
  if [ -f "$XNET_LOGROTATE_FILE" ] && cmp -s "$tmp" "$XNET_LOGROTATE_FILE"; then
    rm -f "$tmp"
    ok "Logrotate already configured"
    return 0
  fi

  # Validate BEFORE the new file is in place, by dry-running a copy of the whole
  # configuration with our candidate included. An invalid file is never written.
  local vdir vconf f
  vdir="$(mktemp -d 2>/dev/null)"
  if [ -n "$vdir" ]; then
    mkdir -p "$vdir/d"
    for f in "$XNET_LOGROTATE_DIR"/*; do
      [ -f "$f" ] || continue
      [ "$f" = "$XNET_LOGROTATE_FILE" ] && continue
      cp "$f" "$vdir/d/" 2>/dev/null || true
    done
    cp "$tmp" "$vdir/d/xnet-system-logs"
    vconf="$vdir/logrotate.conf"
    if [ -f "$XNET_LOGROTATE_CONF" ]; then
      sed 's#^[[:space:]]*include[[:space:]].*##' "$XNET_LOGROTATE_CONF" > "$vconf" 2>/dev/null || : > "$vconf"
    else
      : > "$vconf"
    fi
    printf 'include %s\n' "$vdir/d" >> "$vconf"
    if ! logrotate -d -s "$vdir/state" "$vconf" >/dev/null 2>&1; then
      warn "The generated logrotate policy did not validate — leaving the existing configuration untouched."
      rm -f "$tmp"; rm -rf "$vdir"
      return 0
    fi
    rm -rf "$vdir"
  fi

  install -m 0644 -o root -g root "$tmp" "$XNET_LOGROTATE_FILE"
  rm -f "$tmp"

  info "Logrotate policy: weekly, 4 rotations, compressed"
  ok "Log rotation configured successfully (${uncovered[*]} → ${XNET_LOGROTATE_FILE})"
}

# ----- install sing-box core --------------------------------------------------
# The panel/agent shells out to the sing-box binary to apply inbound configs and
# to collect per-user traffic. We pin an exact version and (re)install it when
# missing, broken, or a different version is present (idempotent, best-effort).
# singbox_has_v2ray reports whether the installed sing-box binary was built with
# the with_v2ray_api tag (printed on the "Tags:" line of `sing-box version`).
singbox_has_v2ray() {
  sing-box version 2>/dev/null | grep -q "with_v2ray_api"
}

# extract_zip extracts $1 (a .zip) into directory $2, trying unzip, then python3,
# then bsdtar/libarchive `tar`. Installs `unzip` via the package manager as a
# last resort. Returns non-zero if all methods fail.
extract_zip() {
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1 && unzip -o "$zip" -d "$dest" >/dev/null 2>&1; then return 0; fi
  if command -v python3 >/dev/null 2>&1 && python3 -c "import zipfile,sys;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip" "$dest" >/dev/null 2>&1; then return 0; fi
  if command -v bsdtar >/dev/null 2>&1 && bsdtar -xf "$zip" -C "$dest" >/dev/null 2>&1; then return 0; fi
  if tar -xf "$zip" -C "$dest" >/dev/null 2>&1; then return 0; fi
  # Last resort: install unzip and retry.
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y unzip >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y unzip >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -y unzip >/dev/null 2>&1 || true
  fi
  command -v unzip >/dev/null 2>&1 && unzip -o "$zip" -d "$dest" >/dev/null 2>&1
}

# download_singbox_core downloads the X-NET prebuilt sing-box core (which already
# includes with_v2ray_api) for this architecture from SINGBOX_CORE_REPO, verifies
# it carries the with_v2ray_api tag, and installs it to $SINGBOX_BIN. Returns
# non-zero on any failure so the caller can fall back to the official upstream
# binary. Never leaves a half-installed binary in place.
download_singbox_core() {
  local want="$SINGBOX_VERSION" arch uarch
  uarch="$(uname -m)"
  case "$uarch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) warn "No prebuilt X-NET sing-box core for arch '${uarch}'. Only linux amd64 and arm64 are published (sing-box-linux-amd64.zip / sing-box-linux-arm64.zip)."; return 1 ;;
  esac
  # Release asset for this architecture, e.g. sing-box-linux-amd64.zip.
  # The zip contains a single binary named "sing-box" (installed to $SINGBOX_BIN
  # below). Published at ${SINGBOX_CORE_REPO}/releases/tag/v${want}.
  local url="${SINGBOX_CORE_REPO}/releases/download/v${want}/sing-box-linux-${arch}.zip"
  local tmp
  tmp="$(mktemp -d 2>/dev/null || echo /tmp/sb-core)"
  mkdir -p "$tmp"

  info "Downloading sing-box core (with_v2ray_api) v${want} (${arch}) from ${SINGBOX_CORE_REPO}…"
  if ! curl -fsSL "$url" -o "${tmp}/sb.zip" 2>/dev/null; then
    warn "Download failed: ${url}"
    rm -rf "$tmp"; return 1
  fi
  if ! extract_zip "${tmp}/sb.zip" "$tmp"; then
    warn "Could not extract the core archive (no unzip/python3/bsdtar available)."
    rm -rf "$tmp"; return 1
  fi
  # The archive ships the binary named e.g. "sing-box-linux-amd64" (not
  # "sing-box"), so match both. It is installed to the canonical path
  # $SINGBOX_BIN (=/usr/local/bin/sing-box) below, so the on-disk command is
  # always `sing-box` regardless of the archived filename (needed for
  # `sing-box version` and the systemd unit's ExecStart).
  local bin
  bin="$(find "$tmp" -type f \( -name 'sing-box' -o -name "sing-box-linux-${arch}" -o -name 'sing-box-linux-*' \) 2>/dev/null | head -n1)"
  if [ -z "$bin" ]; then
    warn "sing-box binary not found inside the archive."
    rm -rf "$tmp"; return 1
  fi
  chmod +x "$bin" 2>/dev/null || true
  # Verify the downloaded core actually carries with_v2ray_api before installing.
  if ! "$bin" version 2>/dev/null | grep -q "with_v2ray_api"; then
    warn "Downloaded core does NOT include with_v2ray_api; discarding."
    rm -rf "$tmp"; return 1
  fi
  # If the freshly downloaded core is byte-identical to the one already on disk,
  # skip the swap AND the service restart. This keeps re-runs cheap while still
  # UPDATING whenever the release binary changed — even when the version TAG is
  # unchanged. The prebuilt core reports its version as "unknown" (no version
  # ldflag), so a tag/version check can NOT detect a rebuilt release; a content
  # hash can, which is exactly the "core not updating on the server" case.
  if [ -x "$SINGBOX_BIN" ] && command -v sha256sum >/dev/null 2>&1; then
    local new_sum cur_sum
    new_sum="$(sha256sum "$bin" 2>/dev/null | cut -d' ' -f1 || true)"
    cur_sum="$(sha256sum "$SINGBOX_BIN" 2>/dev/null | cut -d' ' -f1 || true)"
    if [ -n "$new_sum" ] && [ "$new_sum" = "$cur_sum" ]; then
      rm -rf "$tmp"
      ok "sing-box core already up to date (checksum match)."
      return 0
    fi
  fi
  systemctl stop sing-box >/dev/null 2>&1 || true
  install -m 0755 "$bin" "$SINGBOX_BIN"
  rm -rf "$tmp"
  ok "sing-box core (with_v2ray_api) installed/updated at ${SINGBOX_BIN}."
  return 0
}

install_singbox() {
  local want="$SINGBOX_VERSION"

  # The sing-box core is installed EXCLUSIVELY from the X-NET prebuilt release
  # (SINGBOX_CORE_REPO), which is the only build that includes with_v2ray_api —
  # required for authoritative per-UUID (V2Ray Stats) accounting. We deliberately
  # do NOT fall back to the upstream SagerNet release, because that binary lacks
  # with_v2ray_api and would silently degrade accounting to Clash-only.

  # We ALWAYS try to sync the core to the pinned X-NET release — there is NO
  # "already installed, skip" short-circuit. That old fast-path meant that once
  # ANY with_v2ray_api core was present, the server NEVER picked up a newer
  # release (the reported "core not updating on the server" bug), because the
  # prebuilt core reports version "unknown" and can't be version-compared.
  # download_singbox_core is idempotent: it only replaces the on-disk binary (and
  # restarts sing-box) when the release actually differs by content hash, so
  # re-runs stay cheap while a rebuilt release IS applied — even at the same tag.
  info "Syncing sing-box core (with_v2ray_api) v${want} from ${SINGBOX_CORE_REPO}…"
  if download_singbox_core; then
    ensure_singbox_service
    return
  fi

  # Download/verify failed — keep any working core already in place rather than
  # breaking the node when GitHub is briefly unreachable.
  if command -v sing-box >/dev/null 2>&1 && singbox_has_v2ray; then
    warn "Could not reach ${SINGBOX_CORE_REPO}; keeping the existing with_v2ray_api core."
    ensure_singbox_service
    return
  fi

  # No silent upstream fallback: the panel needs with_v2ray_api. Tell the operator
  # exactly how to place the core manually so accounting is not silently degraded.
  warn "Could not install the sing-box core from ${SINGBOX_CORE_REPO}."
  warn "Download it manually and install it to ${SINGBOX_BIN}:"
  warn "  ${SINGBOX_CORE_REPO}/releases/tag/v${want}  (asset: sing-box-linux-<arch>.zip)"
  if command -v sing-box >/dev/null 2>&1; then
    warn "An existing sing-box is present but may lack with_v2ray_api — per-user accounting will stay on Clash until the correct core is installed."
    ensure_singbox_service
  fi
}

# SINGBOX_BIN is the canonical path the systemd unit's ExecStart and the panel's
# .env (SINGBOX_BINARY_PATH) both point at. Everything that touches sing-box must
# agree on this one path.
SINGBOX_BIN="/usr/local/bin/sing-box"

# SINGBOX_BIN is the canonical path the systemd unit's ExecStart and the panel's
# .env (SINGBOX_BINARY_PATH) both point at. Everything that touches sing-box must
# agree on this one path.
SINGBOX_BIN="/usr/local/bin/sing-box"

# ensure_singbox_canonical_path guarantees a working sing-box binary exists at
# the canonical path ($SINGBOX_BIN) the systemd unit and panel use.
#
# Why this is required: distro/apt packages (and the official install.sh
# fallback) install sing-box at /usr/bin/sing-box. Our systemd unit hardcodes
# ExecStart=/usr/local/bin/sing-box, so when only the /usr/bin copy exists the
# service crash-loops with status=203/EXEC ("Unable to locate executable
# /usr/local/bin/sing-box"). When the canonical path is missing but another
# sing-box is present in PATH, copy it into place (falling back to a symlink) so
# the service and panel always resolve the same binary — on fresh installs,
# upgrades, and hosts where sing-box was pre-installed via the package manager.
ensure_singbox_canonical_path() {
  # Already a working binary at the canonical path? Nothing to do.
  if [ -x "$SINGBOX_BIN" ]; then
    return 0
  fi
  local found
  found="$(command -v sing-box 2>/dev/null || true)"
  if [ -n "$found" ] && [ "$found" != "$SINGBOX_BIN" ] && [ -x "$found" ]; then
    mkdir -p "$(dirname "$SINGBOX_BIN")"
    if install -m 0755 "$found" "$SINGBOX_BIN" 2>/dev/null || ln -sf "$found" "$SINGBOX_BIN" 2>/dev/null; then
      ok "Linked sing-box into ${SINGBOX_BIN} (resolved from ${found})."
    else
      warn "Found sing-box at ${found} but could not place it at ${SINGBOX_BIN}; the service may fail to start."
    fi
  fi
}

# ensure_singbox_service writes a correct systemd unit and enables it so the
# panel can start/reload sing-box via `systemctl` (the panel shells out to
# `sudo -n systemctl reload|restart sing-box`). The unit is REWRITTEN on every
# install so a missing/broken/incompatible unit is repaired each time. It is NOT
# started here: the panel generates /etc/sing-box/config.json on first boot and
# then starts/reloads the core. Best-effort (never aborts the installer).
ensure_singbox_service() {
  # Guarantee the binary the unit's ExecStart points at actually exists before
  # we (re)write and (re)start the unit — otherwise the service crash-loops with
  # status=203/EXEC when sing-box lives at /usr/bin (apt) instead of /usr/local/bin.
  ensure_singbox_canonical_path
  mkdir -p /etc/sing-box /var/lib/sing-box
  # Seed a minimal valid config so `systemctl start` / `sing-box check` don't
  # fail before the panel writes the real one. The panel overwrites this on boot.
  if [ ! -f /etc/sing-box/config.json ]; then
    echo '{"log":{"level":"info"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > /etc/sing-box/config.json
  fi
  # Always (re)write the unit to /etc/systemd/system (overrides any distro unit
  # in /lib) so ExecStart, ExecReload (SIGHUP for `systemctl reload`) and the
  # capabilities sing-box needs (bind low ports / tun) are guaranteed correct.
  cat > /etc/systemd/system/sing-box.service <<'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
WorkingDirectory=/var/lib/sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable sing-box >/dev/null 2>&1 || true
  # Bring it up now with the seed config so `systemctl status sing-box` is green
  # immediately; the panel rewrites the config and reloads on its first boot.
  systemctl restart sing-box >/dev/null 2>&1 || true
}

# ----- install SSH tunneling subsystems --------------------------------------
# Installs the optional SSH transport subsystems the panel manages so they show
# as "installed" (and are start/stoppable by the panel) on EVERY node — panel or
# agent: Dropbear, Stunnel (TLS), BadVPN/UDPGW, and SlowDNS (dnstt). WebSocket is
# served by the panel process itself (no package needed). Runs on fresh install,
# upgrade and reinstall. Best-effort and idempotent: a failure in one subsystem
# never aborts the install, and units are created DISABLED (not auto-started at
# boot) — the panel starts them only when the operator enables that protocol, so
# they never grab ports (e.g. 443) from sing-box at boot.
install_ssh_subsystems() {
  info "Installing SSH tunneling subsystems (Dropbear, Stunnel/TLS, BadVPN/UDPGW, SlowDNS)…"

  # --- packages (best-effort across package managers) ---
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    free_apt_lock
    # badvpn lives in Ubuntu's 'universe' component. Ensure the tooling to enable
    # it exists, then enable it (no-op on Debian / when already enabled).
    command -v add-apt-repository >/dev/null 2>&1 || apt_install software-properties-common || true
    if command -v add-apt-repository >/dev/null 2>&1; then
      add-apt-repository -y universe >/dev/null 2>&1 || true
    fi
    free_apt_lock
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null 2>&1 || true
    # Install each package INDEPENDENTLY (and with apt waiting for the lock). A
    # single combined install aborts ALL packages when one is unavailable, which
    # is why Dropbear/Stunnel/UDPGW previously showed "not installed".
    apt_install dropbear-bin || apt_install dropbear || warn "apt-get could not install dropbear."
    apt_install stunnel4 || warn "apt-get could not install stunnel4."
    apt_install badvpn || warn "apt-get could not install badvpn (UDPGW); will try building from source."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y epel-release >/dev/null 2>&1 || true
    dnf install -y dropbear >/dev/null 2>&1 || warn "dnf could not install dropbear."
    dnf install -y stunnel  >/dev/null 2>&1 || warn "dnf could not install stunnel."
    dnf install -y badvpn   >/dev/null 2>&1 || warn "dnf could not install badvpn (UDPGW)."
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release >/dev/null 2>&1 || true
    yum install -y dropbear >/dev/null 2>&1 || warn "yum could not install dropbear."
    yum install -y stunnel  >/dev/null 2>&1 || warn "yum could not install stunnel."
    yum install -y badvpn   >/dev/null 2>&1 || warn "yum could not install badvpn (UDPGW)."
  fi

  # The account gate is set up even when dropbear itself failed to install:
  # the shell it provisions accounts with is chosen by the panel regardless, and
  # having the symlink already present means a dropbear installed later by hand
  # is gated from its first start rather than briefly open to every account.
  ensure_dropbear_user_gate
  ensure_session_gate_pam
  ensure_dropbear_unit
  ensure_stunnel_unit
  ensure_udpgw_unit
  ensure_slowdns_unit

  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "SSH tunneling subsystems prepared (managed by the panel on demand)."
}

# XNET_DROPBEAR_LOG is where Dropbear's own log goes, and it is load-bearing for
# traffic accounting — not a convenience.
#
# Dropbear forks a child per connection and only setuids inside the fork that
# execs a SHELL. A tunnel-only client (ssh -N / -D / -L, which is how these
# accounts are used) never asks for one, so nothing ever runs as the account and
# the account's UID owns no socket. Both kernel collectors key on the socket
# owner's UID, so such an account measures EXACTLY 0 bytes and shows 0 online
# however much it transfers. The only record of who owns a connection is the
# authentication Dropbear logs — which carries the child PID, the account name
# and the client endpoint — so the panel reads it and attributes each live
# connection from there.
#
# It is written to a plain file rather than left to the journal because that is
# the one source guaranteed readable by the unprivileged 'xnet' service user:
# Ubuntu 24.04 minimal images ship no rsyslog (so /var/log/auth.log may not
# exist) and journal access needs group membership the panel may not have. The
# panel still falls back to auth.log and journalctl if this file is missing.
XNET_DROPBEAR_LOG="/var/log/xnet/dropbear.log"

# ensure_dropbear_logging makes Dropbear's log readable by the panel and keeps
# it from growing without bound. Applied on every run (including upgrades), and
# via a drop-in so it also covers a dropbear.service this installer did not
# write.
ensure_dropbear_logging() {
  local had_dropin=1
  [ -f /etc/systemd/system/dropbear.service.d/20-xnet-logging.conf ] || had_dropin=0
  mkdir -p "$(dirname "$XNET_DROPBEAR_LOG")"
  chmod 0755 "$(dirname "$XNET_DROPBEAR_LOG")" 2>/dev/null || true
  [ -f "$XNET_DROPBEAR_LOG" ] || : > "$XNET_DROPBEAR_LOG"
  chmod 0644 "$XNET_DROPBEAR_LOG" 2>/dev/null || true

  # systemd's append: needs v240+ (Ubuntu 20.04 and newer). On anything older
  # the drop-in is simply rejected and the panel falls back to the journal.
  mkdir -p /etc/systemd/system/dropbear.service.d
  cat > /etc/systemd/system/dropbear.service.d/20-xnet-logging.conf <<EOF
# Managed by X-Net. Dropbear's auth lines are how the panel attributes
# tunnel-only sessions to an account; see install.sh:ensure_dropbear_logging.
[Service]
StandardOutput=append:${XNET_DROPBEAR_LOG}
StandardError=append:${XNET_DROPBEAR_LOG}
EOF

  cat > /etc/logrotate.d/xnet-dropbear <<EOF
${XNET_DROPBEAR_LOG} {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0644 root root
}
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true

  # A logging directive only takes effect on RESTART. Without this, a server
  # upgraded in place keeps a dropbear that writes nowhere the panel looks, and
  # every Dropbear account goes on reporting 0 online and 0 traffic while the
  # unit file looks perfectly correct. Restarting is done ONLY when the drop-in
  # was just created, so re-running the installer does not drop live tunnels
  # every time.
  if [ "$had_dropin" = "0" ] && systemctl is-active dropbear >/dev/null 2>&1; then
    systemctl restart dropbear >/dev/null 2>&1 || true
    ok "Dropbear restarted so it logs to ${XNET_DROPBEAR_LOG} (session attribution)."
  fi
}

# XNET_RESTRICTED_SHELL is the login shell of every SSH account that is NOT a
# Dropbear account, and it is the whole mechanism that keeps those accounts off
# the Dropbear port.
#
# Each OpenSSH instance the panel runs is locked to one protocol group with
# AllowGroups, so an "SSH WS" account cannot authenticate on the SSH TCP port.
# Dropbear has no such directive. The pam_succeed_if rule below only works if
# dropbear was BUILT with PAM, and Debian/Ubuntu build it against shadow
# instead — so on these hosts the rule is inert and dropbear accepted ANY valid
# Linux account. An "SSH TCP" account could therefore log in on port 446, where
# its session is root-owned and invisible to per-account accounting.
#
# Dropbear's one unconditional per-user gate is /etc/shells: it rejects any
# account whose login shell is not listed there ("has invalid shell, rejected").
# So Dropbear accounts keep /bin/bash (always listed) and everyone else gets
# this symlink, which is deliberately NOT listed. OpenSSH never reads
# /etc/shells, and the symlink points at /bin/bash, so nothing else changes:
# same sessions, same forwarding, same banner.
XNET_RESTRICTED_SHELL="/usr/local/sbin/xnet-shell"

ensure_dropbear_user_gate() {
  mkdir -p "$(dirname "$XNET_RESTRICTED_SHELL")"
  # A symlink, not a wrapper script: sshd execs the login shell with argv[0]
  # prefixed by '-', and bash only treats itself as a LOGIN shell when it sees
  # that. A script would lose it, and with it /etc/profile and the banner.
  if [ ! -e "$XNET_RESTRICTED_SHELL" ] || [ "$(readlink -f "$XNET_RESTRICTED_SHELL" 2>/dev/null)" != "$(readlink -f /bin/bash 2>/dev/null)" ]; then
    ln -sfn /bin/bash "$XNET_RESTRICTED_SHELL"
  fi

  # The gate is the ABSENCE of this path from /etc/shells. `chsh` and some
  # packages append to that file, and a single stray line would silently reopen
  # the Dropbear port to every account on the box, so it is removed on every run
  # rather than only checked once.
  if grep -qxF "$XNET_RESTRICTED_SHELL" /etc/shells 2>/dev/null; then
    sed -i "\|^${XNET_RESTRICTED_SHELL}\$|d" /etc/shells
    warn "Removed ${XNET_RESTRICTED_SHELL} from /etc/shells — listing it there lets every SSH account use the Dropbear port."
  fi
  # Dropbear needs /bin/bash listed or its OWN accounts cannot log in.
  grep -qxF /bin/bash /etc/shells 2>/dev/null || echo /bin/bash >> /etc/shells

  # Defence in depth: harmless when dropbear has no PAM, effective when it does.
  if [ -f /etc/pam.d/dropbear ] && ! grep -q 'ssh-dropbear-users' /etc/pam.d/dropbear 2>/dev/null; then
    sed -i '1a auth required pam_succeed_if.so user ingroup ssh-dropbear-users' /etc/pam.d/dropbear 2>/dev/null || true
  fi
  ok "Dropbear account gate ready (non-Dropbear accounts use ${XNET_RESTRICTED_SHELL})."
}

# ensure_dropbear_unit writes a clean dropbear.service running on the configured
# port (default 444). On upgrade, if the service file already exists, it is NOT
# overwritten so admin port changes from the panel are preserved. Only on fresh
# install the default port 444 is written.
ensure_dropbear_unit() {
  local bin keybin
  bin="$(command -v dropbear 2>/dev/null || echo /usr/sbin/dropbear)"
  keybin="$(command -v dropbearkey 2>/dev/null || echo /usr/bin/dropbearkey)"
  if [ ! -x "$bin" ]; then
    warn "dropbear binary not found — Dropbear will show as not installed."
    return 0
  fi
  mkdir -p /etc/dropbear
  # Stop the distro init from auto-starting dropbear on port 22.
  if [ -f /etc/default/dropbear ]; then
    if grep -q '^NO_START=' /etc/default/dropbear; then
      sed -i 's/^NO_START=.*/NO_START=1/' /etc/default/dropbear
    else
      echo 'NO_START=1' >> /etc/default/dropbear
    fi
  fi
  # Generate dropbear-format host keys once (idempotent).
  [ -f /etc/dropbear/dropbear_rsa_host_key ]     || "$keybin" -t rsa     -f /etc/dropbear/dropbear_rsa_host_key     >/dev/null 2>&1 || true
  [ -f /etc/dropbear/dropbear_ed25519_host_key ] || "$keybin" -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1 || true

  # Only write the service file on FRESH install (preserve admin port changes on upgrade)
  if [ ! -f /etc/systemd/system/dropbear.service ]; then
    cat > /etc/systemd/system/dropbear.service <<EOF
[Unit]
Description=Dropbear SSH (X-Net managed)
After=network.target

[Service]
Type=simple
# -K 60: send keepalive probes so a client that disappeared without a clean
# disconnect is detected and its session closed. Dropbear's default is 0 (off),
# which leaves dead sessions occupying max_login slots indefinitely. The panel
# rewrites this unit (with its own keepAlive value) on every SSH settings apply.
ExecStart=${bin} -F -E -p 444 -K 60 -r /etc/dropbear/dropbear_rsa_host_key -r /etc/dropbear/dropbear_ed25519_host_key
Restart=on-failure
RestartSec=5
StandardOutput=append:${XNET_DROPBEAR_LOG}
StandardError=append:${XNET_DROPBEAR_LOG}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  ensure_dropbear_logging

  # Ensure /bin/false and /usr/sbin/nologin are listed in /etc/shells so Dropbear
  # accepts login for SSH tunnel users (created with these shells by the panel).
  for sh in /bin/false /usr/sbin/nologin; do
    grep -qxF "$sh" /etc/shells 2>/dev/null || echo "$sh" >> /etc/shells
  done

  ensure_dropbear_user_gate
  ensure_session_gate_pam
  systemctl enable --now dropbear >/dev/null 2>&1 || true
  ok "Dropbear unit ready and started."
}

# ensure_stunnel_unit prepares stunnel4 with a self-signed cert and a config that
# wraps SSH-over-TLS on the default TLS port (443). ENABLED=1 lets the panel's
# `systemctl start stunnel4` actually bring tunnels up, but the unit is left
# disabled at boot so it doesn't seize port 443 from sing-box before the operator
# enables the TLS protocol.
ensure_stunnel_unit() {
  if ! command -v stunnel4 >/dev/null 2>&1 && ! command -v stunnel >/dev/null 2>&1; then
    warn "stunnel binary not found — Stunnel/TLS will show as not installed."
    return 0
  fi
  mkdir -p /etc/ssl/xnet /etc/stunnel
  # Self-signed cert so stunnel can start even before a real cert is issued.
  if [ ! -f /etc/ssl/xnet/cert.pem ] || [ ! -f /etc/ssl/xnet/key.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout /etc/ssl/xnet/key.pem -out /etc/ssl/xnet/cert.pem \
      -subj "/CN=xnet-ssh-tls" >/dev/null 2>&1 || true
  fi
  # The panel's apply helper (xnet-ssh-apply) owns /etc/stunnel/stunnel.conf and
  # forwards SSH-over-TLS to the DEDICATED sshd_tls instance on 127.0.0.1:2223,
  # which is independent of the main OpenSSH port. Remove any legacy single-file
  # config that hardcoded connect=127.0.0.1:22 — that one breaks the moment the
  # operator changes the main OpenSSH port (stunnel keeps dialing the dead :22).
  rm -f /etc/stunnel/xnet-ssh.conf 2>/dev/null || true
  cat > /etc/stunnel/stunnel.conf <<'EOF'
; X-Net SSH-over-TLS tunnel (bootstrap — the panel rewrites this on TLS apply).
; Forwards to the dedicated sshd_tls instance (127.0.0.1:2223), NOT the main
; sshd, so changing the OpenSSH port never breaks the TLS tunnel.
pid = /var/run/stunnel4.pid
[ssh-tls-direct]
accept = 443
connect = 127.0.0.1:2223
cert = /etc/ssl/xnet/cert.pem
key = /etc/ssl/xnet/key.pem
EOF
  if [ -f /etc/default/stunnel4 ]; then
    if grep -q '^ENABLED=' /etc/default/stunnel4; then
      sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
    else
      echo 'ENABLED=1' >> /etc/default/stunnel4
    fi
  else
    echo 'ENABLED=1' > /etc/default/stunnel4
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  # Do NOT auto-start: the default TLS port (443) commonly collides with a
  # sing-box Reality/TLS inbound on the same host. The unit is installed and the
  # panel starts it when the operator enables the TLS protocol (and picks a free
  # port). systemctl disable keeps it from grabbing 443 at boot.
  systemctl disable stunnel4 >/dev/null 2>&1 || true
  ok "Stunnel/TLS installed (enable from the panel; default port 443 may clash with Reality)."
}

# ensure_udpgw_unit writes a badvpn-udpgw.service bound to 127.0.0.1:7300 (the
# panel's default UDPGW port). Created disabled; the panel starts it on demand.
ensure_udpgw_unit() {
  local bin
  bin="$(command -v badvpn-udpgw 2>/dev/null || echo /usr/bin/badvpn-udpgw)"
  # Fallback: if the package wasn't available, build just the udpgw component
  # from source (best-effort). Keeps UDPGW working on distros/images that don't
  # ship a badvpn package.
  if [ ! -x "$bin" ] && [ ! -x /usr/local/bin/badvpn-udpgw ]; then
    build_badvpn_udpgw
  fi
  bin="$(command -v badvpn-udpgw 2>/dev/null || echo /usr/local/bin/badvpn-udpgw)"
  if [ ! -x "$bin" ]; then
    warn "badvpn-udpgw binary not found — BadVPN/UDPGW will show as not installed."
    return 0
  fi
  cat > /etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN UDP Gateway (X-Net managed)
After=network.target

[Service]
Type=simple
ExecStart=${bin} --listen-addr 127.0.0.1:7300 --max-clients 1024 --max-connections-for-client 16
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now badvpn-udpgw >/dev/null 2>&1 || true
  ok "BadVPN/UDPGW unit ready and started (127.0.0.1:7300)."
}

# build_badvpn_udpgw installs badvpn-udpgw to /usr/local/bin. It first tries a
# prebuilt binary (overridable via XNET_UDPGW_URL), then falls back to compiling
# ONLY the udpgw component from source. Best-effort: installs its own build deps
# (git/cmake/gcc) and warns instead of aborting on failure.
build_badvpn_udpgw() {
  local arch dl_arch dst="/usr/local/bin/badvpn-udpgw"

  # --- 1) prebuilt download (fast path) ---
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  dl_arch="amd64" ;;
    aarch64|arm64) dl_arch="arm64" ;;
    *) dl_arch="" ;;
  esac
  local url="${XNET_UDPGW_URL:-}"
  # Try known prebuilt mirrors when no explicit URL is set
  if [ -z "$url" ] && [ -n "$dl_arch" ]; then
    local mirrors=(
      "https://github.com/AliDbg/SH/raw/main/badvpn/badvpn-udpgw-linux-${dl_arch}"
      "https://github.com/fisabiliyusri/Lunatic/raw/main/badvpn/badvpn-udpgw"
      "https://raw.githubusercontent.com/MrAminiDev/tunnelMaster/main/badvpn/badvpn-udpgw64"
    )
    for mirror in "${mirrors[@]}"; do
      if curl -fsSL --connect-timeout 10 "$mirror" -o "$dst" 2>/dev/null && [ -s "$dst" ]; then
        chmod 0755 "$dst"
        # Verify it's an actual ELF binary, not an HTML 404 page
        if file "$dst" 2>/dev/null | grep -qi "ELF"; then
          ok "badvpn-udpgw installed from prebuilt mirror."
          return 0
        fi
        rm -f "$dst" 2>/dev/null || true
      fi
      rm -f "$dst" 2>/dev/null || true
    done
  elif [ -n "$url" ]; then
    if curl -fsSL "$url" -o "$dst" 2>/dev/null && [ -s "$dst" ]; then
      chmod 0755 "$dst"; ok "badvpn-udpgw installed from XNET_UDPGW_URL."; return 0
    fi
    rm -f "$dst" 2>/dev/null || true
  fi

  # --- 2) build from source ---
  info "Building badvpn-udpgw from source (best-effort)…"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y git cmake make gcc g++ build-essential >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git cmake make gcc gcc-c++ >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git cmake make gcc gcc-c++ >/dev/null 2>&1 || true
  fi
  if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
    warn "git/cmake unavailable — cannot build badvpn-udpgw."
    return 0
  fi
  local src="/tmp/xnet-badvpn"
  rm -rf "$src" 2>/dev/null || true
  if git clone --depth 1 https://github.com/ambrop72/badvpn.git "$src" >/dev/null 2>&1; then
    mkdir -p "$src/build"
    local blog="/tmp/xnet-badvpn-build.log"
    # badvpn is old C. Modern toolchains (e.g. gcc 14 on Ubuntu 24.04) promote
    # implicit function declarations / incompatible-pointer / int-conversion
    # warnings to HARD ERRORS, which breaks the build and leaves UDPGW
    # uninstalled. Relax those so the udpgw component compiles, and capture the
    # build output to $blog so a genuine failure is diagnosable (fail-loud)
    # instead of a silent skip.
    if ( cd "$src/build" \
          && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
               -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
               -DCMAKE_C_FLAGS="-fcommon -Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-discarded-qualifiers" \
          && make -j"$(nproc 2>/dev/null || echo 1)" ) >"$blog" 2>&1 && [ -f "$src/build/udpgw/badvpn-udpgw" ]; then
      install -m 0755 "$src/build/udpgw/badvpn-udpgw" "$dst"
      ok "badvpn-udpgw built and installed to ${dst}."
    else
      warn "badvpn-udpgw build failed; see ${blog} for the compiler error. UDPGW will be unavailable until installed."
    fi
  else
    warn "Could not clone badvpn source; UDPGW will be unavailable until installed manually."
  fi
  rm -rf "$src" 2>/dev/null || true
}

# ensure_slowdns_unit installs the dnstt SlowDNS server (dns-server) best-effort
# and writes a slowdns.service. dnstt is not packaged by distros, so we try a
# prebuilt download (overridable via XNET_DNSTT_URL); the unit is created either
# way so the subsystem shows as installed, and the panel starts it on demand once
# the operator sets the NS domain + keys.
ensure_slowdns_unit() {
  local arch dl_arch bin="/usr/local/bin/dns-server"
  if [ ! -x "$bin" ]; then
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64)  dl_arch="amd64" ;;
      aarch64|arm64) dl_arch="arm64" ;;
      *) dl_arch="" ;;
    esac
    local url="${XNET_DNSTT_URL:-}"
    if [ -z "$url" ] && [ -n "$dl_arch" ]; then
      # Try multiple mirrors for dnstt-server binary
      local mirrors=(
        "https://github.com/AliDbg/SH/raw/main/dnstt/dnstt-server-linux-${dl_arch}"
        "https://github.com/fisabiliyusri/Lunatic/raw/main/dnstt/dnstt-server-linux-${dl_arch}"
        "https://github.com/MrAminiDev/tunnelMaster/raw/main/dnstt/dnstt-server"
        "https://github.com/nickoala/dnstt/releases/download/v0.20220208.0/dnstt-server-linux-${dl_arch}"
      )
      for mirror in "${mirrors[@]}"; do
        if curl -fsSL --connect-timeout 10 "$mirror" -o "$bin" 2>/dev/null && [ -s "$bin" ]; then
          # Verify it's an actual binary, not an HTML 404 page
          if file "$bin" 2>/dev/null | grep -qi "ELF"; then
            chmod 0755 "$bin"
            ok "SlowDNS dnstt server installed to ${bin}."
            url="done"
            break
          fi
          rm -f "$bin" 2>/dev/null || true
        fi
        rm -f "$bin" 2>/dev/null || true
      done
      # If download failed, try building from Go source
      if [ "$url" != "done" ] && command -v go >/dev/null 2>&1; then
        info "Trying to build dnstt from Go source…"
        if GOBIN=/usr/local/bin go install www.bamsoftware.com/git/dnstt.git/dnstt-server@latest 2>/dev/null; then
          if [ -x "/usr/local/bin/dnstt-server" ]; then
            mv /usr/local/bin/dnstt-server "$bin"
            ok "SlowDNS dnstt server built from Go source."
            url="done"
          fi
        fi
      fi
      # Final fallback: use the bundled binary shipped with the installer
      if [ "$url" != "done" ]; then
        local bundled="$(dirname "$(readlink -f "$0")")/dns-server"
        if [ -f "$bundled" ] && file "$bundled" 2>/dev/null | grep -qi "ELF"; then
          install -m 0755 "$bundled" "$bin"
          ok "SlowDNS dnstt server installed from bundled binary."
          url="done"
        fi
      fi
      if [ "$url" != "done" ]; then
        warn "Could not auto-download the SlowDNS (dnstt) server from any mirror. Install /usr/local/bin/dns-server manually to enable SlowDNS."
      fi
    elif [ -n "$url" ]; then
      if curl -fsSL "$url" -o "$bin" 2>/dev/null && [ -s "$bin" ]; then
        chmod 0755 "$bin"
        ok "SlowDNS dnstt server installed to ${bin}."
      else
        rm -f "$bin" 2>/dev/null || true
        warn "Could not download dnstt from ${url}."
      fi
    fi
  fi
  # Create the unit regardless so the subsystem is recognized. ExecStart uses the
  # SlowDNS port (53) and forwards to the dns-protocol sshd instance (2224); the
  # NS domain + private key are supplied from panel settings at start time.
  cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=SlowDNS (dnstt) server (X-Net managed)
After=network.target

[Service]
Type=simple
EnvironmentFile=-/etc/xnet/slowdns.env
ExecStart=/usr/local/bin/dns-server -udp :53 -privkey-file /etc/xnet/slowdns.key \${XNET_SLOWDNS_NSDOMAIN} 127.0.0.1:2224
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/xnet
  systemctl disable slowdns >/dev/null 2>&1 || true
  if [ -x /usr/local/bin/dns-server ]; then
    ok "SlowDNS unit ready (started by panel on demand)."
  else
    warn "SlowDNS unit created but dns-server binary is missing — install it to enable SlowDNS."
  fi
}

# setup_secondary_sshd provisions the per-protocol OpenSSH instances the panel's
# WebSocket/TLS/SlowDNS proxies relay to (127.0.0.1:2222/2223/2224). Tunnel users
# (ssh-ws/tls/slowdns) authenticate against these localhost-only daemons instead
# of the public port 22, which is what lets us safely restrict port 22 to
# ssh-tcp-users. Idempotent; safe on install, upgrade and reinstall.
setup_secondary_sshd() {
  command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ] || {
    # Ensure the OpenSSH server is present (it provides /usr/sbin/sshd).
    if command -v apt-get >/dev/null 2>&1; then free_apt_lock; apt-get install -y openssh-server >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then dnf install -y openssh-server >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then yum install -y openssh-server >/dev/null 2>&1 || true
    fi
  }
  local sshd_bin
  sshd_bin="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
  [ -x "$sshd_bin" ] || { warn "sshd binary not found — secondary SSH instances skipped (WS/TLS/SlowDNS need it)."; return 0; }

  # Host keys (generated once; harmless if they already exist).
  ssh-keygen -A >/dev/null 2>&1 || true

  # sftp-server path differs per distro.
  local sftp="/usr/lib/openssh/sftp-server"
  [ -x "$sftp" ] || sftp="/usr/libexec/openssh/sftp-server"

  local svc port grp
  for entry in "ws:2222:ssh-ws-users ssh-tls-users" "tls:2223:ssh-tls-users" "dns:2224:ssh-slowdns-users"; do
    svc="${entry%%:*}"
    port="$(echo "$entry" | cut -d: -f2)"
    grp="$(echo "$entry" | cut -d: -f3)"
    # ALWAYS write internal sshd configs with fixed ports (2222/2223/2224).
    # These are internal-only (127.0.0.1). Panel proxy handles public ports.
    cat > "/etc/ssh/sshd_config_${svc}" <<EOF
Port ${port}
ListenAddress 127.0.0.1
AllowGroups ${grp}
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes
AllowTcpForwarding yes
PermitTunnel yes
GatewayPorts clientspecified
# Reap sessions whose client vanished without disconnecting cleanly. Without
# these, a dropped mobile connection leaves a half-open session alive forever,
# which keeps showing the user as online and consumes a max_login slot. The
# panel overwrites both values from its SSH settings on every apply.
ClientAliveInterval 15
ClientAliveCountMax 2
Subsystem sftp ${sftp}
EOF
    cat > "/etc/systemd/system/sshd-${svc}.service" <<EOF
[Unit]
Description=OpenSSH daemon (${svc} protocol, X-Net managed)
After=network.target

[Service]
ExecStart=${sshd_bin} -D -f /etc/ssh/sshd_config_${svc}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  for svc in ws tls dns; do
    systemctl enable --now "sshd-${svc}" >/dev/null 2>&1 || true
  done
  ok "Per-protocol SSH instances ready (WS:2222, TLS:2223, SlowDNS:2224)."
}

# harden_main_sshd restricts the main OpenSSH daemon (port 22) to ssh-tcp-users
# so users created for tunnel protocols (Dropbear/WS/TLS/SlowDNS) can NOT open a
# shell on port 22. To avoid ever locking the operator out, root, the invoking
# sudo user and every currently logged-in user are added to ssh-tcp-users first,
# and the new config is validated with `sshd -t` before the service is restarted
# (the AllowGroups line is rolled back if validation fails). Idempotent; runs on
# install, upgrade and reinstall.
harden_main_sshd() {
  [ -f /etc/ssh/sshd_config ] || return 0
  for grp in ssh-tcp-users ssh-ws-users ssh-tls-users ssh-slowdns-users ssh-dropbear-users; do
    groupadd -f "$grp" >/dev/null 2>&1 || true
  done
  # Preserve shell access for the people who must keep it.
  local keep u
  keep="root ${SUDO_USER:-}"
  for u in $(who 2>/dev/null | awk '{print $1}' | sort -u); do
    keep="$keep $u"
  done
  keep="$(echo "$keep" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  for u in $keep; do
    [ -n "$u" ] || continue
    id "$u" >/dev/null 2>&1 && usermod -aG ssh-tcp-users "$u" >/dev/null 2>&1 || true
  done
  # Restrict port 22 to ssh-tcp-users only.
  sed -i '/^[[:space:]]*AllowGroups/d' /etc/ssh/sshd_config
  echo "AllowGroups ssh-tcp-users" >> /etc/ssh/sshd_config
  if sshd -t >/dev/null 2>&1; then
    systemctl restart sshd >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
    ok "Main sshd restricted to ssh-tcp-users (tunnel users blocked on port 22)."
  else
    warn "sshd config validation failed — reverting AllowGroups to avoid lockout."
    sed -i '/^[[:space:]]*AllowGroups[[:space:]][[:space:]]*ssh-tcp-users[[:space:]]*$/d' /etc/ssh/sshd_config
  fi
}

# ----- deploy files -----------------------------------------------------------
deploy_files() {
  info "Deploying files to ${INSTALL_DIR}…"

  # Create service user if needed
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin "$SERVICE_USER"
    ok "Service user '$SERVICE_USER' created."
  fi

  # Journal read access. The panel reads SSH authentication lines to attribute
  # Dropbear tunnel-only sessions to an account (nothing else can — see
  # ensure_dropbear_logging). It prefers the plain log file, but on a host where
  # that is unavailable the journal is the fallback, and a non-root user sees
  # only its own journal unless it is in this group. Idempotent; the group is
  # absent on non-systemd hosts, where the failure is harmless.
  usermod -aG systemd-journal "$SERVICE_USER" >/dev/null 2>&1 || true

  # Create the SSH protocol groups up-front (idempotent) so they exist on EVERY
  # node — panel or agent — before any account is provisioned. Without these,
  # `useradd -G ssh-tcp-users` fails with "group does not exist" on a node that
  # never ran the SSH subsystem setup, leaving the account's node assignment in a
  # failed state. groupadd -f is a no-op when the group already exists.
  for grp in ssh-tcp-users ssh-ws-users ssh-tls-users ssh-slowdns-users ssh-dropbear-users; do
    groupadd -f "$grp" >/dev/null 2>&1 || true
  done
  ok "SSH protocol groups ensured."

  # Create directories
  mkdir -p "${INSTALL_DIR}/data"
  mkdir -p /etc/sing-box
  mkdir -p /etc/ssh
  # ACME HTTP-01 webroot — served by the panel's port-80 WebSocket proxy so
  # Let's Encrypt can validate via --webroot without certbot needing to bind
  # port 80 itself. Owned by the service user so the panel's health check can
  # write test tokens; certbot runs as root and can also write here.
  mkdir -p /var/lib/xnet/acme/.well-known/acme-challenge

  # Stop service if running
  if systemctl is-active --quiet xnet 2>/dev/null; then
    info "Stopping existing xnet service…"
    systemctl stop xnet
  fi

  # Remove stale lock files that prevent useradd/usermod
  rm -f /etc/passwd.lock /etc/shadow.lock /etc/group.lock /etc/gshadow.lock

  # --- Binary ---
  install -m 0755 "$SCRIPT_DIR/xnet-server" "${INSTALL_DIR}/xnet-server"
  ok "Backend binary installed."

  # --- Frontend ---
  rm -rf "${INSTALL_DIR}/dist"
  cp -r "$SCRIPT_DIR/dist" "${INSTALL_DIR}/dist"
  ok "Frontend installed."

  # --- SSH apply helper script ---
  install -m 0755 "$SCRIPT_DIR/xnet-ssh-apply" "${INSTALL_DIR}/xnet-ssh-apply"
  # Strip any CR (\r) so a helper shipped/edited with Windows CRLF line endings
  # never breaks the shebang ("/usr/bin/env: 'bash\r': No such file or directory").
  sed -i 's/\r$//' "${INSTALL_DIR}/xnet-ssh-apply" 2>/dev/null || true
  chmod 0755 "${INSTALL_DIR}/xnet-ssh-apply"
  ln -sf "${INSTALL_DIR}/xnet-ssh-apply" /usr/local/bin/xnet-ssh-apply
  ok "xnet-ssh-apply helper installed."

  # --- Optional helper scripts (if present) ---
  # xnet-fix-banner / xnet-diag-* are installed alongside the rest so they can be
  # run straight from /opt/xnet on a server that no longer has the source tree.
  # xnet-fix-banner resolves xnet-ssh-info from its own directory, which is
  # exactly where install.sh puts it.
  # xnet-fix-sudoers is in this list because the sudoers failure path below
  # tells the operator to run it. It was never copied, so that instruction sent
  # them looking for a file that is not on the machine.
  for script in xnet-install-sshd.sh xnet-cert-install.sh healthcheck.sh \
                xnet-fix-banner.sh xnet-diag-banner.sh xnet-diag-traffic.sh \
                xnet-fix-sudoers.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
      install -m 0755 "$SCRIPT_DIR/$script" "${INSTALL_DIR}/${script%.sh}"
    fi
  done

  # --- xnet-ssh-info (per-account stats: banner generator + Dropbear lookup) ---
  # Shipped as a real file rather than an inline heredoc so there is exactly one
  # copy to keep correct. xnet-ssh-apply refuses to configure banners without it.
  if [ -f "$SCRIPT_DIR/xnet-ssh-info" ]; then
    install -m 0755 "$SCRIPT_DIR/xnet-ssh-info" "${INSTALL_DIR}/xnet-ssh-info"
    # Strip any CR so a file edited on Windows does not break the shebang.
    sed -i 's/\r$//' "${INSTALL_DIR}/xnet-ssh-info" 2>/dev/null || true
    chmod 0755 "${INSTALL_DIR}/xnet-ssh-info"
    ok "xnet-ssh-info helper installed."
  else
    warn "xnet-ssh-info not found next to install.sh — SSH account stats will not work."
  fi

  # --- Management CLI (xnet) ---
  # Installed to /opt/xnet/xnet-cli and symlinked as /usr/local/bin/xnet so the
  # operator can run `xnet` from anywhere for prerequisites, updates, port/login
  # settings, health checks, and service restarts.
  if [ -f "$SCRIPT_DIR/xnet-cli.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/xnet-cli.sh" "${INSTALL_DIR}/xnet-cli"
    ln -sf "${INSTALL_DIR}/xnet-cli" /usr/local/bin/xnet
    ok "Management CLI installed (run: xnet)."
  fi

  # --- Session admission gate (PAM) ---
  # Refuses a login that would exceed max_login, at authentication time, so the
  # client gets a clean "too many logins" instead of connecting and being killed
  # a few seconds later. Root-owned: PAM runs it as root during authentication,
  # so the unprivileged panel user must not be able to rewrite it.
  if [ -f "$SCRIPT_DIR/xnet-session-gate.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/xnet-session-gate.sh" "${INSTALL_DIR}/xnet-session-gate"
    ok "SSH session admission gate installed."
  fi

  # --- In-panel updater ---
  # Lets the Dashboard move the panel to any published release. It runs DETACHED
  # (systemd-run) because install.sh restarts the panel partway through, so it
  # cannot be a child of the process that asked for the update.
  #
  # Root-owned like the other privileged helpers: the unprivileged panel user
  # launches it through sudo, so it must not be a file that same user can
  # rewrite — that would turn a panel compromise into arbitrary root execution.
  if [ -f "$SCRIPT_DIR/xnet-update.sh" ]; then
    install -m 0755 "$SCRIPT_DIR/xnet-update.sh" "${INSTALL_DIR}/xnet-update"
    ok "In-panel updater installed (Dashboard → panel version)."
  fi

  # --- Ownership (MUST come before setcap — chown strips capabilities!) ---
  chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}" /etc/sing-box
  chown -R "${SERVICE_USER}:${SERVICE_USER}" /var/lib/xnet 2>/dev/null || true
  chmod 0755 /var/lib/xnet /var/lib/xnet/acme 2>/dev/null || true
  ok "File permissions set."
  # xnet-ssh-info / xnet-ssh-greet are reachable through sudo from every SSH
  # account, so they must stay root-owned — the unprivileged panel user must not
  # be able to rewrite a script that any account can then run as root.
  # (xnet-fc / xnet-fc-pam are the retired v8 hooks; xnet-ssh-apply deletes them.)
  # xnet-update is here for the same reason: the unprivileged panel user
  # launches it through sudo, so it must not be a file that same user can
  # rewrite — that would turn a panel compromise into arbitrary root execution.
  for helper in xnet-ssh-info xnet-ssh-greet xnet-update xnet-session-gate; do
    if [ -f "${INSTALL_DIR}/${helper}" ]; then
      chown root:root "${INSTALL_DIR}/${helper}" 2>/dev/null || true
      chmod 0755 "${INSTALL_DIR}/${helper}"
    fi
  done

  # --- setcap AFTER chown (chown strips extended attributes including caps) ---
  if ! command -v setcap >/dev/null 2>&1; then
    die "setcap not found. Install libcap2-bin (apt) or libcap (dnf) and re-run."
  fi
  setcap 'cap_net_bind_service=+ep' "${INSTALL_DIR}/xnet-server"
  ok "cap_net_bind_service applied (allows binding to ports < 1024)."

  # --- Security: ensure main sshd only allows ssh-tcp-users ---
  # Tunnel-only users (dropbear/ws/tls/dns) must NOT be able to get a shell via
  # port 22. First provision the per-protocol sshd instances the WS/TLS/SlowDNS
  # proxies relay to, THEN restrict port 22 (with lockout protection). Applied on
  # every run (install / upgrade / reinstall).
  setup_secondary_sshd
  harden_main_sshd
}

# ----- sudoers ----------------------------------------------------------------
configure_sudoers() {
  info "Configuring sudoers for xnet service user…"

  # IMPORTANT: sudo rejects wildcards in the MIDDLE of command arguments (e.g.
  # `systemctl * sshd`). Such a line invalidates the ENTIRE sudoers file, which
  # silently strips ALL of the xnet user's privileges — breaking sing-box
  # reload/restart and SSH provisioning. So we use only explicit verb+service
  # entries (and trailing-arg wildcards, which sudo DOES allow), then validate
  # with visudo before activating.
  local tmp="/etc/sudoers.d/.xnet.tmp"   # dotted name => ignored by sudo while staging

  cat > "$tmp" <<'EOF'
# ---- X-Net Panel — sudoers rules ----
# SSH user management
xnet ALL=(root) NOPASSWD: /usr/sbin/useradd, /usr/sbin/usermod, /usr/sbin/userdel, /usr/sbin/chpasswd
xnet ALL=(root) NOPASSWD: /sbin/useradd, /sbin/usermod, /sbin/userdel, /sbin/chpasswd
xnet ALL=(root) NOPASSWD: /usr/bin/chpasswd, /usr/bin/pkill, /bin/pkill, /usr/bin/kill, /bin/kill
xnet ALL=(root) NOPASSWD: /usr/sbin/groupadd, /sbin/groupadd
# gpasswd: removes a user from a protocol group when its SSH method changes, so
# the account loses access to the protocol it is no longer assigned to (each
# sshd instance is gated by AllowGroups on exactly one of these groups).
xnet ALL=(root) NOPASSWD: /usr/bin/gpasswd, /bin/gpasswd, /usr/sbin/gpasswd
# passwd: read-only account status (`passwd -S <user>`) is how the panel checks
# that a provisioned account can ACTUALLY authenticate — that its hash is
# present and not locked — instead of trusting that provisioning reported
# success. Password writes still go through chpasswd.
xnet ALL=(root) NOPASSWD: /usr/bin/passwd, /bin/passwd
# Live connection inspection: `ss -tnp` reports the PID owning each established
# socket, which is how the panel resolves the source IP of a connected SSH user.
# Needed because /proc/<pid>/fd of an SSH account's process is root-only, so an
# unprivileged panel cannot read the peer address any other way.
xnet ALL=(root) NOPASSWD: /usr/sbin/ss, /sbin/ss, /usr/bin/ss, /bin/ss
# Auth-log reading: a Dropbear tunnel-only session never runs a process as the
# account, so its authentication log line is the ONLY record of which account
# owns the connection — without it such accounts show 0 online and 0 traffic.
# The panel prefers /var/log/xnet/dropbear.log (world-readable, written by the
# unit) and falls back to journalctl, which the service user cannot read on its
# own. Read-only; journalctl cannot modify anything.
xnet ALL=(root) NOPASSWD: /usr/bin/journalctl, /bin/journalctl
# Firewall
xnet ALL=(root) NOPASSWD: /usr/sbin/nft, /sbin/nft
xnet ALL=(root) NOPASSWD: /usr/sbin/ufw, /usr/bin/ufw, /usr/bin/firewall-cmd, /bin/firewall-cmd
# systemctl daemon-reload (no service argument)
xnet ALL=(root) NOPASSWD: /usr/bin/systemctl daemon-reload, /bin/systemctl daemon-reload
# Privileged helpers (trailing-arg wildcard is permitted by sudo)
xnet ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-apply, /opt/xnet/xnet-ssh-apply *
xnet ALL=(root) NOPASSWD: /opt/xnet/xnet-cert-install, /opt/xnet/xnet-cert-install *
# SSH user account info: any authenticated SSH user may run xnet-ssh-info to
# see their own account stats (expiry, traffic, max-login). The script prints
# only the row matching the supplied username and never modifies anything.
# The per-session hooks (/etc/ssh/sshrc, /etc/profile.d/xnet-ssh-info.sh) run
# unprivileged and depend on this; without it a session shows the banner text
# and no account details at all. xnet-ssh-apply re-installs the same rule as
# /etc/sudoers.d/xnet-ssh-info so upgraded servers are covered too.
# The Defaults !requiretty directive is not portable and causes visudo to
# reject the generated fragment on some distributions. Omit it so the sudoers
# fragment is portable across Debian/Ubuntu and RHEL-family hosts. If a host
# requires a !requiretty rule, operators should add it manually into a safe,
# audited sudoers fragment via visudo.
ALL ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-info, /opt/xnet/xnet-ssh-info *
# TLS certificate management (issuance needs args: certonly --webroot/--standalone ...)
xnet ALL=(root) NOPASSWD: /usr/bin/certbot, /usr/bin/certbot *, /bin/certbot, /bin/certbot *
# Panel self-restart via a transient unit (separate cgroup) so the restart
# survives the xnet service being stopped. Trailing wildcard is permitted.
xnet ALL=(root) NOPASSWD: /usr/bin/systemd-run *, /bin/systemd-run *
EOF

  # Explicit verb+service systemctl rules (valid sudoers — no mid-arg wildcard).
  {
    echo "# systemctl control for managed services (explicit verb+service)"
    local svc verb sc
    for svc in sing-box sshd ssh ssh.socket sshd.socket sshd-ws sshd-tls sshd-dns xnet-ws dropbear stunnel4 badvpn-udpgw slowdns xnet; do
      for sc in /usr/bin/systemctl /bin/systemctl; do
        for verb in start stop restart reload status is-active enable disable; do
          echo "xnet ALL=(root) NOPASSWD: ${sc} ${verb} ${svc}"
        done
      done
    done
  } >> "$tmp"

  chmod 440 "$tmp"

  # Validate BEFORE activating; an invalid file would break sudo for the panel.
  #
  # The validation output is REPORTED, not discarded. This used to run with
  # `>/dev/null 2>&1` and fail with a single warn line, so the one message that
  # explained the failure — visudo naming the offending line — was thrown away.
  # When no /etc/sudoers.d/xnet existed yet, "left existing rules unchanged" also
  # meant "left NO rules at all", and the panel came up unable to run a single
  # privileged command: no SSH user creation, no service restart, no port change.
  # That looked like a dozen unrelated runtime failures instead of one install
  # step that did not happen.
  local visudo_out
  if visudo_out="$(visudo -cf "$tmp" 2>&1)"; then
    mv -f "$tmp" /etc/sudoers.d/xnet
    rm -f /etc/sudoers.d/xnet-ssh-apply 2>/dev/null || true
    ok "Sudoers configured and validated (visudo OK)."

    # Also provision a small helper fragment (/etc/sudoers.d/xnet-apply) used
    # by previous installations and convenience scripts. Validate it separately
    # with visudo to prevent accidental sudo lockout.
    cat > /etc/sudoers.d/xnet-apply <<'EOS'
# Helper fragment allowing xnet to run the apply helper and a few passwd helpers
xnet ALL=(root) NOPASSWD: /opt/xnet/xnet-ssh-apply, /opt/xnet/xnet-ssh-apply *
xnet ALL=(root) NOPASSWD: /usr/bin/gpasswd, /bin/gpasswd, /usr/sbin/gpasswd
xnet ALL=(root) NOPASSWD: /usr/bin/passwd, /bin/passwd
EOS
    chmod 0440 /etc/sudoers.d/xnet-apply || true
    if ! visudo -c -f /etc/sudoers.d/xnet-apply >/dev/null 2>&1; then
      warn "Created /etc/sudoers.d/xnet-apply but visudo rejected it — removing to be safe."
      rm -f /etc/sudoers.d/xnet-apply || true
    else
      ok "/etc/sudoers.d/xnet-apply installed and validated."
    fi
  else
    # Keep the rejected file for inspection under a name sudo ignores (the dot
    # prefix), so the operator can see exactly what was generated.
    mv -f "$tmp" /etc/sudoers.d/.xnet.rejected 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    err_line "Generated sudoers FAILED visudo validation:"
    printf '%s\n' "$visudo_out" | sed 's/^/    /'
    err_line "The rejected file was kept at /etc/sudoers.d/.xnet.rejected for inspection."
    if [ -f /etc/sudoers.d/xnet ]; then
      warn "Existing /etc/sudoers.d/xnet left in place — the panel keeps its previous privileges."
    else
      # Nothing to fall back on. Say plainly what will not work, because every
      # later symptom traces back here.
      err_line "There is NO /etc/sudoers.d/xnet on this host, so the panel has NO privileges."
      err_line "SSH account creation, service restarts and port changes will all fail with"
      err_line "\"sudo: ... not allowed\" until this is fixed. Run: xnet fix sudoers"
    fi
  fi
}

# err_line prints an error-styled line without aborting, for multi-line reports.
err_line() { echo -e "  ${C_RED}✗${C_RESET} $*" >&2; }

# ----- env file ---------------------------------------------------------------
create_env() {
  gen_jwt
  [ -n "$WEB_BASE_PATH" ] || gen_base_path
  cat > "${INSTALL_DIR}/.env" <<EOF
PORT=${PANEL_PORT}
DATABASE_PATH=${INSTALL_DIR}/data/xnet.db
STATIC_DIR=${INSTALL_DIR}/dist
JWT_SECRET=${JWT_SECRET}
WEB_BASE_PATH=${WEB_BASE_PATH}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
SINGBOX_CONFIG_PATH=/etc/sing-box/config.json
SINGBOX_BINARY_PATH=${SINGBOX_BIN}
NODE_ROLE=${NODE_ROLE}
AGENT_ALLOWED_CIDRS=${AGENT_ALLOWED_CIDRS}
NODE_CLIENT_SCHEME=http
NODE_ID=${NODE_ID}
NODE_API_KEY=${NODE_API_KEY}
NODE_SECRET_KEY=${NODE_SECRET_KEY}
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}/.env"
  ok "Environment file created."
}

# ----- Central Session Manager -----------------------------------------------
# effective_node_role echoes "panel" or "agent": it prefers the role persisted
# in the panel .env (authoritative on upgrades), falling back to the in-memory
# NODE_ROLE set by a fresh install's prompt, defaulting to "panel". The Central
# Session Manager is installed and the local node is wired to it ONLY on a panel
# host — an agent must NOT run its own manager (that would make enforcement
# per-server instead of GLOBAL). Agents point at the panel's manager instead.
effective_node_role() {
  local r="$NODE_ROLE"
  if [ -f "${INSTALL_DIR}/.env" ]; then
    local env_role
    env_role="$(grep '^NODE_ROLE=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$env_role" ] && r="$env_role"
  fi
  case "$r" in
  agent) echo "agent" ;;
  *) echo "panel" ;;
  esac
}

# sm_prepare_secrets resolves the admin + node HMAC secrets used by BOTH the
# manager service and the panel, reusing any that already exist so the
# panel<->manager pairing survives upgrades:
#   - admin secret: reuse the one already in the panel .env (if present)
#   - node secret : reuse the one already in the manager env file (if present)
# Otherwise fresh random secrets are generated. Safe to call in both flows.
sm_prepare_secrets() {
  local existing_admin existing_node
  # NOTE: `|| true` is required — under `set -Eeuo pipefail` a non-matching grep
  # exits 1 and would abort the whole installer via the ERR trap. A missing key
  # is normal (fresh install, or upgrade from a pre-Session-Manager version).
  existing_admin="$(grep '^SESSION_MANAGER_ADMIN_SECRET=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2- || true)"
  # XNET_SM_NODE_SECRETS is "id:secret"; strip the "id:" prefix to recover the secret.
  existing_node="$(grep '^XNET_SM_NODE_SECRETS=' "$SM_ENV_FILE" 2>/dev/null | cut -d= -f2- | sed 's/^[^:]*://' || true)"
  SM_ADMIN_SECRET="${existing_admin:-$(rand_hex 32)}"
  SM_NODE_SECRET="${existing_node:-$(rand_hex 32)}"
  # Register the local node under the panel's node id (falls back to node-local)
  # so the manager's data-plane is ready and doesn't warn about missing secrets.
  SM_NODE_ID="${NODE_ID:-node-local}"
}

# sm_ensure_panel_env wires the panel .env to the local manager by appending the
# SESSION_MANAGER_* lines, but ONLY when (a) the manager binary is actually in
# the bundle (so we never mark the panel "configured" without a manager to talk
# to) and (b) the lines are not already present. Idempotent; used by BOTH fresh
# and upgrade flows (create_env writes the base .env without these lines).
sm_ensure_panel_env() {
  # The admin API + local manager live on the PANEL host only; agents have no
  # local manager to point the admin client at.
  [ "$(effective_node_role)" = "panel" ] || return 0
  [ -f "$SCRIPT_DIR/xnet-session-manager" ] || return 0
  [ -f "${INSTALL_DIR}/.env" ] || return 0
  if grep -q '^SESSION_MANAGER_URL=' "${INSTALL_DIR}/.env" 2>/dev/null; then
    return 0
  fi
  cat >> "${INSTALL_DIR}/.env" <<EOF
SESSION_MANAGER_URL=${SM_URL}
SESSION_MANAGER_ACTOR_ID=${SM_ACTOR_ID}
SESSION_MANAGER_ADMIN_SECRET=${SM_ADMIN_SECRET}
EOF
  ok "Session Manager wiring added to panel .env."
}

# ensure_session_admission_env turns on the in-core, pre-connection device-limit
# gate by default (SINGBOX_FORCE_SESSION_ADMISSION=1). This is the HARD cap: a
# device beyond a client's limit is denied admission before any data flows (no
# more post-hoc "connect then get killed" flapping). install.sh installs ONLY the
# X-NET fork core, which compiles the gate in, so forcing it is safe here; it is
# a NO-OP until an admin sets a per-client device cap (max_connections / the
# "Devices" field), and the post-write `sing-box check` still guards the config.
# The key is appended only when absent, so an operator who removed it is honored.
ensure_session_admission_env() {
  [ -f "${INSTALL_DIR}/.env" ] || return 0
  # 1) Force the in-core gate ON (hard per-node cap). Appended only when absent.
  if ! grep -q '^SINGBOX_FORCE_SESSION_ADMISSION=' "${INSTALL_DIR}/.env" 2>/dev/null; then
    echo "SINGBOX_FORCE_SESSION_ADMISSION=1" >> "${INSTALL_DIR}/.env"
    ok "In-core device-limit gate enabled (hard cap; SINGBOX_FORCE_SESSION_ADMISSION=1)."
  fi
  # 1b) Fail-CLOSED by default: when the manager is unreachable, deny new
  #     connections (production-safe). Operators can set =allow for fail-open.
  if ! grep -q '^SESSION_ADMISSION_FAILURE_MODE=' "${INSTALL_DIR}/.env" 2>/dev/null; then
    echo "SESSION_ADMISSION_FAILURE_MODE=reject" >> "${INSTALL_DIR}/.env"
    ok "Admission failure mode = reject (fail-closed) by default."
  fi
  # 2) Point the node's in-core gate at the CENTRAL manager (RemoteStore) so caps
  #    enforce globally AND the panel's Session Manager page sees live sessions.
  #    Only when the manager binary is in the bundle (co-located manager) and the
  #    node credentials are prepared. node_id/node_secret MUST match the manager's
  #    XNET_SM_NODE_SECRETS (written by install_session_manager from the same vars).
  # Only auto-wire to the CO-LOCATED manager on a panel host. An agent must not
  # point at 127.0.0.1 (no manager there); its central endpoint + node creds are
  # provided out-of-band (see the multi-node deploy notes) — if SESSION_ADMISSION_*
  # is pre-set in the agent's .env it is honored as-is and left untouched here.
  if [ "$(effective_node_role)" = "panel" ] && [ -f "$SCRIPT_DIR/xnet-session-manager" ] && [ -n "$SM_NODE_ID" ] && [ -n "$SM_NODE_SECRET" ]; then
    if ! grep -q '^SESSION_ADMISSION_MANAGER_ENDPOINT=' "${INSTALL_DIR}/.env" 2>/dev/null; then
      cat >> "${INSTALL_DIR}/.env" <<EOF
SESSION_ADMISSION_MANAGER_ENDPOINT=${SM_GRPC_ENDPOINT}
SESSION_ADMISSION_NODE_ID=${SM_NODE_ID}
SESSION_ADMISSION_NODE_SECRET=${SM_NODE_SECRET}
EOF
      ok "Node wired to central Session Manager (RemoteStore @ ${SM_GRPC_ENDPOINT}, node_id=${SM_NODE_ID})."
    fi
    # 2b) PUBLIC manager endpoint the panel PUSHES to remote agents during
    #     automatic credential distribution. Agents cannot reach the panel's
    #     loopback SESSION_ADMISSION_MANAGER_ENDPOINT, so we publish a reachable
    #     address here. Priority: explicit XNET_SM_PUBLIC_ENDPOINT, else — when
    #     the manager binds a public interface (multi-node) — <public-ip>:<port>.
    #     Left unset for a loopback-only (single-server) bind; the panel then
    #     falls back to the loopback endpoint, which is harmless with no agents.
    if ! grep -q '^SESSION_ADMISSION_PUBLIC_ENDPOINT=' "${INSTALL_DIR}/.env" 2>/dev/null; then
      sm_public_ep="${XNET_SM_PUBLIC_ENDPOINT:-}"
      if [ -z "$sm_public_ep" ]; then
        case "$SM_GRPC_BIND" in
          127.0.0.1:*|localhost:*) : ;;  # loopback bind → no public endpoint
          *)
            detect_ip
            sm_grpc_port="${SM_GRPC_BIND##*:}"
            if [ "$ACCESS_IP" != "<server-ip>" ] && [ -n "$sm_grpc_port" ]; then
              sm_public_ep="${ACCESS_IP}:${sm_grpc_port}"
            fi
            ;;
        esac
      fi
      if [ -n "$sm_public_ep" ]; then
        echo "SESSION_ADMISSION_PUBLIC_ENDPOINT=${sm_public_ep}" >> "${INSTALL_DIR}/.env"
        ok "Agents will be auto-pushed the public manager endpoint ${sm_public_ep}."
      fi
    fi
  fi
}

# install_session_manager installs the manager binary, writes its env file and
# systemd unit, and starts it. The admin HTTP surface binds 127.0.0.1 only, so
# it is never reachable off-box (no firewall rule needed) — HMAC still
# authenticates every admin call. Secrets must already be set by
# sm_prepare_secrets. If the binary is not in the bundle (older package) it warns
# and returns so the rest of the install proceeds unchanged.
install_session_manager() {
  if [ "$(effective_node_role)" != "panel" ]; then
    info "Agent node — NOT installing a local Session Manager (agents connect to the panel's central manager for GLOBAL enforcement)."
    return 0
  fi
  if [ ! -f "$SCRIPT_DIR/xnet-session-manager" ]; then
    warn "xnet-session-manager binary not in bundle — skipping Session Manager service."
    warn "The Session Manager page will show 'not configured' until a manager is wired."
    return 0
  fi

  info "Installing Central Session Manager (localhost-only)…"
  systemctl stop xnet-session-manager >/dev/null 2>&1 || true
  install -m 0755 "$SCRIPT_DIR/xnet-session-manager" "$SM_BIN"

  mkdir -p /etc/xnet
  cat > "$SM_ENV_FILE" <<EOF
XNET_SM_GRPC_ADDR=${SM_GRPC_BIND}
XNET_SM_HTTP_ADDR=${SM_HTTP_ADDR}
XNET_SM_BACKEND=memory
XNET_SM_ADMIN_SECRETS=${SM_ACTOR_ID}:${SM_ADMIN_SECRET}
XNET_SM_NODE_SECRETS=${SM_NODE_ID}:${SM_NODE_SECRET}
EOF
  chmod 600 "$SM_ENV_FILE"
  chown "${SERVICE_USER}:${SERVICE_USER}" "$SM_ENV_FILE" 2>/dev/null || true

  cat > /etc/systemd/system/xnet-session-manager.service <<EOF
[Unit]
Description=X-NET Central Session Manager
After=network.target
Before=xnet.service

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
EnvironmentFile=${SM_ENV_FILE}
ExecStart=${SM_BIN}
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now xnet-session-manager >/dev/null 2>&1 || true
  sleep 1
  if systemctl is-active --quiet xnet-session-manager; then
    ok "Session Manager running on ${SM_HTTP_ADDR} (localhost-only)."
  else
    warn "Session Manager service did not start; the panel page will show 'unreachable'."
    journalctl -u xnet-session-manager -n 15 --no-pager 2>/dev/null || true
  fi
}

# ----- systemd service --------------------------------------------------------
install_service() {
  info "Installing systemd service…"
  cat > /etc/systemd/system/xnet.service <<EOF
[Unit]
Description=X-Net Panel Backend
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/xnet-server
# Restart=always so the panel comes back after a restore-triggered self-exit
# (the restore flow re-execs the process to load the new database). The restore
# code also schedules an explicit systemd-run restart as the primary path, so
# this is defence in depth and independent of the exit code.
Restart=always
RestartSec=3
# NoNewPrivileges must be false so sudo can escalate for useradd/systemctl.
NoNewPrivileges=false
# Do NOT use ProtectSystem — it makes /etc read-only breaking useradd.
# Do NOT use AmbientCapabilities — it conflicts with sudo (audit message error).
# Port binding is handled by setcap on the binary itself.

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xnet >/dev/null 2>&1 || true
  # Use restart (NOT just `enable --now`): on an upgrade the panel is often
  # already running, and `enable --now` would leave it on its OLD environment —
  # so freshly-wired values like SESSION_MANAGER_* in .env would never load and
  # the Session Manager page would keep showing "not configured". A restart
  # guarantees the panel re-reads the updated .env every time.
  systemctl restart xnet
  sleep 2

  if systemctl is-active --quiet xnet; then
    ok "xnet service is running."
  else
    journalctl -u xnet -n 20 --no-pager
    die "xnet service failed to start. Check logs above."
  fi
}

# ----- firewall ---------------------------------------------------------------
open_firewall() {
  local port="$1"
  [ -n "$port" ] || return 0
  info "Opening port ${port} in the firewall…"
  local handled="false"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ok "ufw: port ${port} opened."
    handled="true"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld: port ${port} opened."
    handled="true"
  fi
  # Best-effort iptables ACCEPT as a fallback (covers hosts using raw iptables).
  # Insert only if an identical rule is not already present. Non-persistent on
  # its own, but makes the port reachable immediately for this boot/session.
  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; then
      iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
    fi
    handled="true"
  fi
  if [ "$handled" != "true" ]; then
    warn "No firewall tool detected — ensure port ${port}/tcp is reachable (incl. any cloud/provider firewall)."
  else
    warn "If a cloud/provider firewall (Security Group) is in front of this server, also allow ${port}/tcp there."
  fi
}

# ----- summary ----------------------------------------------------------------
print_summary() {
  detect_ip
  echo
  echo -e "${C_GRN}${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GRN}${C_BOLD}║        X-Net Panel — Installation Complete              ║${C_RESET}"
  echo -e "${C_GRN}${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo -e "  ${C_BOLD}🌐 Login URL :${C_RESET} http://${ACCESS_IP}:${PANEL_PORT}/${WEB_BASE_PATH}"
  echo -e "  ${C_BOLD}🔗 Sub Port  :${C_RESET} ${SUB_PORT}  (public subscription links; change in Settings)"
  echo -e "  ${C_BOLD}👤 Username  :${C_RESET} ${ADMIN_USERNAME}"
  echo -e "  ${C_BOLD}🔑 Password  :${C_RESET} ${ADMIN_PASSWORD}"
  if [ -n "${WEB_BASE_PATH}" ]; then
    echo
    echo -e "  ${C_YLW}🔒 Secret login path is required — the bare URL redirects here.${C_RESET}"
    echo -e "     Manage it later in: Advanced Settings → Core Settings (panel port & login path)."
  fi
  if [ "$PASSWORD_GENERATED" = "true" ]; then
    echo
    echo -e "  ${C_YLW}⚠  Password was auto-generated — save it now!${C_RESET}"
  fi
  if [ "$NODE_ROLE" = "agent" ]; then
    echo
    echo -e "  ${C_BOLD}━━━ Agent node credentials (register this node in the panel) ━━━${C_RESET}"
    echo -e "  ${C_BOLD}NODE_API_KEY (token) :${C_RESET} ${NODE_API_KEY}"
    echo -e "  ${C_BOLD}NODE_SECRET_KEY      :${C_RESET} ${NODE_SECRET_KEY}"
    echo
    echo -e "  ${C_YLW}On the PANEL, open Nodes & Servers → Register Node and enter:${C_RESET}"
    echo -e "    • IP/Domain  = this server's address"
    echo -e "    • API Port   = ${PANEL_PORT}"
    echo -e "    • API Token  = the NODE_API_KEY above"
    echo -e "    • Secret Key = the NODE_SECRET_KEY above"
    echo -e "  ${C_YLW}The panel must use NODE_CLIENT_SCHEME=http to reach this agent (default).${C_RESET}"
  fi
  echo
  echo -e "  ${C_YLW}Security:${C_RESET} This URL uses plain HTTP. For production,"
  echo -e "  put it behind a domain + HTTPS (Caddy/Nginx reverse proxy)."
  echo
  echo -e "  ${C_BOLD}Useful commands:${C_RESET}"
  echo -e "    journalctl -u xnet -f      # live logs"
  echo -e "    systemctl restart xnet     # restart panel"
  echo -e "    systemctl status xnet      # check status"
  echo
}

print_upgrade_summary() {
  detect_ip
  local port web_path login_url
  port="$(grep '^PORT=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2)"
  port="${port:-8080}"
  web_path="$(grep '^WEB_BASE_PATH=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2)"
  if [ -n "$web_path" ]; then
    login_url="http://${ACCESS_IP}:${port}/${web_path}"
  else
    login_url="http://${ACCESS_IP}:${port}"
  fi
  echo
  echo -e "${C_GRN}${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_RESET}"
  echo -e "${C_GRN}${C_BOLD}║         X-Net Panel — Upgrade Complete                  ║${C_RESET}"
  echo -e "${C_GRN}${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo -e "  ${C_BOLD}🌐 Panel URL :${C_RESET} ${login_url}"
  echo -e "  ${C_BOLD}📁 Config    :${C_RESET} ${INSTALL_DIR}/.env (preserved)"
  echo -e "  ${C_BOLD}💾 Database  :${C_RESET} ${INSTALL_DIR}/data/xnet.db (preserved)"
  echo
  echo -e "  Your existing credentials and settings are unchanged."
  echo
  echo -e "  ${C_BOLD}Useful commands:${C_RESET}"
  echo -e "    journalctl -u xnet -f      # live logs"
  echo -e "    systemctl restart xnet     # restart panel"
  echo
}

# ----- main -------------------------------------------------------------------
main() {
  echo
  echo -e "${C_BLU}${C_BOLD}  ╔═══════════════════════════════════════╗${C_RESET}"
  echo -e "${C_BLU}${C_BOLD}  ║       X-Net Panel Installer           ║${C_RESET}"
  echo -e "${C_BLU}${C_BOLD}  ╚═══════════════════════════════════════╝${C_RESET}"
  echo

  install_deps
  persist_tcp_early_demux
  configure_logrotate
  install_singbox
  install_ssh_subsystems

  if [ "$IS_UPGRADE" = "true" ]; then
    # --- Upgrade: preserve .env + database ---
    info "Existing installation detected at ${INSTALL_DIR}."
    info "Upgrading binary, frontend, and helper scripts…"
    echo
    # Upgrade never changes the operator's existing timezone unless they pass
    # XNET_TIMEZONE explicitly (configure_timezone is a no-op otherwise).
    configure_timezone
    deploy_files
    configure_sudoers
    sm_prepare_secrets
    sm_ensure_panel_env
    ensure_session_admission_env
    install_session_manager
    install_service
    # Ensure the API port is open on upgrade too (older installs / agent nodes
    # may never have had it opened, which shows up as "connection timed out"
    # when the panel probes the node). Read the port from the preserved .env.
    upg_port="$(grep '^PORT=' "${INSTALL_DIR}/.env" 2>/dev/null | cut -d= -f2)"
    open_firewall "${upg_port:-8080}"
    print_upgrade_summary
  else
    # --- Fresh install: prompt for credentials ---
    info "Fresh installation — setting up X-Net Panel."
    prompt_credentials
    prompt_port
    prompt_role
    prompt_timezone
    echo
    configure_timezone
    deploy_files
    configure_sudoers
    sm_prepare_secrets
    create_env
    sm_ensure_panel_env
    ensure_session_admission_env
    install_session_manager
    install_service
    open_firewall "$PANEL_PORT"
    # The public subscription listener binds its own port; without this rule the
    # links resolve but never connect.
    open_firewall "$SUB_PORT"
    print_summary
  fi
}

main "$@"
