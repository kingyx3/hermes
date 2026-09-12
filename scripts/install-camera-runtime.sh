#!/usr/bin/env bash
# Secure Xiaomi camera runtime for the Hermes GCP VM.
# Production path: TP-Link WireGuard -> go2rtc private Unix socket -> constrained
# camera broker Unix socket -> Hermes snapshot client. No normal TCP camera API.
set -euo pipefail

: "${WIREGUARD_CONFIG_SOURCE:?WIREGUARD_CONFIG_SOURCE is required}"
: "${SANITIZER_SOURCE:?SANITIZER_SOURCE is required}"
: "${CAMERA_API_SOURCE:?CAMERA_API_SOURCE is required}"
: "${CAMERA_PROXY_SOURCE:?CAMERA_PROXY_SOURCE is required}"
: "${CAMERA_REFRESH_SOURCE:?CAMERA_REFRESH_SOURCE is required}"
: "${CAMERA_ROUTE_PIN_SOURCE:?CAMERA_ROUTE_PIN_SOURCE is required}"
: "${CAMERA_AUTH_SOURCE:?CAMERA_AUTH_SOURCE is required}"
: "${CAMERA_SKILL_SOURCE:?CAMERA_SKILL_SOURCE is required}"

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="${HERMES_HOME:-/home/hermes}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-${HERMES_HOME}/.hermes}"
XIAOMI_REGION="${XIAOMI_REGION:-sg}"
CAMERA_EXPECTED_COUNT="${CAMERA_EXPECTED_COUNT:-3}"
GO2RTC_VERSION="1.9.14"
GO2RTC_SHA256="32d616af226bd731678ffde328b94cfb94e30339bfefc469cfb76323144615a6"
GO2RTC_URL="https://github.com/AlexxIT/go2rtc/releases/download/v${GO2RTC_VERSION}/go2rtc_linux_amd64"
GO2RTC_USER="go2rtc"
PROXY_USER="hermes-camera"
GO2RTC_STATE="/var/lib/go2rtc"
GO2RTC_SECURE="/etc/go2rtc/secure.yaml"
WG_BOOTSTRAP="/etc/wireguard/home.bootstrap.conf"
WG_CONFIG="/etc/wireguard/home.conf"
CAMERA_ETC="/etc/hermes-camera"
LIB_DIR="/usr/local/lib/hermes-cameras"
SKILL_DIR="${HERMES_CONFIG_DIR}/skills/home/cameras"

log() { printf '[camera-runtime] %s\n' "$*"; }

if ! [[ "${CAMERA_EXPECTED_COUNT}" =~ ^[0-9]+$ ]] || [ "${CAMERA_EXPECTED_COUNT}" -lt 1 ] || [ "${CAMERA_EXPECTED_COUNT}" -gt 16 ]; then
  echo "[camera-runtime] ERROR: CAMERA_EXPECTED_COUNT must be 1..16" >&2
  exit 1
fi

log "Installing minimal camera runtime packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  ffmpeg \
  python3 \
  wireguard-tools

if ! id -u "${GO2RTC_USER}" >/dev/null 2>&1; then
  useradd --system --home-dir "${GO2RTC_STATE}" --shell /usr/sbin/nologin "${GO2RTC_USER}"
fi
HERMES_GROUP="$(id -gn "${HERMES_USER}")"
if ! id -u "${PROXY_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin \
    --gid "${HERMES_GROUP}" --groups "${GO2RTC_USER}" "${PROXY_USER}"
else
  usermod -a -G "${GO2RTC_USER}" "${PROXY_USER}"
fi

