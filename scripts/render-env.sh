#!/usr/bin/env bash
# ===========================================================================
# render-env.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Renders the VM-side /etc/hermes-agent/hermes.env and the systemd unit from
# their templates, substituting values from the environment. The rendered
# hermes.env contains the Gemini secret and is written mode 0600 to a runner
# temp path; it is copied to the VM over SSH and deleted from the runner by
# the caller. It is NEVER committed and NEVER printed.
#
# Required env:
#   GEMINI_API_KEY, HERMES_USER, HERMES_HOME, HERMES_CONFIG_DIR, WORKSPACE_DIR
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

# shellcheck disable=SC2016
envsubst '${HERMES_USER} ${HERMES_HOME} ${HERMES_CONFIG_DIR} ${WORKSPACE_DIR}' \
  <"${SCRIPT_DIR}/hermes.service.tmpl" >"${UNIT_FILE}"
chmod 0644 "${UNIT_FILE}"

echo "ENV_FILE=${ENV_FILE}"
echo "UNIT_FILE=${UNIT_FILE}"
