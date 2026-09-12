---
name: home-cameras
description: "Read-only access to the configured Xiaomi home cameras through the local go2rtc/WireGuard bridge. Use for current visual checks of the home; never claim historical coverage."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [Home, Camera, Xiaomi, Vision, Security]
---

# Home cameras — read-only live snapshots

Use this skill whenever the user asks what is currently visible at home, asks
you to check one or more cameras, or asks whether a person/animal/object is
visible. The integration is deliberately snapshot-only: it does not expose
camera credentials, RTSP, audio, PTZ, recording, or historical footage.

## Runtime

```bash
CAPI="${HERMES_HOME:-$HOME/.hermes}/skills/home/cameras/scripts/camera_api.py"
test -x "$CAPI" || { echo "Camera Runtime Repair is required: $CAPI is missing" >&2; exit 1; }
```

Only invoke it with `/usr/bin/python3`:

```bash
/usr/bin/python3 "$CAPI" check
/usr/bin/python3 "$CAPI" list
/usr/bin/python3 "$CAPI" snapshot CAMERA_NAME
/usr/bin/python3 "$CAPI" snapshot-all
```

## Routing rules

1. Run `list` before the first camera request in a conversation unless the exact
   configured camera name is already known from a fresh result.
2. For one camera, run `snapshot CAMERA_NAME`. For a request covering the home,
   run `snapshot-all`.
3. Each successful snapshot result contains a local `path`. Call Hermes'
   `vision_analyze` tool on that exact local image path before describing what
   is visible. Do not infer visual details from the camera name or command
   output alone.
4. Treat each image as a point-in-time observation. Say that you cannot answer
   historical questions ("what happened earlier", "who came home at 3pm") from
   this integration because it intentionally does not record video.
5. Do not use curl, raw go2rtc endpoints, Xiaomi account APIs, WireGuard tools,
   or camera-control protocols as a substitute for this client.
6. Never expose or search for Xiaomi tokens, WireGuard private keys, the
   go2rtc writable configuration, or `/etc/wireguard/home.conf`.
7. A failed `check` with `setup_required: true` means the operator still needs
   to complete the one-time Xiaomi authorization documented in `docs/cameras.md`.

## Multi-camera answers

Analyze each returned image separately, keeping camera names attached to the
observations, then summarize across cameras. If a snapshot fails for one camera,
report that camera as unavailable rather than treating it as empty.
