#!/usr/bin/env bash
# ===========================================================================
# hermes-ops.sh — lightweight operational wrapper, run ON THE VM.
#
# Responds to the small set of operational commands the VM is allowed to
# handle. All heavy lifting stays on GitHub Actions; this is just a thin
# convenience around systemctl and the hermes CLI.
#
# Usage: hermes-ops.sh {start|stop|restart|status|logs|doctor|update}
# ===========================================================================
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
HERMES_BIN="${HERMES_HOME}/.local/bin/hermes"
SERVICE="hermes-agent.service"

run_hermes() {
  # Source the runtime env (Gemini key) without echoing it.
  sudo -u "${HERMES_USER}" \
    HERMES_HOME="${HERMES_CONFIG_DIR}" \
    HOME="${HERMES_HOME}" \
    bash -c 'set -a; [ -r /etc/hermes-agent/hermes.env ] && . /etc/hermes-agent/hermes.env; set +a; exec "$@"' _ "${HERMES_BIN}" "$@"
}

cmd="${1:-status}"
case "${cmd}" in
  start)   sudo systemctl start "${SERVICE}" ;;
  stop)    sudo systemctl stop "${SERVICE}" ;;
  restart) sudo systemctl restart "${SERVICE}" ;;
  status)  sudo systemctl --no-pager --full status "${SERVICE}" ;;
  logs)    sudo journalctl -u "${SERVICE}" --no-pager -n "${LINES:-200}" ;;
  doctor)  run_hermes doctor ;;
  update)
    run_hermes update
    sudo systemctl restart "${SERVICE}"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|doctor|update}" >&2
    exit 2
    ;;
esac
