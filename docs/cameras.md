# Secure Xiaomi C500 Pro cameras for Hermes

This integration is designed for three Xiaomi home cameras behind a TP-Link
WireGuard server, with Hermes running on the existing GCP VM. Normal operation
has **no go2rtc TCP listener**. The security boundary is:

```text
Xiaomi cameras -> TP-Link WireGuard -> go2rtc private Unix socket
              -> constrained camera broker Unix socket -> Hermes -> vision
```

Hermes never receives the Xiaomi token, WireGuard private key, raw go2rtc
control socket, RTSP/WebRTC access, PTZ control, or continuous video.

## What the repository automates

After the GitHub secret `HOME_WIREGUARD_CONFIG` exists, **Home Camera Runtime**:

- validates and sanitizes the TP-Link WireGuard export; command hooks, public
  routes, default routes, IPv6 routes, and unsupported wg-quick directives are
  rejected,
- keeps the original sanitized TP-Link export root-only at
  `/etc/wireguard/home.bootstrap.conf` and the active runtime config at
  `/etc/wireguard/home.conf`, both mode `0600`,
- installs the pinned go2rtc v1.9.14 binary only after verifying its SHA-256,
- runs go2rtc as an unprivileged system user with systemd sandboxing, CPU/memory
  limits, RTSP/WebRTC disabled, and only `api`, `mp4`, and `xiaomi` modules,
- exposes go2rtc only at `/run/go2rtc/api.sock`; there is no normal TCP port
  `1984`,
- runs a second broker as a different system user. Hermes can access only the
  broker socket at `/run/hermes-camera/camera.sock`; the broker can only list
  validated cameras, health-check, or return one current snapshot,
- prevents the Hermes user from reading `/var/lib/go2rtc/go2rtc.yaml` or
  connecting to the raw go2rtc Unix socket,
- keeps snapshot conversion inside a memory/CPU-limited broker cgroup and limits
  frame/image sizes and timeouts,
- discovers Xiaomi devices through the authenticated Xiaomi cloud API, accepts
  only RFC1918 camera addresses, and validates camera names before use,
- after the first successful discovery, requires exactly three unique cameras,
  pins those IPs in `/etc/hermes-camera/camera-ips.json`, and rewrites WireGuard
  `AllowedIPs` to three `/32` routes. Later IP drift fails closed until an
  operator verifies the DHCP reservations and explicitly re-pins,
- installs a 6-hour refresh timer and a read-only Hermes `home-cameras` skill,
- adds CI security tests, CodeQL Python analysis, Dependabot for GitHub Actions,
  and a weekly go2rtc release-watch issue if the pinned version becomes stale.

## One-time TP-Link setup

On the TP-Link BE19000-class router:

1. **Reserve a stable DHCP address for each of the three cameras.** Do not
   port-forward any camera.
2. Go to **Advanced -> VPN Server -> WireGuard** and enable WireGuard.
3. Set **Client Access = Home Network Only**. Do not configure Internet-wide
   routes such as `0.0.0.0/0` or `0.0.0.0/1,128.0.0.0/1`.
4. Keep **Persistent Keepalive** at 25 seconds if the router exposes the option.
5. Enable TP-Link DDNS, or otherwise provide a stable public endpoint, if your
   WAN address changes.
6. Create a **dedicated WireGuard account** named `hermes-gcp` (or similar).
   Enable a pre-shared key if the router offers one.
7. Export that account's WireGuard configuration. Use this peer only for Hermes.

The repository permits an RFC1918 subnet route during bootstrap so discovery can
complete. Immediately after the first verified three-camera discovery it
replaces that subnet with only the three pinned camera `/32`s.

### WAN / CGNAT requirement

