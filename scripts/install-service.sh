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
sudo install -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0600 "${SYSTEM_ENV_FILE}" "${HERMES_DOTENV}"

# Apply Hermes config migrations once credentials are visible in the profile.
# Non-fatal: a doctor warning should not prevent systemd from restarting, and
# the follow-up health check/debug action will still expose remaining issues.
if sudo -u "${HERMES_USER}" test -x "${HERMES_BIN}"; then
  log "Running hermes doctor --fix..."
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
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
