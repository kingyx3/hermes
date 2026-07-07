#!/usr/bin/env bash
# ===========================================================================
# sync-pull.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Pulls durable user/agent-authored Hermes state and workspace files from the VM
# into the checked-out repo. This is intentionally allowlist-first: the sync is
# for memory, skills, and user workspace artifacts, not the installed Hermes
# agent runtime, package managers, browsers, caches, logs, or generated system
# files.
#
# Requires an already-established ephemeral SSH tunnel (see ssh-iap.sh); reads
# SSH_USER, SSH_PORT, SSH_KEY, SSH_OPTS from the env.
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
HERMES_ALLOWLIST="${SCRIPT_DIR}/sync-hermes-allowlist.txt"
WORKSPACE_ALLOWLIST="${SCRIPT_DIR}/sync-workspace-allowlist.txt"

log() { printf '[sync-pull] %s\n' "$*"; }

for policy_file in "${EXCLUDES}" "${HERMES_ALLOWLIST}" "${WORKSPACE_ALLOWLIST}"; do
  if [ ! -s "${policy_file}" ]; then
    log "Missing or empty sync policy file: ${policy_file}"
    exit 1
  fi
done

# shellcheck disable=SC2086
RSH="ssh -i ${SSH_KEY} -p ${SSH_PORT} ${SSH_OPTS}"

run_rsync() {
  local remote_src="$1" dest="$2" filter_file="$3" label="$4" use_sudo="$5" change_log="$6"
  local -a cmd=(
    rsync
    -az
    --delete
    --delete-excluded
    --prune-empty-dirs
    --itemize-changes
    --human-readable
    --exclude-from="${EXCLUDES}"
    --filter="merge ${filter_file}"
    -e "${RSH}"
  )

  if [ "${use_sudo}" = "1" ]; then
    cmd+=(--rsync-path="sudo -u $(printf %q "${HERMES_OWNER:-hermes}") rsync")
  fi

  cmd+=("${SSH_USER}@localhost:${remote_src}/" "${dest}/")

  log "Pulling ${label}: ${remote_src} -> ${dest}"
  "${cmd[@]}" | tee "${change_log}"
}

summarize_changes() {
  local label="$1" change_log="$2"
  if [ -s "${change_log}" ]; then
    log "${label} rsync changes:"
    sed 's/^/[sync-pull]   /' "${change_log}"
  else
    log "${label}: no allowlisted changes transferred."
  fi
}

pull() {
  local remote_src="$1" dest="$2" filter_file="$3" label="$4"
  mkdir -p "${dest}"

  local change_log
  change_log="$(mktemp)"

  if ! run_rsync "${remote_src}" "${dest}" "${filter_file}" "${label}" 1 "${change_log}"; then
    log "sudo rsync failed for ${label}; retrying without sudo."
    : > "${change_log}"
    run_rsync "${remote_src}" "${dest}" "${filter_file}" "${label}" 0 "${change_log}"
  fi

  summarize_changes "${label}" "${change_log}"
  rm -f "${change_log}"
}

pull "${HERMES_CONFIG_DIR}" "${REPO_DIR}/.hermes" "${HERMES_ALLOWLIST}" "Hermes durable state"
pull "${WORKSPACE_DIR}" "${REPO_DIR}/workspace" "${WORKSPACE_ALLOWLIST}" "Workspace user files"

# Normalize permissions so committed files are not executable/odd-moded. The
# commit step has an additional binary/runtime guard before staging is pushed.
find "${REPO_DIR}/.hermes" "${REPO_DIR}/workspace" -type f -exec chmod 0644 {} + 2>/dev/null || true
find "${REPO_DIR}/.hermes" "${REPO_DIR}/workspace" -type d -exec chmod 0755 {} + 2>/dev/null || true

log "Pull complete."
