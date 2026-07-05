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
WORKSPACE_DIR="${WORKSPACE_DIR:-${HERMES_HOME}/workspace}"
# Stable, agent-suitable default; override via HERMES_MODEL.
HERMES_MODEL="${HERMES_MODEL:-gemini-3.5-flash}"
# Gemini's OpenAI-compatible endpoint, per Google's API docs.
GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta/openai/}"

HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"

log() { printf '[configure] %s\n' "$*"; }

run_hermes() {
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    "${HERMES_BIN}" "$@"
}

log "Selecting Gemini provider and model '${HERMES_MODEL}'..."
# Primary path: the documented non-interactive CLI, all as dotted keys under
# the same `model:` block (per the official config.yaml schema: `default`,
# `provider`, `base_url`). Using a BARE `model` key here (no dot) would
# overwrite the whole `model:` value with a scalar string, wiping out
# `provider`/`base_url` set just above — always use `model.default`.
# Tolerant of key-name differences across Hermes versions (never abort the
# deploy on one of these).
run_hermes config set model.provider gemini || true
run_hermes config set model.base_url "${GEMINI_BASE_URL}" || true
run_hermes config set model.default "${HERMES_MODEL}" || true
run_hermes config set terminal.backend local || true
run_hermes config set terminal.cwd "${WORKSPACE_DIR}" || true
run_hermes config set terminal.timeout 300 || true

# Verify the CLI actually recorded the gemini provider.
CONFIG_FILE="${HERMES_CONFIG_DIR}/config.yaml"
if sudo -u "${HERMES_USER}" grep -Eq '^model:[[:space:]]*$' "${CONFIG_FILE}" 2>/dev/null \
   && sudo -u "${HERMES_USER}" grep -q 'provider: *gemini' "${CONFIG_FILE}" 2>/dev/null \
   && sudo -u "${HERMES_USER}" grep -q 'base_url: *https://generativelanguage.googleapis.com/v1beta/openai/' "${CONFIG_FILE}" 2>/dev/null; then
  log "Gemini provider recorded in config.yaml."
elif sudo -u "${HERMES_USER}" grep -Eq '^model:[[:space:]]*$' "${CONFIG_FILE}" 2>/dev/null; then
  log "WARNING: config.yaml has a model block that deploy could not verify. Rewriting model block for Gemini."
  sudo -u "${HERMES_USER}" awk '
    BEGIN { skip=0 }
    /^model:[[:space:]]*$/ { skip=1; next }
    skip && /^[^[:space:]]/ { skip=0 }
    !skip { print }
  ' "${CONFIG_FILE}" >"${CONFIG_FILE}.tmp"
  sudo -u "${HERMES_USER}" mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
model:
  default: ${HERMES_MODEL}
  provider: gemini
  base_url: ${GEMINI_BASE_URL}
YAML
else
  # No model key at all, OR model: is a bad flat scalar (e.g. left over from
  # an older version of this script that used a bare, non-dotted `config set
  # model ...`, clobbering the block into a plain string). Safe to repair:
  # drop any single flat `model: <value>` line, then write the documented
  # block fresh.
  log "No usable model block found; writing the documented one directly."
  sudo -u "${HERMES_USER}" sed -i '/^model:[[:space:]]*[^[:space:]]/d' "${CONFIG_FILE}" 2>/dev/null || true
  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
model:
  default: ${HERMES_MODEL}
  provider: gemini
  base_url: ${GEMINI_BASE_URL}
YAML
fi

sudo -u "${HERMES_USER}" grep -q 'provider: *gemini' "${CONFIG_FILE}"
sudo -u "${HERMES_USER}" grep -q 'base_url: *https://generativelanguage.googleapis.com/v1beta/openai/' "${CONFIG_FILE}"

log "Hermes configuration step complete."
