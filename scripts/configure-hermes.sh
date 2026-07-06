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
# Stable, agent-suitable default; override via HERMES_MODEL. HERMES_MODEL may
# also be an ordered fallback chain, e.g. "gemini-3.5-pro, gemini-3.5-flash".
# The first currently available entry becomes model.default; the rest become
# fallback_providers in order, all using the Gemini provider.
HERMES_MODEL_RAW="${HERMES_MODEL:-gemini-3.5-flash}"
# Gemini's OpenAI-compatible endpoint, per Google's API docs.
GEMINI_BASE_URL="${GEMINI_BASE_URL:-https://generativelanguage.googleapis.com/v1beta/openai/}"
GEMINI_ENV_FILE="${GEMINI_ENV_FILE:-/etc/hermes-agent/hermes.env}"
# Fast deploy-time probe used only to pick a currently usable primary model.
# It avoids starting Hermes on a model that is already rate/quota/auth/model-name
# limited, while preserving the user's preference order among usable models.
HERMES_MODEL_PROBE_TIMEOUT="${HERMES_MODEL_PROBE_TIMEOUT:-6}"
HERMES_MODEL_PROBE_CONNECT_TIMEOUT="${HERMES_MODEL_PROBE_CONNECT_TIMEOUT:-2}"
HERMES_SKIP_MODEL_PROBE="${HERMES_SKIP_MODEL_PROBE:-false}"

HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
declare -a HERMES_MODEL_CHAIN=()
declare -a HERMES_MODEL_FALLBACKS=()

log() { printf '[configure] %s\n' "$*"; }

trim() {
  local value="$*"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

parse_model_chain() {
  local raw="$1"
  local entry
  local -a entries=()

  # GitHub repo variables are usually single-line, but support common ordered
  # chain delimiters so users can write comma-, newline-, semicolon-, pipe-, or
  # arrow-separated model lists.
  raw="${raw//$'\r'/,}"
  raw="${raw//$'\n'/,}"
  raw="${raw//;/,}"
  raw="${raw//|/,}"
  raw="${raw//>/,}"

  IFS=',' read -r -a entries <<<"${raw}"
  for entry in "${entries[@]}"; do
    entry="$(trim "${entry}")"
    # Allow optional gemini: prefix for readability, while keeping model IDs as
    # the actual values Hermes expects for the Gemini provider.
    if [[ "${entry}" == gemini:* ]]; then
      entry="${entry#gemini:}"
      entry="$(trim "${entry}")"
    fi
    [ -n "${entry}" ] && HERMES_MODEL_CHAIN+=("${entry}")
  done
}

yaml_quote() {
  local escaped
  escaped="$(printf '%s' "$1" | sed "s/'/''/g")"
  printf "'%s'" "${escaped}"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

read_env_file_value() {
  local name="$1"
  local file="$2"
  [ -r "${file}" ] || return 0
  awk -F= -v name="${name}" '
    $1 == name { value = substr($0, index($0, "=") + 1) }
    END { print value }
  ' "${file}"
}

resolve_gemini_api_key() {
  local key="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"
  if [ -z "${key}" ]; then
    key="$(read_env_file_value GEMINI_API_KEY "${GEMINI_ENV_FILE}")"
  fi
  if [ -z "${key}" ]; then
    key="$(read_env_file_value GOOGLE_API_KEY "${GEMINI_ENV_FILE}")"
  fi
  printf '%s' "${key}"
}

probe_gemini_model() {
  local model="$1"
  local api_key="$2"
  local tmp_file status escaped_model
  tmp_file="$(mktemp)"
  escaped_model="$(json_escape "${model}")"

  status="$({
    curl -sS -o "${tmp_file}" -w '%{http_code}' \
      --connect-timeout "${HERMES_MODEL_PROBE_CONNECT_TIMEOUT}" \
      --max-time "${HERMES_MODEL_PROBE_TIMEOUT}" \
      -H "Authorization: Bearer ${api_key}" \
      -H 'Content-Type: application/json' \
      "${GEMINI_BASE_URL%/}/chat/completions" \
      -d "{\"model\":\"${escaped_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1,\"temperature\":0}"
  } 2>/dev/null || true)"

  rm -f "${tmp_file}"
  [ "${status}" = "200" ]
}

fast_fail_unavailable_models() {
  local api_key model
  local -a available=()
  local -a unavailable=()

  case "${HERMES_SKIP_MODEL_PROBE}" in
    true|1|yes)
      log "Skipping Gemini model availability probe."
      return 0
      ;;
  esac

  api_key="$(resolve_gemini_api_key)"
  if [ -z "${api_key}" ]; then
    log "Skipping Gemini model availability probe: no GEMINI_API_KEY/GOOGLE_API_KEY found."
    return 0
  fi

  log "Probing Gemini model chain with ${HERMES_MODEL_PROBE_TIMEOUT}s max per model."
  for model in "${HERMES_MODEL_CHAIN[@]}"; do
    if probe_gemini_model "${model}" "${api_key}"; then
      available+=("${model}")
      log "Model probe passed: ${model}"
    else
      unavailable+=("${model}")
      log "Model probe failed fast: ${model}; keeping it later in the fallback chain."
    fi
  done

  if [ "${#available[@]}" -gt 0 ] && [ "${#unavailable[@]}" -gt 0 ]; then
    HERMES_MODEL_CHAIN=("${available[@]}" "${unavailable[@]}")
    log "Using first currently available model as primary: ${HERMES_MODEL_CHAIN[0]}"
  elif [ "${#available[@]}" -eq 0 ]; then
    log "No model in the chain passed the fast probe; preserving configured order and letting Hermes report runtime errors."
  fi
}

