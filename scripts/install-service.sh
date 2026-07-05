#!/usr/bin/env bash
# ===========================================================================
# install-service.sh — run ON THE VM (via SSH) during deployment.
#
# Installs/updates the hermes-agent systemd unit (already rendered on the
# runner and copied to /tmp/hermes.service), applies journald size caps,
# enables the service, and restarts it so it picks up the latest env file.
#
# Idempotent. The rendered unit contains no secrets.
# ===========================================================================
set -euo pipefail

RENDERED_UNIT="${RENDERED_UNIT:-/tmp/hermes.service}"
UNIT_DEST="/etc/systemd/system/hermes-agent.service"
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
HERMES_STATE_DIR="${HERMES_CONFIG_DIR}/state"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
SYSTEM_ENV_FILE="/etc/hermes-agent/hermes.env"
HERMES_DOTENV="${HERMES_CONFIG_DIR}/.env"

log() { printf '[service] %s\n' "$*"; }

if [ ! -f "${RENDERED_UNIT}" ]; then
  echo "[service] ERROR: rendered unit not found at ${RENDERED_UNIT}" >&2
  exit 1
fi

# Verify the env file exists and is locked down before starting the service.
if [ ! -f "${SYSTEM_ENV_FILE}" ]; then
  echo "[service] ERROR: ${SYSTEM_ENV_FILE} missing; run the env step first." >&2
  exit 1
fi
sudo chown root:root "${SYSTEM_ENV_FILE}"
sudo chmod 0600 "${SYSTEM_ENV_FILE}"

# Hermes itself also checks $HERMES_HOME/.env for provider credentials during
# doctor/gateway startup. Keep the root-owned systemd EnvironmentFile as the
# source of truth, then mirror the rendered values into the hermes user's
# private profile .env so non-interactive deploys behave like `hermes setup`.
log "Syncing rendered env into ${HERMES_DOTENV}..."
sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0700 "${HERMES_CONFIG_DIR}"
sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0700 "${HERMES_STATE_DIR}"
sudo install -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0600 "${SYSTEM_ENV_FILE}" "${HERMES_DOTENV}"

# Upstream doctor still has a generic raw-text provider marker check that does
# not count Gemini's key names. The provider-specific Gemini check is the real
# credential check; this empty marker only prevents the stale generic setup
# summary when no other provider marker is present. If a real NOUS_API_KEY is
# supplied through extra env/secrets, it is preserved and this block is skipped.
if ! sudo grep -Eq '^(OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|ANTHROPIC_TOKEN|OPENAI_BASE_URL|NOUS_API_KEY|GLM_API_KEY|ZAI_API_KEY|Z_AI_API_KEY|KIMI_API_KEY|KIMI_CN_API_KEY|GMI_API_KEY|MINIMAX_API_KEY|MINIMAX_CN_API_KEY|KILOCODE_API_KEY|DEEPSEEK_API_KEY|DASHSCOPE_API_KEY|HF_TOKEN|OPENCODE_ZEN_API_KEY|OPENCODE_GO_API_KEY|XIAOMI_API_KEY|TOKENHUB_API_KEY)=' "${HERMES_DOTENV}"; then
  printf '\n# Compatibility marker for Hermes doctor generic provider detection.\nNOUS_API_KEY=\n' \
    | sudo tee -a "${HERMES_DOTENV}" >/dev/null
  sudo chown "${HERMES_USER}:${HERMES_USER}" "${HERMES_DOTENV}"
  sudo chmod 0600 "${HERMES_DOTENV}"
fi

# Apply Hermes config migrations once credentials are visible in the profile.
# Non-fatal: a doctor warning should not prevent systemd from restarting, and
# the follow-up health check/debug action will still expose remaining issues.
if sudo -u "${HERMES_USER}" test -x "${HERMES_BIN}"; then
  log "Running hermes doctor --fix..."
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    XDG_STATE_HOME="${HERMES_STATE_DIR}" \
    bash -c 'set -a; [ -r "$1" ] && . "$1"; set +a; exec "$2" doctor --fix' _ "${HERMES_DOTENV}" "${HERMES_BIN}" \
    || log "hermes doctor --fix reported issues; continuing so service status is visible."
fi

log "Installing systemd unit..."
sudo install -m 0644 "${RENDERED_UNIT}" "${UNIT_DEST}"

# Cap journald so logs never fill the small disk.
log "Applying journald size limits..."
sudo install -d -m 0755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/hermes.conf >/dev/null <<'CONF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=1week
CONF
sudo systemctl restart systemd-journald

log "Enabling and (re)starting hermes-agent..."
sudo systemctl daemon-reload
sudo systemctl enable hermes-agent.service
sudo systemctl restart hermes-agent.service

# Give it a moment, then report status (non-fatal).
sleep 3
sudo systemctl --no-pager --full status hermes-agent.service || true
log "Service installed."
