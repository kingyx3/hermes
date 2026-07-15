#!/usr/bin/env bash
# Install the Google Workspace OAuth helper, dependency-free API client,
# managed skill instructions, wrappers, and optional Desktop OAuth client.
# Run on the VM as root through GitHub Actions' ephemeral IAP SSH path.
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_GROUP="${HERMES_GROUP:-${HERMES_USER}}"
HERMES_USER_HOME="${HERMES_USER_HOME:-${HERMES_HOME:-/home/hermes}}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_USER_HOME}/.hermes}"
CLIENT_SECRET_SOURCE="${CLIENT_SECRET_SOURCE:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SOURCE="${SKILL_SOURCE:-${SCRIPT_DIR}/google-workspace-skill/SKILL.md}"
API_SOURCE="${API_SOURCE:-${SCRIPT_DIR}/google-workspace-api.py}"
TARGET_LIB_DIR="/usr/local/lib/hermes"
TARGET_HELPER="${TARGET_LIB_DIR}/google-workspace-oauth.py"
TARGET_API="${TARGET_LIB_DIR}/google-workspace-api.py"
TARGET_OAUTH_WRAPPER="/usr/local/bin/hermes-google-workspace"
TARGET_API_WRAPPER="/usr/local/bin/hermes-google-api"
TARGET_USER_BIN_DIR="${HERMES_USER_HOME}/.local/bin"
TARGET_CLIENT="${HERMES_CONFIG_DIR}/google_client_secret.json"
TARGET_SKILL_DIR="${HERMES_CONFIG_DIR}/skills/productivity/google-workspace"
TARGET_SKILL_SCRIPTS_DIR="${TARGET_SKILL_DIR}/scripts"

install -d -o root -g root -m 0755 "${TARGET_LIB_DIR}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/google-workspace-oauth.py" "${TARGET_HELPER}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-workspace.sh" "${TARGET_OAUTH_WRAPPER}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-api.sh" "${TARGET_API_WRAPPER}"
install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_USER_BIN_DIR}"
install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SCRIPT_DIR}/hermes-google-workspace.sh" "${TARGET_USER_BIN_DIR}/hermes-google-workspace"
install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SCRIPT_DIR}/hermes-google-api.sh" "${TARGET_USER_BIN_DIR}/hermes-google-api"
install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0700 "${HERMES_CONFIG_DIR}"

if [ -f "${API_SOURCE}" ]; then
  /usr/bin/python3 -m py_compile "${API_SOURCE}"
  install -o root -g root -m 0755 "${API_SOURCE}" "${TARGET_API}"
  install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_SKILL_SCRIPTS_DIR}"
  # Replace the exact bundled compatibility-client path. This makes both the
  # managed skill and stale upstream instructions dependency-free.
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${API_SOURCE}" "${TARGET_SKILL_SCRIPTS_DIR}/google_api.py"
  echo "GOOGLE_WORKSPACE_STDLIB_CLIENT_INSTALLED"
else
  echo "ERROR: dependency-free Google API source not found: ${API_SOURCE}" >&2
  exit 1
fi

if [ -f "${SKILL_SOURCE}" ]; then
  install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_SKILL_DIR}"
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0644 "${SKILL_SOURCE}" "${TARGET_SKILL_DIR}/SKILL.md"
  echo "GOOGLE_WORKSPACE_SKILL_INSTALLED"
else
  echo "ERROR: managed Google Workspace skill source not found: ${SKILL_SOURCE}" >&2
  exit 1
fi

if [ -n "${CLIENT_SECRET_SOURCE}" ]; then
  [ -f "${CLIENT_SECRET_SOURCE}" ] || { echo "OAuth client file not found" >&2; exit 1; }
  python3 - "${CLIENT_SECRET_SOURCE}" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
installed = payload.get("installed")
if not isinstance(installed, dict) or not installed.get("client_id") or not installed.get("client_secret"):
    raise SystemExit("Expected Google OAuth Desktop app JSON with installed.client_id and installed.client_secret")
PY
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0600 "${CLIENT_SECRET_SOURCE}" "${TARGET_CLIENT}"
fi

if [ -f "${TARGET_CLIENT}" ]; then
  # The OAuth setup helper still uses google-auth libraries. Runtime Gmail and
  # Calendar operations use the standard-library client above and need no pip.
  sudo -u "${HERMES_USER}" env \
    HOME="${HERMES_USER_HOME}" \
    HERMES_USER_HOME="${HERMES_USER_HOME}" \
    HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR}" \
    "${TARGET_OAUTH_WRAPPER}" install-deps
  echo "GOOGLE_WORKSPACE_PROVISIONED"
else
  echo "GOOGLE_WORKSPACE_RUNTIME_INSTALLED_WITHOUT_CLIENT"
fi
