#!/usr/bin/env bash
# ===========================================================================
# bootstrap-vm.sh — run ON THE VM (via SSH) during deployment.
#
# Installs the minimum OS dependencies, creates the dedicated hermes user and
# directories, installs the OFFICIAL Nous Research Hermes Agent, and cleans up
# package-manager caches to keep the e2-micro small.
#
# Heavy/browser components are skipped (--skip-browser) because this VM never
# runs local model inference or browser automation.
#
# Idempotent: safe to re-run. Requires sudo (run as a sudo-capable OS Login
# user). Does NOT handle any secrets.
# ===========================================================================
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
WORKSPACE_DIR="${WORKSPACE_DIR:-${HERMES_HOME}/workspace}"
# Set ENABLE_SWAP=1 to create a small swap file (helps the 1 GB e2-micro during
# the one-time install). Off by default; see README for the tradeoff.
ENABLE_SWAP="${ENABLE_SWAP:-0}"

log() { printf '[bootstrap] %s\n' "$*"; }

# --- 1. Minimal OS packages -------------------------------------------------
log "Installing minimal OS dependencies..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
# curl: installer download; git: Hermes runtime pulls updates; ripgrep: Hermes
# tool dependency; ca-certificates: TLS; rsync: used by the sync workflow;
# python3-venv: Hermes venv. Node.js is fetched by the Hermes installer itself.
sudo apt-get install -y --no-install-recommends \
  curl \
  git \
  ripgrep \
  ca-certificates \
  rsync \
  python3-venv

# --- 2. Optional small swap (one-time install headroom) ---------------------
if [ "${ENABLE_SWAP}" = "1" ] && [ ! -f /swapfile ]; then
  log "Creating 1 GiB swap file..."
  sudo fallocate -l 1G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=1024
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
fi

# --- 3. Dedicated non-root user + directories -------------------------------
if ! id -u "${HERMES_USER}" >/dev/null 2>&1; then
  log "Creating user ${HERMES_USER}..."
  sudo useradd --create-home --home-dir "${HERMES_HOME}" --shell /bin/bash "${HERMES_USER}"
fi

log "Ensuring directories and ownership..."
sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0755 "${HERMES_HOME}"
sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0700 "${HERMES_CONFIG_DIR}"
sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0755 "${WORKSPACE_DIR}"

# --- 4. Install the official Hermes Agent (as the hermes user) ---------------
# Skip if already installed (idempotent); use `hermes update` for upgrades.
if sudo -u "${HERMES_USER}" test -x "${HERMES_HOME}/.local/bin/hermes"; then
  log "Hermes already installed; skipping installer (use hermes update to upgrade)."
else
  log "Installing official Nous Research Hermes Agent (non-interactive, no browser)..."
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-setup --skip-browser'
fi

# --- 5. Trim caches to keep the disk small ----------------------------------
log "Cleaning package-manager caches..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
# uv download cache created during install.
sudo -u "${HERMES_USER}" rm -rf "${HERMES_CONFIG_DIR}/cache" "${HERMES_HOME}/.cache/uv" 2>/dev/null || true

log "Bootstrap complete."
