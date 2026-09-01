#!/usr/bin/env bash
# xnet-update — move the panel to a published release, from inside the panel.
#
# Invoked by the panel as:
#     sudo -n systemd-run --unit=xnet-panel-update --collect \
#          /bin/bash /opt/xnet/xnet-update <tag> <state-file>
#
# It runs DETACHED on purpose. install.sh stops and restarts the xnet service
# partway through, so anything running as a child of the panel process would be
# killed while the new binary was being written — leaving a half-installed
# panel and no way to report why.
#
# Because the requesting HTTP connection cannot survive that restart either,
# progress is written to a state file the panel reads back once it is up again.
# Every phase change is recorded before the work starts, so a crash leaves the
# last thing attempted on record rather than a silent stop.
#
# It deliberately does NOT reimplement installation. It fetches the release
# bundle and hands off to the install.sh inside it, which is the same script an
# operator runs by hand and the only thing that knows how to upgrade in place
# while preserving .env and the database.

set -uo pipefail

TAG="${1:-}"
STATE="${2:-/opt/xnet/data/update-state.json}"
REPO="xpanel-cp/x-net"
API="https://api.github.com/repos/${REPO}/releases"
WORK_DIR="$(mktemp -d /tmp/xnet-update-XXXXXX)"
LOG="/var/log/xnet-update.log"

exec >>"$LOG" 2>&1
echo "=== $(date -Is) xnet-update -> ${TAG} ==="

FROM_VERSION=""
BACKUP_ID=""
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Carry forward the fields the panel already wrote, so the report keeps naming
# the version we came from and the backup that can undo this.
if [ -f "$STATE" ]; then
  FROM_VERSION="$(grep -oE '"fromVersion"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" | sed -E 's/.*"([^"]*)"$/\1/' | head -n1)"
  BACKUP_ID="$(grep -oE '"backupId"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" | sed -E 's/.*"([^"]*)"$/\1/' | head -n1)"
  STARTED_AT="$(grep -oE '"startedAt"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATE" | sed -E 's/.*"([^"]*)"$/\1/' | head -n1)"
fi

# json_escape renders a value safe to embed in the state file. Messages carry
# command output, which routinely contains quotes and newlines.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ' | tr '\r' ' '
}

set_state() {
  local phase="$1" message="$2" ended=""
  case "$phase" in
    done|failed) ended="$(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
  esac
  local tmp="${STATE}.tmp"
  cat > "$tmp" <<EOF
{
  "phase": "$(json_escape "$phase")",
  "tag": "$(json_escape "$TAG")",
  "message": "$(json_escape "$message")",
  "startedAt": "$(json_escape "$STARTED_AT")",
  "endedAt": "$(json_escape "$ended")",
  "fromVersion": "$(json_escape "$FROM_VERSION")",
  "backupId": "$(json_escape "$BACKUP_ID")"
}
EOF
  # Rename so a reader never sees a half-written file.
  mv -f "$tmp" "$STATE"
  # The panel runs unprivileged and has to be able to read this back.
  chown xnet:xnet "$STATE" 2>/dev/null || true
  echo "[$phase] $message"
}

fail() {
  set_state failed "$1"
  rm -rf "$WORK_DIR"
  exit 1
}

trap 'rm -rf "$WORK_DIR"' EXIT

[ -n "$TAG" ] || fail "No release tag was given."
command -v curl >/dev/null 2>&1 || fail "curl is not installed."
command -v tar  >/dev/null 2>&1 || fail "tar is not installed."

# ----- resolve the bundle URL -------------------------------------------------
set_state downloading "Resolving the install bundle for ${TAG}…"

auth=()
[ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

rel_json="$(curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" \
            "${API}/tags/${TAG}" 2>/dev/null)" \
  || fail "Could not read release ${TAG} from GitHub."

# Prefer an asset whose name mentions xnet, else the first .tar.gz — the same
# preference install/xnet.sh applies.
url=""
if command -v jq >/dev/null 2>&1; then
  url="$(echo "$rel_json" | jq -r '
    .assets
    | (map(select(.name | test("xnet.*\\.tar\\.gz$"))) + map(select(.name | endswith(".tar.gz"))))
    | .[0].browser_download_url // empty')"
else
  url="$(echo "$rel_json" \
        | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.tar\.gz"' \
        | sed -E 's/.*"([^"]+)".*/\1/' | head -n1)"
fi
[ -n "$url" ] || fail "Release ${TAG} has no .tar.gz install bundle attached."

# ----- download ---------------------------------------------------------------
set_state downloading "Downloading ${url##*/}…"
curl -fSL "${auth[@]}" "$url" -o "${WORK_DIR}/bundle.tar.gz" \
  || fail "Download failed from ${url}"

size="$(stat -c %s "${WORK_DIR}/bundle.tar.gz" 2>/dev/null || echo 0)"
[ "$size" -gt 1000000 ] || fail "The downloaded bundle is only ${size} bytes — it is not a release archive."

# ----- extract ----------------------------------------------------------------
set_state extracting "Extracting the bundle (${size} bytes)…"
# Verify the archive before unpacking it, so a truncated download fails here
# rather than halfway through replacing the installation.
tar -tzf "${WORK_DIR}/bundle.tar.gz" >/dev/null 2>&1 \
  || fail "The downloaded archive is corrupt (tar could not read it)."
tar -xzf "${WORK_DIR}/bundle.tar.gz" -C "$WORK_DIR" || fail "Extraction failed."

installer="$(find "$WORK_DIR" -maxdepth 3 -name install.sh -type f 2>/dev/null | head -n1)"
[ -n "$installer" ] || fail "install.sh was not found inside the ${TAG} bundle."

# ----- install ----------------------------------------------------------------
# From here the panel is stopped and restarted by install.sh. Nothing after this
# point can report to the running panel; the state file is the only channel.
set_state installing "Running the ${TAG} installer. The panel restarts during this step."

cd "$(dirname "$installer")" || fail "Could not enter the bundle directory."
if bash "$installer"; then
  set_state done "Panel updated to ${TAG}. Reload the page."
  echo "=== $(date -Is) update to ${TAG} completed ==="
  exit 0
fi

# install.sh preserves .env and the database, so a failure here leaves the
# PREVIOUS installation in place far more often than not. Say that, and name the
# backup, rather than leaving the operator to guess how bad it is.
fail "The ${TAG} installer failed. The previous installation and database are preserved; see ${LOG}. Backup ${BACKUP_ID} can be restored if needed."
