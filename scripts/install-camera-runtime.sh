#!/usr/bin/env bash
# Secure Xiaomi camera runtime for the Hermes GCP VM.
# Installs a pinned go2rtc binary, a sanitized WireGuard client, read-only
# Hermes camera tooling, and periodic Xiaomi discovery. No public listener is
# created; go2rtc binds only to 127.0.0.1.
set -euo pipefail

: "${WIREGUARD_CONFIG_SOURCE:?WIREGUARD_CONFIG_SOURCE is required}"
: "${SANITIZER_SOURCE:?SANITIZER_SOURCE is required}"
: "${CAMERA_API_SOURCE:?CAMERA_API_SOURCE is required}"
: "${CAMERA_REFRESH_SOURCE:?CAMERA_REFRESH_SOURCE is required}"
: "${CAMERA_SKILL_SOURCE:?CAMERA_SKILL_SOURCE is required}"

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
XIAOMI_REGION="${XIAOMI_REGION:-sg}"
GO2RTC_VERSION="1.9.14"
GO2RTC_SHA256="32d616af226bd731678ffde328b94cfb94e30339bfefc469cfb76323144615a6"
GO2RTC_URL="https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_linux_amd64"
GO2RTC_USER="go2rtc"
GO2RTC_STATE="/var/lib/go2rtc"
GO2RTC_SECURE="/etc/go2rtc/secure.yaml"
WG_CONFIG="/etc/wireguard/home.conf"
LIB_DIR="/usr/local/lib/hermes-cameras"
SKILL_DIR="${HERMES_CONFIG_DIR}/skills/home/cameras"

log() { printf '[camera-runtime] %s\n' "$*"; }

log "Installing minimal camera runtime packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  ffmpeg \
  wireguard-tools

if ! id -u "${GO2RTC_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${GO2RTC_STATE}" --shell /usr/sbin/nologin "${GO2RTC_USER}"
fi
install -d -o root -g root -m 0755 "${LIB_DIR}" /etc/go2rtc
install -d -o root -g root -m 0700 /etc/wireguard
install -d -o "${GO2RTC_USER}" -g "${GO2RTC_USER}" -m 0700 "${GO2RTC_STATE}"
install -m 0755 "${SANITIZER_SOURCE}" "${LIB_DIR}/sanitize_wireguard.py"
install -m 0755 "${CAMERA_REFRESH_SOURCE}" "${LIB_DIR}/camera_refresh.py"

log "Validating and installing TP-Link WireGuard client export..."
tmp_wg="$(mktemp)"
trap 'rm -f "${tmp_wg}" /tmp/go2rtc-download' EXIT
python3 "${LIB_DIR}/sanitize_wireguard.py" "${WIREGUARD_CONFIG_SOURCE}" "${tmp_wg}"
install -o root -g root -m 0600 "${tmp_wg}" "${WG_CONFIG}"

log "Installing pinned go2rtc v${GO2RTC_VERSION} with release-asset digest verification..."
current_hash=""
if [ -x /usr/local/bin/go2rtc ]; then
  current_hash="$(sha256sum /usr/local/bin/go2rtc | awk '{print $1}')"
fi
if [ "${current_hash}" != "${GO2RTC_SHA256}" ]; then
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
    -o /tmp/go2rtc-download "${GO2RTC_URL}"
  echo "${GO2RTC_SHA256}  /tmp/go2rtc-download" | sha256sum -c -
  install -o root -g root -m 0755 /tmp/go2rtc-download /usr/local/bin/go2rtc
fi

# Xiaomi auth tokens are written by go2rtc to its private config. They never
# enter Hermes' environment or the repository sync surface.
if [ ! -f "${GO2RTC_STATE}/go2rtc.yaml" ]; then
  cat >"${GO2RTC_STATE}/go2rtc.yaml" <<'YAML'
xiaomi: {}
YAML
fi
if [ ! -f "${GO2RTC_STATE}/streams.json" ]; then
  printf '%s\n' '{"streams":{}}' >"${GO2RTC_STATE}/streams.json"
fi
if [ ! -f "${GO2RTC_STATE}/cameras.json" ]; then
  printf '%s\n' '{"cameras":[]}' >"${GO2RTC_STATE}/cameras.json"
fi
chown "${GO2RTC_USER}:${GO2RTC_USER}" \
  "${GO2RTC_STATE}/go2rtc.yaml" "${GO2RTC_STATE}/streams.json" "${GO2RTC_STATE}/cameras.json"