The TP-Link's WAN address must be reachable from the Internet. If the router's
WAN address is in `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, or
`100.64.0.0/10`, you are behind an upstream/private NAT. Obtain a public IPv4
from the ISP (or use a different VPN design) before continuing.

## Add the WireGuard secret to GitHub

The exported file contains a client private key, so never commit it. Add the
**entire exported file** as this repository Actions secret:

```text
HOME_WIREGUARD_CONFIG
```

Path: **Repository Settings -> Secrets and variables -> Actions -> Secrets ->
New repository secret**.

The workflow writes it to a mode-0600 runner temp file, copies it over IAP,
sanitizes it on the VM, and deletes temporary copies. It never enters Terraform
state or the Hermes environment.

For this setup the expected camera count defaults to `3`. Only set the optional
repository variable `CAMERA_EXPECTED_COUNT` if the intended number changes.

## Deploy and verify the network boundary

Merge the camera PR, let **Deploy Hermes Agent** finish, then let **Home Camera
Runtime** finish. The camera workflow verifies all of these automatically:

```text
wg-quick@home.service          active
go2rtc.service                 active
hermes-camera-proxy.service    active
hermes-camera-refresh.timer    enabled
/run/go2rtc/api.sock           mode 660
TCP 127.0.0.1:1984            NOT listening in normal operation
Hermes -> raw go2rtc socket    denied
Hermes -> Xiaomi token file    denied
```

The workflow fails if WireGuard never completes a handshake.

## One-time Xiaomi authorization

Xiaomi must mint an account token interactively and may require CAPTCHA,
email/SMS verification, or 2FA. Do not put the Xiaomi password or verification
code in GitHub, Telegram, Hermes, or shell arguments.

Authorization is deliberately **not available during normal operation**. You
open a 15-minute localhost-only enrollment window that uses a random one-time
Basic Auth password; it automatically closes after 15 minutes.

From a trusted computer with `gcloud` access to this GCP project:

### 1. Open the enrollment window

```bash
gcloud compute ssh hermes-agent \
  --zone us-central1-a \
  --tunnel-through-iap \
  --command 'sudo hermes-camera-auth open'
```

The command prints a temporary username (`camera-admin`) and random password.
Do not copy that password into chat or GitHub.

If repository variables change the VM name/zone, use those values instead.

### 2. In a second terminal, create the IAP-only local tunnel

```bash
gcloud compute ssh hermes-agent \
  --zone us-central1-a \
  --tunnel-through-iap \
  -- -N -L 1984:127.0.0.1:1984
```

Leave this terminal open temporarily.

### 3. Authorize Xiaomi

Open:

```text
http://127.0.0.1:1984/add.html
```

Your browser will request the temporary Basic Auth credentials printed in step
1. Choose **Xiaomi**, sign in to Mi Home, complete Xiaomi verification, and use
the region that contains your cameras (`sg` by default for this deployment).

The Xiaomi account token is written only to `/var/lib/go2rtc/go2rtc.yaml`, owned
by `go2rtc`, mode `0600`.

### 4. Close the enrollment window immediately

```bash
gcloud compute ssh hermes-agent \
  --zone us-central1-a \
  --tunnel-through-iap \
  --command 'sudo hermes-camera-auth close'
```

Closing the window restores the private Unix-socket runtime, discovers the
cameras, verifies there are exactly three, pins their IPs, converts WireGuard to
three `/32` routes, and restarts the constrained broker. The auto-close timer is
only a fallback; close it manually as soon as authorization succeeds.

If the Mi Home account uses another region, set repository variable
`XIAOMI_REGION` to the correct go2rtc Xiaomi region (`cn`, `de`, `i2`, `ru`,
`sg`, or `us`), re-run **Home Camera Runtime**, then repeat authorization.

## Verify production state

After authorization, this command should show three `/32` routes rather than a
whole home subnet:

```bash
gcloud compute ssh hermes-agent \
  --zone us-central1-a \
  --tunnel-through-iap \
  --command "sudo grep '^AllowedIPs' /etc/wireguard/home.conf"
```

Ask Hermes:

```text
Check all my cameras.
```

Hermes should list the camera names, capture one JPEG per camera through the
broker, and use `vision_analyze` on those local files.

## IP drift / DHCP changes

The first successful inventory is pinned intentionally. If a camera later gets
a different IP, automatic refresh **fails closed** rather than changing VPN
routes. First fix/verify the TP-Link DHCP reservations. Only after confirming
that the newly discovered IPs really belong to your three cameras, run:

```bash
gcloud compute ssh hermes-agent \
  --zone us-central1-a \
  --tunnel-through-iap \
  --command 'sudo hermes-camera-auth repin'
```

Do not use `repin` as a routine recovery step without checking the router first.

## Rotation and incident response

- **WireGuard key suspected compromised:** delete/recreate only the dedicated
  `hermes-gcp` peer, update `HOME_WIREGUARD_CONFIG`, and re-run Home Camera
  Runtime.
- **Xiaomi token suspected compromised:** remove/revoke the token state and run
  the short enrollment flow again. Never expose go2rtc publicly for recovery.
- **Camera IP changes unexpectedly:** treat it as a network/configuration event;
  verify TP-Link DHCP reservations before `repin`.
- **go2rtc release available:** the weekly dependency watch opens one issue for
  review. Do not blindly update the binary/digest; review upstream changes and
  let CI/CodeQL pass first.
- **No historical recording:** this deployment intentionally captures only
  requested point-in-time frames. It cannot answer what happened hours earlier.
