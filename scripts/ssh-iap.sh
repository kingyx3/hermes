#!/usr/bin/env bash
# ===========================================================================
# ssh-iap.sh — run ON THE GITHUB ACTIONS RUNNER.
#
# Sets up (and tears down) EPHEMERAL SSH access to the VM through IAP TCP
# forwarding. No long-lived VM SSH key is ever stored as a GitHub secret:
# a fresh keypair is generated per run, registered via OS Login with a short
# TTL, and removed at the end.
#
#   ssh-iap.sh up    -> keygen + OS Login add + start IAP tunnel to localhost
#   ssh-iap.sh down  -> stop tunnel + remove the ephemeral key from OS Login
#
# State (key path, port, login user, tunnel pid) is written to $STATE_DIR/env
# so the calling workflow can `source` it:
#
#   source "$(scripts/ssh-iap.sh up)"     # prints the path to the env file
#   ssh -i "$SSH_KEY" -p "$SSH_PORT" ... "$SSH_USER"@localhost
#   scripts/ssh-iap.sh down
#
# Required env: VM_NAME, ZONE, PROJECT_ID
# Optional env: LOCAL_PORT (default 2222), STATE_DIR, KEY_TTL (default 3600s)
# ===========================================================================
set -euo pipefail

: "${VM_NAME:?VM_NAME required}"
: "${ZONE:?ZONE required}"
: "${PROJECT_ID:?PROJECT_ID required}"
LOCAL_PORT="${LOCAL_PORT:-2222}"
KEY_TTL="${KEY_TTL:-3600s}"
STATE_DIR="${STATE_DIR:-${RUNNER_TEMP:-/tmp}/hermes-ssh}"
ENV_FILE="${STATE_DIR}/env"

log() { printf '[ssh-iap] %s\n' "$*" >&2; }

up() {
  mkdir -p "${STATE_DIR}"
  chmod 700 "${STATE_DIR}"
  local key="${STATE_DIR}/id_ed25519"

  log "Generating ephemeral SSH keypair..."
  rm -f "${key}" "${key}.pub"
  ssh-keygen -t ed25519 -N "" -f "${key}" -C "hermes-ci-ephemeral" >/dev/null

  log "Registering public key with OS Login (TTL ${KEY_TTL})..."
  gcloud compute os-login ssh-keys add \
    --key-file="${key}.pub" \
    --ttl="${KEY_TTL}" \
    --project="${PROJECT_ID}" >/dev/null

  local user
  user="$(gcloud compute os-login describe-profile \
    --project="${PROJECT_ID}" \
    --format='value(posixAccounts[0].username)')"
  if [ -z "${user}" ]; then
    log "ERROR: could not determine OS Login username."
    exit 1
  fi

  log "Starting IAP tunnel localhost:${LOCAL_PORT} -> ${VM_NAME}:22 ..."
  nohup gcloud compute start-iap-tunnel "${VM_NAME}" 22 \
    --local-host-port="localhost:${LOCAL_PORT}" \
    --zone="${ZONE}" \
    --project="${PROJECT_ID}" >"${STATE_DIR}/tunnel.log" 2>&1 &
  echo $! >"${STATE_DIR}/tunnel.pid"

  # Wait for the tunnel to accept connections.
  local i
  for i in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/localhost/${LOCAL_PORT}") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      break
    fi
    sleep 1
    if [ "${i}" = "30" ]; then
      log "ERROR: IAP tunnel did not come up in time."
      cat "${STATE_DIR}/tunnel.log" >&2 || true
      exit 1
    fi
  done

  {
    echo "export SSH_KEY='${key}'"
    echo "export SSH_PORT='${LOCAL_PORT}'"
    echo "export SSH_USER='${user}'"
    echo "export SSH_OPTS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'"
  } >"${ENV_FILE}"

  log "Ephemeral SSH ready (user=${user})."
  echo "${ENV_FILE}"
}

down() {
  if [ -f "${STATE_DIR}/tunnel.pid" ]; then
    log "Stopping IAP tunnel..."
    kill "$(cat "${STATE_DIR}/tunnel.pid")" 2>/dev/null || true
    rm -f "${STATE_DIR}/tunnel.pid"
  fi
  if [ -f "${STATE_DIR}/id_ed25519.pub" ]; then
    log "Removing ephemeral key from OS Login..."
    # --key accepts either a raw public key or its OS Login fingerprint (a hex
    # SHA-256 digest) -- NOT ssh-keygen's base64 display fingerprint, which is
    # a different format and would silently never match. Pass the public key
    # file directly to avoid the format mismatch entirely.
    gcloud compute os-login ssh-keys remove --key="${STATE_DIR}/id_ed25519.pub" --project="${PROJECT_ID}" || true
  fi
  rm -rf "${STATE_DIR}"
  log "Ephemeral SSH torn down."
}

case "${1:-}" in
  up)   up ;;
  down) down ;;
  *)    echo "Usage: $0 {up|down}" >&2; exit 2 ;;
esac
