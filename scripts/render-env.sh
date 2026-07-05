#!/usr/bin/env bash
# ===========================================================================
# render-env.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Renders the VM-side /etc/hermes-agent/hermes.env and the systemd unit from
# their templates, substituting values from the environment. The rendered
# hermes.env contains secrets and is written mode 0600 to a runner temp path;
# it is copied to the VM over SSH and deleted from the runner by the caller.
# It is NEVER committed and NEVER printed.
#
# Required env:
#   GEMINI_API_KEY, HERMES_USER, HERMES_HOME, HERMES_CONFIG_DIR, WORKSPACE_DIR
# Optional env (all default to "" / disabled if unset — see hermes.env.tmpl
# for the core vars; these are appended verbatim, not run through envsubst,
# so token values containing '$' are never (mis)expanded):
#   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, TELEGRAM_GROUP_ALLOWED_USERS,
#   TELEGRAM_GROUP_ALLOWED_CHATS, TELEGRAM_HOME_CHANNEL, TELEGRAM_REACTIONS
#   HERMES_EXTRA_ENV      - arbitrary extra `KEY=VALUE` lines (non-secret)
#   HERMES_EXTRA_SECRETS  - arbitrary extra `KEY=VALUE` lines (secret)
# Optional env:
#   OUT_DIR (default: $RUNNER_TEMP/hermes-render)
# Outputs (paths printed as KEY=VALUE lines):
#   ENV_FILE=..., UNIT_FILE=...
# ===========================================================================
set -euo pipefail

: "${GEMINI_API_KEY:?GEMINI_API_KEY required}"
: "${HERMES_USER:?HERMES_USER required}"
: "${HERMES_HOME:?HERMES_HOME required}"
: "${HERMES_CONFIG_DIR:?HERMES_CONFIG_DIR required}"
: "${WORKSPACE_DIR:?WORKSPACE_DIR required}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_USERS="${TELEGRAM_GROUP_ALLOWED_USERS:-}"
TELEGRAM_GROUP_ALLOWED_CHATS="${TELEGRAM_GROUP_ALLOWED_CHATS:-}"
TELEGRAM_HOME_CHANNEL="${TELEGRAM_HOME_CHANNEL:-}"
TELEGRAM_REACTIONS="${TELEGRAM_REACTIONS:-}"
HERMES_EXTRA_ENV="${HERMES_EXTRA_ENV:-}"
HERMES_EXTRA_SECRETS="${HERMES_EXTRA_SECRETS:-}"

if [ -n "${TELEGRAM_BOT_TOKEN}" ] && [ -z "${TELEGRAM_ALLOWED_USERS}" ]; then
  echo "[render-env] WARNING: TELEGRAM_BOT_TOKEN is set but TELEGRAM_ALLOWED_USERS is empty." >&2
  echo "[render-env] Unknown users are gated by 'unauthorized_dm_behavior' (default: pairing" >&2
  echo "[render-env] flow), not fully blocked. Set the TELEGRAM_ALLOWED_USERS repo variable" >&2
  echo "[render-env] to your numeric Telegram user ID (via @userinfobot) to lock this down." >&2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-${RUNNER_TEMP:-/tmp}/hermes-render}"
mkdir -p "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

ENV_FILE="${OUT_DIR}/hermes.env"
UNIT_FILE="${OUT_DIR}/hermes.service"

# Only these vars are substituted, so no unrelated $VAR in templates expands.
export GEMINI_API_KEY HERMES_USER HERMES_HOME HERMES_CONFIG_DIR WORKSPACE_DIR

umask 077
# The single-quoted arg is the literal allow-list envsubst substitutes; it must
# NOT be expanded by the shell — SC2016 is expected here.
# shellcheck disable=SC2016
envsubst '${GEMINI_API_KEY} ${HERMES_CONFIG_DIR} ${WORKSPACE_DIR}' \
  <"${SCRIPT_DIR}/hermes.env.tmpl" >"${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

# Optional integrations, appended verbatim (NOT envsubst'd) so token values
# are never (mis)expanded. Telegram auto-activates in Hermes purely from the
# presence of these env vars — no config.yaml change is needed.
{
  if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
    echo ""
    echo "# Telegram gateway (auto-activates from TELEGRAM_BOT_TOKEN alone)."
    printf 'TELEGRAM_BOT_TOKEN=%s\n' "${TELEGRAM_BOT_TOKEN}"
  fi
  if [ -n "${TELEGRAM_ALLOWED_USERS}" ]; then
    printf 'TELEGRAM_ALLOWED_USERS=%s\n' "${TELEGRAM_ALLOWED_USERS}"
  fi
  if [ -n "${TELEGRAM_GROUP_ALLOWED_USERS}" ]; then
    printf 'TELEGRAM_GROUP_ALLOWED_USERS=%s\n' "${TELEGRAM_GROUP_ALLOWED_USERS}"
  fi
  if [ -n "${TELEGRAM_GROUP_ALLOWED_CHATS}" ]; then
    printf 'TELEGRAM_GROUP_ALLOWED_CHATS=%s\n' "${TELEGRAM_GROUP_ALLOWED_CHATS}"
  fi
  if [ -n "${TELEGRAM_HOME_CHANNEL}" ]; then
    printf 'TELEGRAM_HOME_CHANNEL=%s\n' "${TELEGRAM_HOME_CHANNEL}"
  fi
  if [ -n "${TELEGRAM_REACTIONS}" ]; then
    printf 'TELEGRAM_REACTIONS=%s\n' "${TELEGRAM_REACTIONS}"
  fi
  if [ -n "${HERMES_EXTRA_ENV}" ]; then
    echo ""
    echo "# HERMES_EXTRA_ENV (repo variable): arbitrary extra runtime config."
    printf '%s\n' "${HERMES_EXTRA_ENV}"
  fi
  if [ -n "${HERMES_EXTRA_SECRETS}" ]; then
    echo ""
    echo "# HERMES_EXTRA_SECRETS (GitHub secret): arbitrary extra runtime secrets."
    printf '%s\n' "${HERMES_EXTRA_SECRETS}"
  fi
} >>"${ENV_FILE}"
chmod 0600 "${ENV_FILE}"

# shellcheck disable=SC2016
envsubst '${HERMES_USER} ${HERMES_HOME} ${HERMES_CONFIG_DIR} ${WORKSPACE_DIR}' \
  <"${SCRIPT_DIR}/hermes.service.tmpl" >"${UNIT_FILE}"
chmod 0644 "${UNIT_FILE}"

echo "ENV_FILE=${ENV_FILE}"
echo "UNIT_FILE=${UNIT_FILE}"