install -d -o root -g root -m 0755 "${LIB_DIR}" /etc/go2rtc
install -d -o root -g root -m 0700 /etc/wireguard "${CAMERA_ETC}"
install -d -o "${GO2RTC_USER}" -g "${GO2RTC_USER}" -m 0750 "${GO2RTC_STATE}"
install -m 0755 "${SANITIZER_SOURCE}" "${LIB_DIR}/sanitize_wireguard.py"
install -m 0755 "${CAMERA_REFRESH_SOURCE}" "${LIB_DIR}/camera_refresh.py"
install -m 0755 "${CAMERA_ROUTE_PIN_SOURCE}" "${LIB_DIR}/pin_camera_routes.py"
install -m 0755 "${CAMERA_PROXY_SOURCE}" "${LIB_DIR}/camera_proxy.py"
install -m 0755 "${CAMERA_AUTH_SOURCE}" /usr/local/sbin/hermes-camera-auth
cat >"${CAMERA_ETC}/runtime.env" <<EOF
XIAOMI_REGION=${XIAOMI_REGION}
CAMERA_EXPECTED_COUNT=${CAMERA_EXPECTED_COUNT}
EOF
chmod 0644 "${CAMERA_ETC}/runtime.env"

log "Validating and installing TP-Link WireGuard client export..."
tmp_wg="$(mktemp)"
trap 'rm -f "${tmp_wg}" /tmp/go2rtc-download' EXIT
python3 "${LIB_DIR}/sanitize_wireguard.py" "${WIREGUARD_CONFIG_SOURCE}" "${tmp_wg}"
install -o root -g root -m 0600 "${tmp_wg}" "${WG_BOOTSTRAP}"

if [ -f "${CAMERA_ETC}/camera-ips.json" ]; then
  CAMERA_EXPECTED_COUNT="${CAMERA_EXPECTED_COUNT}" python3 "${LIB_DIR}/pin_camera_routes.py" \
    --bootstrap "${WG_BOOTSTRAP}" --runtime "${WG_CONFIG}" \
    --inventory "${GO2RTC_STATE}/cameras.json" --pin "${CAMERA_ETC}/camera-ips.json" \
    --changed-marker /run/hermes-camera-routes.changed \
    --expected-count "${CAMERA_EXPECTED_COUNT}"
else
  install -o root -g root -m 0600 "${WG_BOOTSTRAP}" "${WG_CONFIG}"
fi

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
chmod 0600 "${GO2RTC_STATE}/go2rtc.yaml"
chmod 0640 "${GO2RTC_STATE}/streams.json" "${GO2RTC_STATE}/cameras.json"

cat >"${GO2RTC_SECURE}" <<'YAML'
app:
  modules:
    - api
    - mp4
    - xiaomi
api:
  listen: ""
  unix_listen: "/run/go2rtc/api.sock"
  origin: ""
  allow_paths:
    - /api/streams
    - /api/frame.mp4
    - /api/xiaomi
rtsp:
  listen: ""
webrtc:
  listen: ""
YAML
chmod 0644 "${GO2RTC_SECURE}"

cat >/etc/systemd/system/go2rtc.service <<EOF
[Unit]
Description=go2rtc private Xiaomi camera bridge
After=network-online.target wg-quick@home.service
Wants=network-online.target
Requires=wg-quick@home.service

[Service]
Type=simple
User=${GO2RTC_USER}
Group=${GO2RTC_USER}
WorkingDirectory=${GO2RTC_STATE}
RuntimeDirectory=go2rtc
RuntimeDirectoryMode=0750
ExecStart=/usr/local/bin/go2rtc -config ${GO2RTC_STATE}/go2rtc.yaml -config ${GO2RTC_STATE}/streams.json -config ${GO2RTC_SECURE}
ExecStartPost=/bin/chmod 0660 /run/go2rtc/api.sock
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
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${GO2RTC_STATE} /run/go2rtc
MemoryMax=192M
CPUQuota=40%
LimitNOFILE=4096
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/go2rtc-auth.service <<EOF
[Unit]
Description=Temporary localhost-only Xiaomi authorization service
After=network-online.target wg-quick@home.service
Requires=wg-quick@home.service
Conflicts=go2rtc.service

[Service]
Type=simple
User=${GO2RTC_USER}
Group=${GO2RTC_USER}
WorkingDirectory=${GO2RTC_STATE}
ExecStart=/usr/local/bin/go2rtc -config ${GO2RTC_STATE}/go2rtc.yaml -config /run/hermes-camera-auth.yaml
Restart=no
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
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${GO2RTC_STATE}
MemoryMax=128M
CPUQuota=25%
TasksMax=48
EOF

