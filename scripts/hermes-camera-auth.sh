#!/usr/bin/env bash
# Open/close a short-lived, localhost-only Xiaomi authorization window.
set -euo pipefail

ACTION="${1:-status}"
RUNTIME_ENV="/etc/hermes-camera/runtime.env"
if [ -r "${RUNTIME_ENV}" ]; then
  # shellcheck disable=SC1090
  . "${RUNTIME_ENV}"
fi
XIAOMI_REGION="${XIAOMI_REGION:-sg}"
CAMERA_EXPECTED_COUNT="${CAMERA_EXPECTED_COUNT:-3}"
AUTH_CONFIG="/run/hermes-camera-auth.yaml"
AUTH_SERVICE="go2rtc-auth.service"
CLOSE_TIMER="hermes-camera-auth-close.timer"

open_window() {
  local password
  password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"

  systemctl stop "${CLOSE_TIMER}" >/dev/null 2>&1 || true
  systemctl stop hermes-camera-proxy.service go2rtc.service >/dev/null 2>&1 || true

  umask 077
  cat >"${AUTH_CONFIG}" <<YAML
app:
  modules:
    - api
    - xiaomi
api:
  listen: "127.0.0.1:1984"
  unix_listen: ""
  username: "camera-admin"
  password: "${password}"
  local_auth: true
  origin: ""
  allow_paths:
    - /
    - /api/xiaomi
rtsp:
  listen: ""
webrtc:
  listen: ""
YAML
  chown root:go2rtc "${AUTH_CONFIG}"
  chmod 0640 "${AUTH_CONFIG}"

  systemctl start "${AUTH_SERVICE}"
  systemctl restart "${CLOSE_TIMER}"

  cat <<EOF
Xiaomi camera authorization window is open for 15 minutes.

Username: camera-admin
Password: ${password}

Keep this credential private; it expires when the window closes and is not stored in the repository.
In another terminal, create the documented IAP port-forward and open http://127.0.0.1:1984/add.html .
After Xiaomi login succeeds, run: sudo hermes-camera-auth close
EOF
}

close_window() {
  systemctl stop "${CLOSE_TIMER}" >/dev/null 2>&1 || true
  systemctl stop "${AUTH_SERVICE}" >/dev/null 2>&1 || true
  rm -f "${AUTH_CONFIG}"
  systemctl restart go2rtc.service
  systemctl restart hermes-camera-proxy.service
  systemctl start hermes-camera-refresh.service || {
    echo "Camera discovery/route pinning failed. Check: journalctl -u hermes-camera-refresh.service" >&2
    return 1
  }
  echo "Xiaomi authorization window closed; private Unix-socket runtime restored."
}

repin_routes() {
  echo "Refreshing Xiaomi inventory before explicit route re-pin..."
  /usr/sbin/runuser -u go2rtc -- /usr/bin/env XIAOMI_REGION="${XIAOMI_REGION}" \
    /usr/bin/python3 /usr/local/lib/hermes-cameras/camera_refresh.py
  /usr/bin/python3 /usr/local/lib/hermes-cameras/pin_camera_routes.py \
    --expected-count "${CAMERA_EXPECTED_COUNT}" --repin
  if [ -f /run/hermes-camera/routes.changed ]; then
    rm -f /run/hermes-camera/routes.changed
    systemctl restart wg-quick@home.service
  fi
  if [ -f /var/lib/go2rtc/.refresh_changed ]; then
    rm -f /var/lib/go2rtc/.refresh_changed
    systemctl restart go2rtc.service
  fi
  systemctl try-restart hermes-camera-proxy.service || true
  echo "Camera /32 routes re-pinned after explicit operator approval."
}

case "${ACTION}" in
  open)
    open_window
    ;;
  close)
    close_window
    ;;
  repin)
    repin_routes
    ;;
  status)
    if systemctl is-active --quiet "${AUTH_SERVICE}"; then
      echo "authorization-window=open"
    else
      echo "authorization-window=closed"
    fi
    systemctl is-active wg-quick@home.service go2rtc.service hermes-camera-proxy.service || true
    ;;
  *)
    echo "Usage: hermes-camera-auth open|close|repin|status" >&2
    exit 2
    ;;
esac
