#!/usr/bin/env bash
# Install the Google Workspace OAuth helpers, dependency-free API clients,
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
DRIVE_SOURCE="${DRIVE_SOURCE:-${SCRIPT_DIR}/google-drive-workspace.py}"
DRIVE_OAUTH_SOURCE="${DRIVE_OAUTH_SOURCE:-${SCRIPT_DIR}/google-drive-oauth.py}"
TARGET_LIB_DIR="/usr/local/lib/hermes"
TARGET_HELPER="${TARGET_LIB_DIR}/google-workspace-oauth.py"
TARGET_API="${TARGET_LIB_DIR}/google-workspace-api.py"
TARGET_DRIVE="${TARGET_LIB_DIR}/google-drive-workspace.py"
TARGET_DRIVE_OAUTH="${TARGET_LIB_DIR}/google-drive-oauth.py"
TARGET_OAUTH_WRAPPER="/usr/local/bin/hermes-google-workspace"
TARGET_API_WRAPPER="/usr/local/bin/hermes-google-api"
TARGET_DRIVE_WRAPPER="/usr/local/bin/hermes-google-drive"
TARGET_USER_BIN_DIR="${HERMES_USER_HOME}/.local/bin"
TARGET_CLIENT="${HERMES_CONFIG_DIR}/google_client_secret.json"
TARGET_SKILL_DIR="${HERMES_CONFIG_DIR}/skills/productivity/google-workspace"
TARGET_SKILL_SCRIPTS_DIR="${TARGET_SKILL_DIR}/scripts"

validate_python_source() {
  /usr/bin/python3 - "$1" <<'PY'
import ast
import sys
from pathlib import Path

path = Path(sys.argv[1])
ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
PY
}

install -d -o root -g root -m 0755 "${TARGET_LIB_DIR}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/google-workspace-oauth.py" "${TARGET_HELPER}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-workspace.sh" "${TARGET_OAUTH_WRAPPER}"
if [ -f "${SCRIPT_DIR}/hermes-google-api.sh" ]; then
  install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-api.sh" "${TARGET_API_WRAPPER}"
fi
if [ -f "${SCRIPT_DIR}/hermes-google-drive.sh" ]; then
  install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-drive.sh" "${TARGET_DRIVE_WRAPPER}"
fi
if [ -f "${DRIVE_OAUTH_SOURCE}" ]; then
  validate_python_source "${DRIVE_OAUTH_SOURCE}"
  install -o root -g root -m 0755 "${DRIVE_OAUTH_SOURCE}" "${TARGET_DRIVE_OAUTH}"
fi

install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_USER_BIN_DIR}"
install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SCRIPT_DIR}/hermes-google-workspace.sh" "${TARGET_USER_BIN_DIR}/hermes-google-workspace"
if [ -f "${SCRIPT_DIR}/hermes-google-api.sh" ]; then
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SCRIPT_DIR}/hermes-google-api.sh" "${TARGET_USER_BIN_DIR}/hermes-google-api"
fi
if [ -f "${SCRIPT_DIR}/hermes-google-drive.sh" ]; then
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SCRIPT_DIR}/hermes-google-drive.sh" "${TARGET_USER_BIN_DIR}/hermes-google-drive"
fi
install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0700 "${HERMES_CONFIG_DIR}"

if [ -f "${API_SOURCE}" ]; then
  validate_python_source "${API_SOURCE}"
  install -o root -g root -m 0755 "${API_SOURCE}" "${TARGET_API}"
fi
if [ -f "${DRIVE_SOURCE}" ]; then
  validate_python_source "${DRIVE_SOURCE}"
  install -o root -g root -m 0755 "${DRIVE_SOURCE}" "${TARGET_DRIVE}"
fi

# Runtime Repair supplies API sources and installs the dependency-free clients.
# OAuth-only workflow actions may omit them; preserve existing installed clients.
if [ -f "${TARGET_API}" ]; then
  install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_SKILL_SCRIPTS_DIR}"
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_API}" "${TARGET_SKILL_SCRIPTS_DIR}/google_api.py"
  echo "GOOGLE_WORKSPACE_STDLIB_CLIENT_INSTALLED"
elif [ -f "${API_SOURCE}" ]; then
  echo "ERROR: dependency-free Google API client could not be installed." >&2
  exit 1
else
  echo "GOOGLE_WORKSPACE_STDLIB_CLIENT_DEFERRED: run Google Workspace Runtime Repair."
fi

if [ -f "${TARGET_DRIVE}" ]; then
  install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_SKILL_SCRIPTS_DIR}"
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_DRIVE}" "${TARGET_SKILL_SCRIPTS_DIR}/google_drive.py"
  echo "GOOGLE_DRIVE_FOLDER_CLIENT_INSTALLED"
elif [ -f "${DRIVE_SOURCE}" ]; then
  echo "ERROR: folder-bound Google Drive client could not be installed." >&2
  exit 1
else
  echo "GOOGLE_DRIVE_FOLDER_CLIENT_DEFERRED: run Google Workspace Runtime Repair."
fi

if [ -f "${SKILL_SOURCE}" ]; then
  install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${TARGET_SKILL_DIR}"
  install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0644 "${SKILL_SOURCE}" "${TARGET_SKILL_DIR}/SKILL.md"
  echo "GOOGLE_WORKSPACE_SKILL_INSTALLED"
elif [ -f "${TARGET_SKILL_DIR}/SKILL.md" ]; then
  echo "GOOGLE_WORKSPACE_SKILL_PRESERVED"
else
  echo "GOOGLE_WORKSPACE_SKILL_DEFERRED: run Google Workspace Runtime Repair."
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
  # Gmail/Calendar OAuth setup still uses google-auth libraries. Runtime clients
  # for Gmail, Calendar, Drive, Docs, and Sheets use only the standard library.
  sudo -u "${HERMES_USER}" env \
    HOME="${HERMES_USER_HOME}" \
    HERMES_USER_HOME="${HERMES_USER_HOME}" \
    HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR}" \
    "${TARGET_OAUTH_WRAPPER}" install-deps
  echo "GOOGLE_WORKSPACE_PROVISIONED"
else
  echo "GOOGLE_WORKSPACE_RUNTIME_INSTALLED_WITHOUT_CLIENT"
fi
