#!/usr/bin/env bash
# ============================================================
#  X-NET Panel — Online Installer / Version Picker
#
#  Downloads a published GitHub release and runs its bundled
#  installer. By default it shows the LAST 3 releases and lets
#  you choose which one to install.
#
#  Usage (run as root):
#     bash <(curl -fsSL https://raw.githubusercontent.com/xpanel-cp/x-net/main/install/xnet.sh)
#
#  Non-interactive (install a specific tag):
#     bash <(curl -fsSL .../install/xnet.sh) v1.2.3
# ============================================================

set -Eeuo pipefail

# ----- config ----------------------------------------------------------------
REPO="xpanel-cp/x-net"
API="https://api.github.com/repos/${REPO}/releases"
# How many recent releases to list in the picker.
SHOW_LAST=3
# Where the release bundle is unpacked before install.
WORK_DIR="$(mktemp -d /tmp/xnet-install.XXXXXX 2>/dev/null || echo /tmp/xnet-install)"

# ----- pretty output ---------------------------------------------------------
C_RESET='\033[0m'; C_RED='\033[0;31m'; C_GRN='\033[0;32m'
C_YLW='\033[0;33m'; C_BLU='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "${C_BLU}[i]${C_RESET} $*"; }
ok()   { echo -e "${C_GRN}[✓]${C_RESET} $*"; }
warn() { echo -e "${C_YLW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

cleanup() { [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR" 2>/dev/null || true; }
trap cleanup EXIT
trap 'err "Installer aborted on line $LINENO."' ERR

# ----- preflight -------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Please run as root:  sudo bash xnet.sh"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Ensure curl + tar are available (and jq for clean JSON parsing).
ensure_deps() {
  local missing=()
  need_cmd curl || missing+=(curl)
  need_cmd tar  || missing+=(tar)
  need_cmd jq   || missing+=(jq)
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Installing prerequisites: ${missing[*]}"
    if need_cmd apt-get; then
      apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
    elif need_cmd dnf; then
      dnf install -y "${missing[@]}" >/dev/null 2>&1 || true
    elif need_cmd yum; then
      yum install -y "${missing[@]}" >/dev/null 2>&1 || true
    fi
  fi
  need_cmd curl || die "curl is required but could not be installed."
  need_cmd tar  || die "tar is required but could not be installed."
}

# GitHub API helper. Uses GITHUB_TOKEN when present to avoid rate limits.
gh_api() {
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" \
         -H "Accept: application/vnd.github+json" "$url"
  else
    curl -fsSL -H "Accept: application/vnd.github+json" "$url"
  fi
}

# ----- release discovery -----------------------------------------------------
RELEASES_JSON=""
TAGS=()
NAMES=()

load_releases() {
  info "Fetching releases from github.com/${REPO} …"
  RELEASES_JSON="$(gh_api "${API}?per_page=20" || true)"
  [ -n "$RELEASES_JSON" ] || die "Could not reach the GitHub API. Check connectivity or set GITHUB_TOKEN."

  if need_cmd jq; then
    # Skip drafts; keep the most recent SHOW_LAST entries (incl. pre-releases).
    while IFS=$'\t' read -r tag name; do
      [ -n "$tag" ] || continue
      TAGS+=("$tag")
      NAMES+=("${name:-$tag}")
    done < <(echo "$RELEASES_JSON" \
              | jq -r '[.[] | select(.draft == false)]
                       | sort_by(.published_at) | reverse
                       | .['"0:${SHOW_LAST}"'][]
                       | "\(.tag_name)\t\(.name)"')
  else
    # Fallback: grep tag_name (best effort, no draft filtering).
    while read -r tag; do
      [ -n "$tag" ] || continue
      TAGS+=("$tag")
      NAMES+=("$tag")
    done < <(echo "$RELEASES_JSON" | grep -oE '"tag_name"[ ]*:[ ]*"[^"]+"' \
              | sed -E 's/.*"tag_name"[ ]*:[ ]*"([^"]+)".*/\1/' | head -n "$SHOW_LAST")
  fi

  [ "${#TAGS[@]}" -gt 0 ] || die "No published releases found for ${REPO}."
}

# ----- selection -------------------------------------------------------------
SELECTED_TAG=""

choose_release() {
  # Tag passed as the first CLI argument? Use it directly.
  if [ -n "${1:-}" ]; then
    SELECTED_TAG="$1"
    info "Using requested release: ${SELECTED_TAG}"
    return
  fi

  echo
  echo -e "${C_BOLD}Available X-NET releases (latest ${#TAGS[@]}):${C_RESET}"
  local i
  for i in "${!TAGS[@]}"; do
    local marker=""
    [ "$i" -eq 0 ] && marker=" ${C_GRN}(latest)${C_RESET}"
    printf "  ${C_BOLD}%d)${C_RESET} %s  —  %b\n" "$((i + 1))" "${TAGS[$i]}" "${NAMES[$i]}${marker}"
  done
  echo

  local choice
  while :; do
    read -rp "$(echo -e "Choose a version to install [${C_BOLD}1-${#TAGS[@]}${C_RESET}, default 1]: ")" choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#TAGS[@]}" ]; then
      SELECTED_TAG="${TAGS[$((choice - 1))]}"
      break
    fi
    warn "Invalid choice. Enter a number between 1 and ${#TAGS[@]}."
  done
  ok "Selected ${SELECTED_TAG}."
}

# ----- download + run --------------------------------------------------------
resolve_asset_url() {
  local tag="$1"
  local rel_json
  rel_json="$(gh_api "${API}/tags/${tag}" || true)"
  [ -n "$rel_json" ] || die "Release ${tag} not found."

  if need_cmd jq; then
    # Prefer the bundled install tarball (xnet-panel-*.tar.gz); fall back to
    # any .tar.gz asset attached to the release.
    echo "$rel_json" | jq -r '
      .assets
      | (map(select(.name | test("xnet.*\\.tar\\.gz$"))) + map(select(.name | endswith(".tar.gz"))))
      | .[0].browser_download_url // empty'
  else
    echo "$rel_json" | grep -oE '"browser_download_url"[ ]*:[ ]*"[^"]+\.tar\.gz"' \
      | sed -E 's/.*"browser_download_url"[ ]*:[ ]*"([^"]+)".*/\1/' | head -n1
  fi
}

install_release() {
  local tag="$1"
  local url
  url="$(resolve_asset_url "$tag")"
  [ -n "$url" ] || die "Release ${tag} has no .tar.gz install bundle attached.
See RELEASING.md for how to attach the install package to a release."

  mkdir -p "$WORK_DIR"
  info "Downloading ${url##*/} …"
  curl -fSL "$url" -o "${WORK_DIR}/bundle.tar.gz" || die "Download failed."

  info "Extracting bundle …"
  tar -xzf "${WORK_DIR}/bundle.tar.gz" -C "$WORK_DIR" || die "Extraction failed."

  # Locate install.sh inside the extracted tree (it may sit in a subfolder).
  local installer
  installer="$(find "$WORK_DIR" -maxdepth 3 -name install.sh -type f 2>/dev/null | head -n1)"
  [ -n "$installer" ] || die "install.sh not found inside the release bundle."

  local bundle_dir
  bundle_dir="$(dirname "$installer")"
  ok "Release ${tag} ready. Launching installer…"
  echo "------------------------------------------------------------"
  cd "$bundle_dir"
  bash "$installer"
}

# ----- main ------------------------------------------------------------------
main() {
  echo -e "${C_BOLD}X-NET Panel — Online Installer${C_RESET}"
  ensure_deps
  load_releases
  choose_release "${1:-}"
  install_release "$SELECTED_TAG"
}

main "$@"