chmod 0600 "${GO2RTC_STATE}/go2rtc.yaml" "${GO2RTC_STATE}/streams.json" "${GO2RTC_STATE}/cameras.json"

cat >"${GO2RTC_SECURE}" <<'YAML'
# Security overlay. Loaded last so writable Xiaomi state cannot broaden access.
# Only the modules required for Xiaomi discovery and a single MP4 keyframe are
# initialized. In particular, exec/echo/ffmpeg/http/rtsp/webrtc are disabled.
app:
  modules:
    - api
    - mp4
    - xiaomi
api:
  listen: "127.0.0.1:1984"
  origin: ""
  allow_paths:
    - /api
    - /api/streams
    - /api/frame.mp4
    - /api/xiaomi
    - /add.html
    - /main.js
rtsp:
  listen: ""
webrtc:
  listen: ""
YAML
chmod 0644 "${GO2RTC_SECURE}"

cat >/etc/systemd/system/go2rtc.service <<EOF
[Unit]
Description=go2rtc local Xiaomi camera bridge
After=network-online.target wg-quick@home.service
Wants=network-online.target
Requires=wg-quick@home.service

[Service]
Type=simple
User=${GO2RTC_USER}
Group=${GO2RTC_USER}
WorkingDirectory=${GO2RTC_STATE}
ExecStart=/usr/local/bin/go2rtc -config ${GO2RTC_STATE}/go2rtc.yaml -config ${GO2RTC_STATE}/streams.json -config ${GO2RTC_SECURE}
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${GO2RTC_STATE}
LimitNOFILE=4096
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/hermes-camera-refresh.service <<EOF
[Unit]
Description=Refresh Xiaomi camera inventory for Hermes
After=go2rtc.service
Requires=go2rtc.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/runuser -u ${GO2RTC_USER} -- /usr/bin/env XIAOMI_REGION=${XIAOMI_REGION} /usr/bin/python3 ${LIB_DIR}/camera_refresh.py
ExecStartPost=/bin/sh -c 'if [ -f ${GO2RTC_STATE}/.refresh_changed ]; then rm -f ${GO2RTC_STATE}/.refresh_changed; systemctl try-restart go2rtc.service; fi'
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${GO2RTC_STATE}

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/hermes-camera-refresh.timer <<'EOF'
[Unit]
Description=Periodically refresh Xiaomi camera addresses

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
Persistent=true
Unit=hermes-camera-refresh.service

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/hermes-camera-auth.path <<EOF
[Unit]
Description=Refresh cameras when Xiaomi authorization changes

[Path]
PathChanged=${GO2RTC_STATE}/go2rtc.yaml
Unit=hermes-camera-refresh.service

[Install]
WantedBy=multi-user.target
EOF

log "Installing Hermes read-only camera skill..."
install -d -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0755 "${SKILL_DIR}/scripts"
install -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0644 "${CAMERA_SKILL_SOURCE}" "${SKILL_DIR}/SKILL.md"
install -o "${HERMES_USER}" -g "${HERMES_USER}" -m 0755 "${CAMERA_API_SOURCE}" "${SKILL_DIR}/scripts/camera_api.py"

systemctl daemon-reload
systemctl enable wg-quick@home.service go2rtc.service hermes-camera-refresh.timer hermes-camera-auth.path >/dev/null
systemctl restart wg-quick@home.service

# Fail closed if the TP-Link server is unreachable. PersistentKeepalive=25 is
# inserted by the sanitizer when absent, so a healthy tunnel should handshake.
log "Waiting for WireGuard handshake..."
handshake=0
for _ in $(seq 1 20); do
  handshake="$(wg show home latest-handshakes 2>/dev/null | awk 'NR==1 {print $2+0}')"
  if [ "${handshake:-0}" -gt 0 ]; then
    break
  fi
  sleep 2
done
if [ "${handshake:-0}" -le 0 ]; then
  echo "[camera-runtime] ERROR: no WireGuard handshake with TP-Link. Check WAN reachability/DDNS/CGNAT and the exported account." >&2
  exit 1
fi

systemctl restart go2rtc.service
systemctl start hermes-camera-refresh.timer hermes-camera-auth.path
# Discovery is best-effort until the one-time Xiaomi login has been completed.
systemctl start hermes-camera-refresh.service || true
systemctl try-restart hermes-agent.service || true

apt-get clean
rm -rf /var/lib/apt/lists/*

log "Camera runtime installed securely. go2rtc is localhost-only and restricted to api/mp4/xiaomi modules."
