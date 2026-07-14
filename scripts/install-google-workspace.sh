#!/usr/bin/env bash
# Install the Google Workspace OAuth helper and optional Desktop OAuth client.
# Run on the VM as root through the GitHub Actions IAP workflow.
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_GROUP="${HERMES_GROUP:-${HERMES_USER}}"
HERMES_USER_HOME="${HERMES_USER_HOME:-${HERMES_HOME:-/home/hermes}}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_USER_HOME}/.hermes}"
CLIENT_SECRET_SOURCE="${CLIENT_SECRET_SOURCE:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB_DIR="/usr/local/lib/hermes"
TARGET_HELPER="${TARGET_LIB_DIR}/google-workspace-oauth.py"
TARGET_WRAPPER="/usr/local/bin/hermes-google-workspace"
TARGET_CLIENT="${HERMES_CONFIG_DIR}/google_client_secret.json"

install -d -o root -g root -m 0755 "${TARGET_LIB_DIR}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/google-workspace-oauth.py" "${TARGET_HELPER}"
install -o root -g root -m 0755 "${SCRIPT_DIR}/hermes-google-workspace.sh" "${TARGET_WRAPPER}"
install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0700 "${HERMES_CONFIG_DIR}"

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
  sudo -u "${HERMES_USER}" env \
    HOME="${HERMES_USER_HOME}" \
    HERMES_USER_HOME="${HERMES_USER_HOME}" \
    HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR}" \
    "${TARGET_WRAPPER}" install-deps
  echo "GOOGLE_WORKSPACE_PROVISIONED"
else
  echo "GOOGLE_WORKSPACE_HELPER_INSTALLED_WITHOUT_CLIENT"
fi