cat >/etc/systemd/system/hermes-camera-proxy.service <<EOF
[Unit]
Description=Constrained read-only camera broker for Hermes
After=go2rtc.service
Requires=go2rtc.service

[Service]
Type=simple
User=${PROXY_USER}
Group=${HERMES_GROUP}
SupplementaryGroups=${GO2RTC_USER}
RuntimeDirectory=hermes-camera
RuntimeDirectoryMode=0750
ExecStart=/usr/bin/python3 ${LIB_DIR}/camera_proxy.py
Restart=on-failure
RestartSec=3
UMask=0117
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictNamespaces=true
LockPersonality=true
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX
ReadOnlyPaths=${GO2RTC_STATE}/cameras.json
MemoryMax=256M
CPUQuota=80%
TasksMax=32

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/hermes-camera-refresh.service <<EOF
[Unit]
Description=Refresh and pin Xiaomi camera inventory/routes
After=go2rtc.service
Requires=go2rtc.service

[Service]
Type=oneshot
Environment=XIAOMI_REGION=${XIAOMI_REGION}
Environment=CAMERA_EXPECTED_COUNT=${CAMERA_EXPECTED_COUNT}
ExecStart=/usr/sbin/runuser -u ${GO2RTC_USER} -- /usr/bin/env XIAOMI_REGION=${XIAOMI_REGION} /usr/bin/python3 ${LIB_DIR}/camera_refresh.py
ExecStart=/usr/bin/python3 ${LIB_DIR}/pin_camera_routes.py --expected-count ${CAMERA_EXPECTED_COUNT}
ExecStart=/bin/sh -c 'if [ -f /run/hermes-camera/routes.changed ]; then rm -f /run/hermes-camera/routes.changed; systemctl restart wg-quick@home.service; fi; if [ -f ${GO2RTC_STATE}/.refresh_changed ]; then rm -f ${GO2RTC_STATE}/.refresh_changed; systemctl restart go2rtc.service; fi; systemctl try-restart hermes-camera-proxy.service || true'
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${GO2RTC_STATE} /etc/wireguard ${CAMERA_ETC} /run/hermes-camera
EOF

cat >/etc/systemd/system/hermes-camera-refresh.timer <<'EOF'
[Unit]
Description=Periodically refresh Xiaomi camera inventory

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=5min
Persistent=true
Unit=hermes-camera-refresh.service

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/hermes-camera-auth-close.service <<'EOF'
[Unit]
Description=Close temporary Xiaomi camera authorization window

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hermes-camera-auth close
EOF

cat >/etc/systemd/system/hermes-camera-auth-close.timer <<'EOF'
[Unit]
Description=Auto-close Xiaomi camera authorization window

[Timer]
OnActiveSec=15min
AccuracySec=10s
Unit=hermes-camera-auth-close.service
EOF

log "Installing Hermes read-only camera skill..."
install -d -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${SKILL_DIR}/scripts"
install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0644 "${CAMERA_SKILL_SOURCE}" "${SKILL_DIR}/SKILL.md"
install -o "${HERMES_USER}" -g "${HERMES_GROUP}" -m 0755 "${CAMERA_API_SOURCE}" "${SKILL_DIR}/scripts/camera_api.py"

systemctl daemon-reload
systemctl disable --now go2rtc-auth.service hermes-camera-auth-close.timer >/dev/null 2>&1 || true
rm -f /run/hermes-camera-auth.yaml
systemctl enable wg-quick@home.service go2rtc.service hermes-camera-proxy.service hermes-camera-refresh.timer >/dev/null
systemctl restart wg-quick@home.service

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
systemctl restart hermes-camera-proxy.service
systemctl start hermes-camera-refresh.timer
systemctl start hermes-camera-refresh.service || true
systemctl try-restart hermes-agent.service || true

apt-get clean
rm -rf /var/lib/apt/lists/*

log "Camera runtime installed. Production go2rtc API is Unix-socket-only; Hermes reaches only the constrained broker."
