#!/usr/bin/env bash
# ===========================================================================
# hermes-ops.sh — lightweight operational wrapper, run ON THE VM.
#
# Responds to the small set of operational commands the VM is allowed to
# handle. All heavy lifting stays on GitHub Actions; this is just a thin
# convenience around systemctl, journalctl, host diagnostics, and the hermes CLI.
#
# Usage: hermes-ops.sh {start|stop|restart|status|logs|journal-boot|env-check|summary|disk|memory|doctor|smoke|telegram-check|update}
# ===========================================================================
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
HERMES_STATE_DIR="${HERMES_CONFIG_DIR}/state"
HERMES_GATEWAY_LOCK_DIR="${HERMES_STATE_DIR}/hermes/gateway-locks"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
SERVICE="hermes-agent.service"
ENV_FILE="/etc/hermes-agent/hermes.env"

run_hermes() {
  # Source the runtime env (Gemini/Telegram keys) without echoing it.
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    XDG_STATE_HOME="${HERMES_STATE_DIR}" \
    HERMES_GATEWAY_LOCK_DIR="${HERMES_GATEWAY_LOCK_DIR}" \
    bash -c 'set -a; [ -r /etc/hermes-agent/hermes.env ] && . /etc/hermes-agent/hermes.env; set +a; exec "$@"' _ "${HERMES_BIN}" "$@"
}

env_check() {
  if sudo test -r "${ENV_FILE}"; then
    sudo grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" | sed 's/=$//' | sort
  else
    echo "ERROR: ${ENV_FILE} not found or unreadable." >&2
    exit 1
  fi
}

lock_dir_check() {
  echo "HERMES_GATEWAY_LOCK_DIR=${HERMES_GATEWAY_LOCK_DIR}"
  sudo install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0700 "${HERMES_GATEWAY_LOCK_DIR}"
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    XDG_STATE_HOME="${HERMES_STATE_DIR}" \
    HERMES_GATEWAY_LOCK_DIR="${HERMES_GATEWAY_LOCK_DIR}" \
    bash -c 'tmp="${HERMES_GATEWAY_LOCK_DIR}/.write-test.$$"; echo ok > "$tmp"; rm -f "$tmp"'
  echo "OK: Hermes gateway lock directory is writable."
}

recent_telegram_errors() {
  sudo journalctl -u "${SERVICE}" --no-pager --since "-10 minutes" \
    | grep -E 'Failed to connect to Telegram|telegram failed to connect|Gateway started with no connected platforms|Read-only file system' || true
}

telegram_check() {
  sudo bash -c 'set -euo pipefail; set -a; . /etc/hermes-agent/hermes.env; set +a; if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "Telegram token not configured; skipping Telegram API check."; exit 0; fi; python3 - <<"PY"
import json
import os
import sys
import urllib.request

token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
if not token:
    print("Telegram token not configured; skipping Telegram API check.")
    raise SystemExit(0)
url = "https://api.telegram.org/bot" + token + "/getMe"
try:
    with urllib.request.urlopen(url, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    print("Telegram API check failed: " + exc.__class__.__name__, file=sys.stderr)
    raise SystemExit(1)
if not payload.get("ok"):
    print("Telegram API check failed: getMe returned ok=false", file=sys.stderr)
    raise SystemExit(1)
result = payload.get("result", {})
print("Telegram API check OK for bot id " + str(result.get("id", "unknown")) + ".")
PY'
}

smoke() {
  echo "== Service active =="
  sudo systemctl is-active --quiet "${SERVICE}" || {
    sudo systemctl --no-pager --full status "${SERVICE}" || true
    sudo journalctl -u "${SERVICE}" --no-pager -n 120 || true
    exit 1
  }
  echo "OK: ${SERVICE} is active."
  echo
  echo "== Runtime env keys =="
  env_check
  echo
  echo "== Gateway lock dir =="
  lock_dir_check
  echo
  echo "== Telegram API =="
  telegram_check
  echo
  echo "== Recent Telegram startup errors =="
  recent_errors="$(recent_telegram_errors)"
  if [ -n "${recent_errors}" ]; then
    printf '%s\n' "${recent_errors}"
    exit 1
  fi
  echo "OK: no recent Telegram gateway startup errors."
  echo
  echo "== Hermes doctor =="
  run_hermes doctor || echo "hermes doctor reported warnings; service and Telegram checks passed."
}

summary() {
  echo "== Host =="
  hostnamectl || true
  echo
  echo "== Service =="
  sudo systemctl is-enabled "${SERVICE}" || true
  sudo systemctl is-active "${SERVICE}" || true
  sudo systemctl --no-pager --full status "${SERVICE}" || true
  echo
  echo "== Hermes binary =="
  ls -l "${HERMES_BIN}" || true
  "${HERMES_BIN}" --version || true
  echo
  echo "== Disk =="
  df -h / "${HERMES_HOME}" "${HERMES_CONFIG_DIR}" 2>/dev/null || df -h / || true
  echo
  echo "== Memory =="
  free -h || true
  echo
  echo "== Runtime env keys (values redacted) =="
  env_check || true
  echo
  echo "== Gateway lock dir =="
  lock_dir_check || true
  echo
  echo "== Recent logs =="
  sudo journalctl -u "${SERVICE}" --no-pager -n "${LINES:-80}" || true
}

cmd="${1:-status}"
case "${cmd}" in
  start)   sudo systemctl start "${SERVICE}" ;;
  stop)    sudo systemctl stop "${SERVICE}" ;;
  restart) sudo systemctl restart "${SERVICE}" ;;
  status)  sudo systemctl --no-pager --full status "${SERVICE}" ;;
  logs)    sudo journalctl -u "${SERVICE}" --no-pager -n "${LINES:-200}" ;;
  journal-boot) sudo journalctl -u "${SERVICE}" --no-pager -b ;;
  env-check) env_check ;;
  summary) summary ;;
  disk) df -h / "${HERMES_HOME}" "${HERMES_CONFIG_DIR}" 2>/dev/null || df -h / ;;
  memory) free -h ;;
  doctor)  run_hermes doctor ;;
  smoke) smoke ;;
  telegram-check) telegram_check ;;
  update)
    run_hermes update
    sudo systemctl restart "${SERVICE}"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|journal-boot|env-check|summary|disk|memory|doctor|smoke|telegram-check|update}" >&2
    exit 2
    ;;
esac
