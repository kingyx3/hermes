#!/usr/bin/env bash
# Run the repository-managed dependency-free Google Workspace API client.
set -euo pipefail

USER_HOME="${HERMES_USER_HOME:-${HOME:-/home/hermes}}"
if [ -n "${HERMES_CONFIG_DIR:-}" ]; then
  CONFIG_DIR="${HERMES_CONFIG_DIR}"
elif [ -n "${HERMES_HOME:-}" ] && [ "$(basename "${HERMES_HOME}")" = ".hermes" ]; then
  CONFIG_DIR="${HERMES_HOME}"
else
  CONFIG_DIR="${HERMES_HOME:-${USER_HOME}}/.hermes"
fi

GOOGLE_API_SCRIPT="${HERMES_GOOGLE_API_SCRIPT:-/usr/local/lib/hermes/google-workspace-api.py}"
if [ ! -f "${GOOGLE_API_SCRIPT}" ]; then
  GOOGLE_API_SCRIPT="${CONFIG_DIR}/skills/productivity/google-workspace/scripts/google_api.py"
fi

if [ ! -f "${GOOGLE_API_SCRIPT}" ]; then
  echo "Managed Google Workspace API script not found." >&2
  echo "Run the Google Workspace Runtime Repair workflow." >&2
  exit 1
fi

PYTHON_BIN="${HERMES_GOOGLE_PYTHON:-/usr/bin/python3}"
if [ ! -x "${PYTHON_BIN}" ]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi
if [ -z "${PYTHON_BIN}" ] || [ ! -x "${PYTHON_BIN}" ]; then
  echo "python3 is required for the dependency-free Google Workspace client." >&2
  exit 1
fi

export HOME="${USER_HOME}"
export HERMES_HOME="${CONFIG_DIR}"
export HERMES_CONFIG_DIR="${CONFIG_DIR}"
exec "${PYTHON_BIN}" "${GOOGLE_API_SCRIPT}" "$@"
