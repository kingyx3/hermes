#!/usr/bin/env bash
# ===========================================================================
# sync-commit.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Commits the pulled .hermes/ + workspace/ snapshot. Skips entirely when there
# are no changes. Pushes the snapshot to a dedicated sync branch and opens or
# updates a PR into the target branch, so protected branches are never updated
# directly by the workflow.
#
# No GitHub PAT or deploy key is used. Author is hermes-agent[bot].
#
# Required env: GITHUB_TOKEN (used by gh to create/update the PR)
# Optional env: TARGET_BRANCH (default main), DRY_RUN (0/1),
#               SYNC_BRANCH (default hermes-sync),
#               MAX_GIT_BLOB_BYTES (default 50000000)
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
SYNC_BRANCH="${SYNC_BRANCH:-hermes-sync}"
DRY_RUN="${DRY_RUN:-0}"
MAX_GIT_BLOB_BYTES="${MAX_GIT_BLOB_BYTES:-50000000}"
COMMIT_MSG="chore(sync): update Hermes workspace snapshot"

log() { printf '[sync-commit] %s\n' "$*"; }

git config user.name  "hermes-agent[bot]"
git config user.email "hermes-agent[bot]@users.noreply.github.com"

git add -A .hermes workspace 2>/dev/null || git add -A

if [ -f "${SCRIPT_DIR}/sync-validate.sh" ]; then
  MAX_GIT_BLOB_BYTES="${MAX_GIT_BLOB_BYTES}" bash "${SCRIPT_DIR}/sync-validate.sh"
fi

if git diff --cached --quiet; then
  log "No changes to commit — skipping."
  exit 0
fi

log "Staged sync files:"
git --no-pager diff --cached --name-status | sed 's/^/[sync-commit]   /'

log "Staged sync diffstat:"
git --no-pager diff --cached --stat | sed 's/^/[sync-commit]   /' || true

if [ "${DRY_RUN}" = "1" ]; then
  log "DRY_RUN=1 — not committing, pushing, or opening a PR."
  git reset -q HEAD -- . || true
  exit 0
fi

git commit -m "${COMMIT_MSG}"

log "Pushing snapshot to ${SYNC_BRANCH} for PR into ${TARGET_BRANCH}."
git push -f origin "HEAD:${SYNC_BRANCH}"

if ! command -v gh >/dev/null 2>&1; then
  log "gh CLI unavailable; snapshot pushed to ${SYNC_BRANCH} — open a PR manually."
  exit 1
fi

export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
REPO="${GITHUB_REPOSITORY:-}"
GH_REPO_ARGS=()
if [ -n "${REPO}" ]; then
  GH_REPO_ARGS=(--repo "${REPO}")
fi

HEAD_FILTER="${SYNC_BRANCH}"
if [ -n "${REPO}" ]; then
  OWNER="${REPO%%/*}"
  HEAD_FILTER="${OWNER}:${SYNC_BRANCH}"
fi

PR_NUMBER="$(gh pr list "${GH_REPO_ARGS[@]}" \
  --state open \
  --base "${TARGET_BRANCH}" \
  --head "${HEAD_FILTER}" \
  --json number \
  --jq '.[0].number // empty' 2>/dev/null || true)"

if [ -n "${PR_NUMBER}" ]; then
  log "Existing sync PR #${PR_NUMBER} updated by the push."
  exit 0
fi

PR_BODY="$(cat <<EOF
Automated Hermes workspace snapshot.

This workflow opens a pull request instead of committing directly to \`${TARGET_BRANCH}\`, so protected branches stay protected.
EOF
)"

gh pr create "${GH_REPO_ARGS[@]}" \
  --base "${TARGET_BRANCH}" \
  --head "${SYNC_BRANCH}" \
  --title "${COMMIT_MSG}" \
  --body "${PR_BODY}"

log "Opened sync PR from ${SYNC_BRANCH} into ${TARGET_BRANCH}."
