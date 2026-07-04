#!/usr/bin/env bash
# ===========================================================================
# sync-commit.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Commits the pulled .hermes/ + workspace/ snapshot. Skips entirely when there
# are no changes. Pushes to the target branch (default: main) using the
# built-in GITHUB_TOKEN; if the direct push is rejected (e.g. branch
# protection), it falls back to a dedicated sync branch and opens/updates a PR.
#
# No GitHub PAT or deploy key is used. Author is hermes-agent[bot].
#
# Required env: GITHUB_TOKEN (for the PR fallback via gh)
# Optional env: TARGET_BRANCH (default main), DRY_RUN (0/1),
#               SYNC_BRANCH (default hermes-sync)
# ===========================================================================
set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-main}"
SYNC_BRANCH="${SYNC_BRANCH:-hermes-sync}"
DRY_RUN="${DRY_RUN:-0}"
COMMIT_MSG="chore(sync): update Hermes workspace snapshot"

log() { printf '[sync-commit] %s\n' "$*"; }

git config user.name  "hermes-agent[bot]"
git config user.email "hermes-agent[bot]@users.noreply.github.com"

git add -A .hermes workspace 2>/dev/null || git add -A

if git diff --cached --quiet; then
  log "No changes to commit — skipping."
  exit 0
fi

log "Changes detected:"
git --no-pager diff --cached --stat || true

if [ "${DRY_RUN}" = "1" ]; then
  log "DRY_RUN=1 — not committing or pushing."
  git reset -q HEAD -- . || true
  exit 0
fi

git commit -m "${COMMIT_MSG}"

# --- Try a direct push to the target branch --------------------------------
if git push origin "HEAD:${TARGET_BRANCH}"; then
  log "Pushed snapshot directly to ${TARGET_BRANCH}."
  exit 0
fi

# --- Fallback: push to a sync branch and open/update a PR -------------------
log "Direct push to ${TARGET_BRANCH} rejected (branch protection?). Falling back to PR."
git push -f origin "HEAD:${SYNC_BRANCH}"

if command -v gh >/dev/null 2>&1; then
  if gh pr view "${SYNC_BRANCH}" >/dev/null 2>&1; then
    log "Existing PR from ${SYNC_BRANCH} updated by the push."
  else
    gh pr create \
      --base "${TARGET_BRANCH}" \
      --head "${SYNC_BRANCH}" \
      --title "${COMMIT_MSG}" \
      --body "Automated Hermes workspace snapshot. Direct push to \`${TARGET_BRANCH}\` was blocked by branch protection." \
      || log "Could not create PR automatically; branch ${SYNC_BRANCH} is updated — open a PR manually."
  fi
else
  log "gh CLI unavailable; snapshot pushed to ${SYNC_BRANCH} — open a PR manually."
fi
