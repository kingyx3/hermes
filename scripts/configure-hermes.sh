#!/usr/bin/env bash
# ===========================================================================
# configure-hermes.sh — run ON THE VM (via SSH) during deployment.
#
# Configures Hermes Agent to use Gemini as its external model provider, using
# the documented non-interactive CLI. No local model inference is configured.
#
# The Gemini API key is NOT written here — it is provided at runtime by the
# systemd EnvironmentFile (/etc/hermes-agent/hermes.env). Hermes reads
# GEMINI_API_KEY / GOOGLE_API_KEY from the process environment.
#
# Idempotent. Does NOT handle secrets.
# ===========================================================================
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
# Cheap, agent-suitable default; override via HERMES_MODEL.
HERMES_MODEL="${HERMES_MODEL:-gemini-flash-latest}"
GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"

HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"

log() { printf '[configure] %s\n' "$*"; }

run_hermes() {
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    "${HERMES_BIN}" "$@"
}

log "Selecting Gemini provider and model '${HERMES_MODEL}'..."
# Primary path: the documented non-interactive CLI. Tolerant of key-name
# differences across Hermes versions (never abort the deploy on one of these).
run_hermes config set model.provider gemini || true
run_hermes config set model.base_url "${GEMINI_BASE_URL}" || true
run_hermes config set model "${HERMES_MODEL}" || true

# Verify the CLI actually recorded the gemini provider.
CONFIG_FILE="${HERMES_CONFIG_DIR}/config.yaml"
if sudo -u "${HERMES_USER}" grep -q 'provider: *gemini' "${CONFIG_FILE}" 2>/dev/null; then
  log "Gemini provider recorded in config.yaml."
elif ! sudo -u "${HERMES_USER}" grep -q '^model:' "${CONFIG_FILE}" 2>/dev/null; then
  # No model block yet — safe to append the documented one (non-secret).
  log "No model block found; writing one directly."
  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
model:
  default: ${HERMES_MODEL}
  provider: gemini
  base_url: ${GEMINI_BASE_URL}
YAML
else
  # A model block exists but does not name gemini: do NOT append (that would
  # create a duplicate key and invalid YAML). Surface it for manual review
  # rather than silently corrupting the config.
  log "WARNING: config.yaml has a model block that is not 'gemini'. Review it:"
  log "  sudo -u ${HERMES_USER} sed -n '/^model:/,/^[^[:space:]]/p' ${CONFIG_FILE}"
fi

log "Hermes configuration step complete."
