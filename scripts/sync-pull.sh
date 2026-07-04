#!/usr/bin/env bash
# ===========================================================================
# sync-pull.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Pulls the VM's Hermes config/state (.hermes) and workspace into the checked-
# out repo, applying scripts/sync-excludes.txt so secrets/caches/logs/models
# never land in git. Requires an already-established ephemeral SSH tunnel
# (see ssh-iap.sh); reads SSH_USER, SSH_PORT, SSH_KEY, SSH_OPTS from the env.
#
# Required env: SSH_USER, SSH_PORT, SSH_KEY, SSH_OPTS
# Optional env: HERMES_CONFIG_DIR (default /home/hermes/.hermes),
#               WORKSPACE_DIR (default /home/hermes/workspace),
#               REPO_DIR (default: current dir)
# ===========================================================================
set -euo pipefail

: "${SSH_USER:?}" "${SSH_PORT:?}" "${SSH_KEY:?}" "${SSH_OPTS:?}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-/home/hermes/.hermes}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/home/hermes/workspace}"
REPO_DIR="${REPO_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXCLUDES="${SCRIPT_DIR}/sync-excludes.txt"

log() { printf '[sync-pull] %s\n' "$*"; }

# shellcheck disable=SC2086
RSH="ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_OPTS}"

pull() {
  local remote_src="$1" dest="$2"
  mkdir -p "${dest}"
  log "Pulling ${remote_src} -> ${dest}"
  # --delete keeps the snapshot faithful; excludes are applied to both sides.
  rsync -az --delete \
    --exclude-from="${EXCLUDES}" \
    --rsync-path="sudo -u $(printf %q "${HERMES_OWNER:-hermes}") rsync" \
    -e "${RSH}" \
    "${SSH_USER}@localhost:${remote_src}/" "${dest}/" \
  || rsync -az --delete \
    --exclude-from="${EXCLUDES}" \
    -e "${RSH}" \
    "${SSH_USER}@localhost:${remote_src}/" "${dest}/"
}

pull "${HERMES_CONFIG_DIR}" "${REPO_DIR}/.hermes"
pull "${WORKSPACE_DIR}" "${REPO_DIR}/workspace"

# Normalize permissions so committed files are not executable/odd-moded.
find "${REPO_DIR}/.hermes" "${REPO_DIR}/workspace" -type f -exec chmod 0644 {} + 2>/dev/null || true
find "${REPO_DIR}/.hermes" "${REPO_DIR}/workspace" -type d -exec chmod 0755 {} + 2>/dev/null || true

log "Pull complete."
