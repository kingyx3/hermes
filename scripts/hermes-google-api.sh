#!/usr/bin/env bash
# Run Hermes' bundled Google Workspace API CLI with Hermes' own Python venv.
# This avoids relying on login-shell PATH resolution for `python`.
set -euo pipefail

USER_HOME="${HERMES_USER_HOME:-${HOME:-/home/hermes}}"
if [ -n "${HERMES_CONFIG_DIR:-}" ]; then
  CONFIG_DIR="${HERMES_CONFIG_DIR}"
elif [ -n "${HERMES_HOME:-}" ] && [ "$(basename "${HERMES_HOME}")" = ".hermes" ]; then
  CONFIG_DIR="${HERMES_HOME}"
else
  CONFIG_DIR="${HERMES_HOME:-${USER_HOME}}/.hermes"
fi

GOOGLE_API_SCRIPT="${HERMES_GOOGLE_API_SCRIPT:-${CONFIG_DIR}/skills/productivity/google-workspace/scripts/google_api.py}"
PYTHON_BIN=""
for candidate in \
  "${CONFIG_DIR}/hermes-agent/venv/bin/python" \
  "${CONFIG_DIR}/hermes-agent/.venv/bin/python"; do
  if [ -x "${candidate}" ]; then
    PYTHON_BIN="${candidate}"
    break
  fi
done

if [ -z "${PYTHON_BIN}" ]; then
  echo "Hermes Python venv not found under ${CONFIG_DIR}/hermes-agent." >&2
  echo "Run Deploy Hermes Agent, then Google Workspace OAuth → check." >&2
  exit 1
fi

if [ ! -f "${GOOGLE_API_SCRIPT}" ]; then
  echo "Hermes Google Workspace API script not found: ${GOOGLE_API_SCRIPT}" >&2
  echo "Run Deploy Hermes Agent to restore the bundled skill." >&2
  exit 1
fi

export HOME="${USER_HOME}"
export HERMES_HOME="${CONFIG_DIR}"
export HERMES_CONFIG_DIR="${CONFIG_DIR}"
exec "${PYTHON_BIN}" "${GOOGLE_API_SCRIPT}" "$@"