parse_model_chain "${HERMES_MODEL_RAW}"
if [ "${#HERMES_MODEL_CHAIN[@]}" -eq 0 ]; then
  HERMES_MODEL_CHAIN=("gemini-3.5-flash")
fi
fast_fail_unavailable_models
HERMES_MODEL="${HERMES_MODEL_CHAIN[0]}"
if [ "${#HERMES_MODEL_CHAIN[@]}" -gt 1 ]; then
  HERMES_MODEL_FALLBACKS=("${HERMES_MODEL_CHAIN[@]:1}")
fi

run_hermes() {
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    "${HERMES_BIN}" "$@"
}

append_model_block() {
  local model_yaml
  model_yaml="$(yaml_quote "${HERMES_MODEL}")"
  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
model:
  default: ${model_yaml}
  provider: gemini
  base_url: ${GEMINI_BASE_URL}
YAML
}

append_fallback_providers_block() {
  local model model_yaml
  [ "${#HERMES_MODEL_FALLBACKS[@]}" -gt 0 ] || return 0

  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
fallback_providers:
YAML
  for model in "${HERMES_MODEL_FALLBACKS[@]}"; do
    model_yaml="$(yaml_quote "${model}")"
    sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
  - provider: gemini
    model: ${model_yaml}
YAML
  done
}

append_terminal_block() {
  sudo -u "${HERMES_USER}" tee -a "${CONFIG_FILE}" >/dev/null <<YAML
terminal:
  backend: local
  cwd: ${WORKSPACE_DIR}
  timeout: 300
YAML
}

remove_block() {
  local key="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  awk -v key="${key}" '
    BEGIN { skip=0 }
    $0 ~ "^" key ":[[:space:]]*$" { skip=1; next }
    skip && /^[^[:space:]]/ { skip=0 }
    !skip { print }
  ' "${CONFIG_FILE}" >"${tmp_file}"
  install -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0600 "${tmp_file}" "${CONFIG_FILE}"
  rm -f "${tmp_file}"
}

log "Selecting Gemini provider and primary model '${HERMES_MODEL}'..."
if [ "${#HERMES_MODEL_FALLBACKS[@]}" -gt 0 ]; then
  log "Configuring Gemini fallback models: ${HERMES_MODEL_FALLBACKS[*]}"
else
  log "No fallback models configured."
fi

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

# Write deterministic model/fallback blocks. Hermes fallback chains are stored as
# top-level fallback_providers entries; rendering them here lets HERMES_MODEL stay
# the single GitHub variable for both primary and ordered fallback model choice.
CONFIG_FILE="${HERMES_CONFIG_DIR}/config.yaml"
sudo -u "${HERMES_USER}" touch "${CONFIG_FILE}"
remove_block model
append_model_block
remove_block fallback_providers
append_fallback_providers_block

if sudo -u "${HERMES_USER}" grep -Eq '^model:[[:space:]]*$' "${CONFIG_FILE}" 2>/dev/null \
   && sudo -u "${HERMES_USER}" grep -q 'provider: *gemini' "${CONFIG_FILE}" 2>/dev/null \
   && sudo -u "${HERMES_USER}" grep -q 'base_url: *https://generativelanguage.googleapis.com/v1beta/openai/' "${CONFIG_FILE}" 2>/dev/null; then
  log "Gemini provider recorded in config.yaml."
else
  log "Repairing config.yaml model block for Gemini."
  sudo -u "${HERMES_USER}" touch "${CONFIG_FILE}"
  sudo -u "${HERMES_USER}" sed -i '/^model:[[:space:]]*[^[:space:]]/d' "${CONFIG_FILE}" 2>/dev/null || true
  remove_block model
  append_model_block
fi

if sudo -u "${HERMES_USER}" grep -Eq '^terminal:[[:space:]]*$' "${CONFIG_FILE}" 2>/dev/null \
   && sudo -u "${HERMES_USER}" grep -q "cwd: *${WORKSPACE_DIR}" "${CONFIG_FILE}" 2>/dev/null; then
  log "Terminal workspace recorded in config.yaml."
else
  log "Repairing config.yaml terminal block for local workspace execution."
  sudo -u "${HERMES_USER}" touch "${CONFIG_FILE}"
  remove_block terminal
  append_terminal_block
fi

sudo -u "${HERMES_USER}" grep -q 'provider: *gemini' "${CONFIG_FILE}"
sudo -u "${HERMES_USER}" grep -q 'base_url: *https://generativelanguage.googleapis.com/v1beta/openai/' "${CONFIG_FILE}"
sudo -u "${HERMES_USER}" grep -q "cwd: *${WORKSPACE_DIR}" "${CONFIG_FILE}"

log "Hermes configuration step complete."
