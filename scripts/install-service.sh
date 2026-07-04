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

log() { printf '[service] %s\n' "$*"; }

if [ ! -f "${RENDERED_UNIT}" ]; then
  echo "[service] ERROR: rendered unit not found at ${RENDERED_UNIT}" >&2
  exit 1
fi

# Verify the env file exists and is locked down before starting the service.
if [ ! -f /etc/hermes-agent/hermes.env ]; then
  echo "[service] ERROR: /etc/hermes-agent/hermes.env missing; run the env step first." >&2
  exit 1
fi
sudo chown root:root /etc/hermes-agent/hermes.env
sudo chmod 0600 /etc/hermes-agent/hermes.env

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
