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
# for the core vars; these are appended as validated systemd EnvironmentFile
# lines, not run through envsubst, so token values containing '$' are never
# (mis)expanded):
#   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOWED_USERS, TELEGRAM_GROUP_ALLOWED_USERS,
#   TELEGRAM_GROUP_ALLOWED_CHATS, TELEGRAM_HOME_CHANNEL, TELEGRAM_REACTIONS
#   HERMES_EXTRA_ENV      - extra single-line `KEY=VALUE` lines (non-secret)
#   HERMES_EXTRA_SECRETS  - extra single-line `KEY=VALUE` lines (secret)
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

validate_env_name() {
  local name="$1"
  if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "[render-env] ERROR: invalid environment variable name '${name}'." >&2
    exit 1
  fi
}

write_env_line() {
  local name="$1"
  local value="${2-}"
  validate_env_name "${name}"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "[render-env] ERROR: ${name} must be a single-line EnvironmentFile value." >&2
    exit 1
  fi
  printf '%s=%s\n' "${name}" "${value}" >>"${ENV_FILE}"
}

write_env_if_set() {
  local name="$1"
  local value="${2-}"
  if [ -n "${value}" ]; then
    write_env_line "${name}" "${value}"
  fi
}

append_extra_env_block() {
  local label="$1"
  local block="${2-}"
  local line name value
  [ -n "${block}" ] || return 0

  printf '\n# %s\n' "${label}" >>"${ENV_FILE}"
  while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
      ''|'#'*)
        printf '%s\n' "${line}" >>"${ENV_FILE}"
        ;;
      *=*)
        name="${line%%=*}"
        value="${line#*=}"
        write_env_line "${name}" "${value}"
        ;;
      *)
        echo "[render-env] ERROR: ${label} contains a non KEY=VALUE line." >&2
        exit 1
        ;;
    esac
  done <<<"${block}"
}

if [ -n "${TELEGRAM_BOT_TOKEN}" ] && \
   [ -z "${TELEGRAM_ALLOWED_USERS}" ] && \
   [ -z "${TELEGRAM_GROUP_ALLOWED_USERS}" ] && \
   [ -z "${TELEGRAM_GROUP_ALLOWED_CHATS}" ]; then
  echo "[render-env] ERROR: TELEGRAM_BOT_TOKEN is set but no Telegram allowlist is configured." >&2
  echo "[render-env] Set TELEGRAM_ALLOWED_USERS to your numeric Telegram user ID, not your @username." >&2
  echo "[render-env] For groups, set TELEGRAM_GROUP_ALLOWED_USERS or TELEGRAM_GROUP_ALLOWED_CHATS." >&2
  exit 1
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

# Optional integrations. Telegram auto-activates in Hermes purely from the
# presence of these env vars — no config.yaml change is needed.
if [ -n "${TELEGRAM_BOT_TOKEN}" ]; then
  printf '\n# Telegram gateway (auto-activates from TELEGRAM_BOT_TOKEN alone).\n' >>"${ENV_FILE}"
  write_env_line TELEGRAM_BOT_TOKEN "${TELEGRAM_BOT_TOKEN}"
fi
write_env_if_set TELEGRAM_ALLOWED_USERS "${TELEGRAM_ALLOWED_USERS}"
write_env_if_set TELEGRAM_GROUP_ALLOWED_USERS "${TELEGRAM_GROUP_ALLOWED_USERS}"
write_env_if_set TELEGRAM_GROUP_ALLOWED_CHATS "${TELEGRAM_GROUP_ALLOWED_CHATS}"
write_env_if_set TELEGRAM_HOME_CHANNEL "${TELEGRAM_HOME_CHANNEL}"
write_env_if_set TELEGRAM_REACTIONS "${TELEGRAM_REACTIONS}"
append_extra_env_block "HERMES_EXTRA_ENV (repo variable): extra runtime config." "${HERMES_EXTRA_ENV}"
append_extra_env_block "HERMES_EXTRA_SECRETS (GitHub secret): extra runtime secrets." "${HERMES_EXTRA_SECRETS}"
chmod 0600 "${ENV_FILE}"

# shellcheck disable=SC2016
envsubst '${HERMES_USER} ${HERMES_HOME} ${HERMES_CONFIG_DIR} ${WORKSPACE_DIR}' \
  <"${SCRIPT_DIR}/hermes.service.tmpl" >"${UNIT_FILE}"
chmod 0644 "${UNIT_FILE}"

echo "ENV_FILE=${ENV_FILE}"
echo "UNIT_FILE=${UNIT_FILE}"
