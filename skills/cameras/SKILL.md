---
name: home-cameras
description: "Read-only current snapshots from configured Xiaomi home cameras through a constrained Unix-socket broker. Use for current visual checks only; never claim historical coverage or camera-control capability."
version: 1.1.0
platforms: [linux]
metadata:
  hermes:
    tags: [Home, Camera, Xiaomi, Vision, Security]
---

# Home cameras — read-only live snapshots

Use this skill whenever the user asks what is currently visible at home, asks
you to check one or more cameras, or asks whether a person/animal/object is
visible. The integration is deliberately snapshot-only: it does not expose
camera credentials, raw go2rtc access, RTSP, audio, PTZ, recording, or
historical footage.

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
   is visible. Never infer visual details from the camera name or command output.
4. Treat every image as a point-in-time observation. State that historical
   questions cannot be answered because this integration intentionally records
   no video.
5. Do not use curl, raw Unix sockets, go2rtc endpoints, Xiaomi APIs, WireGuard
   tools, `/var/lib/go2rtc`, or `/etc/wireguard` as substitutes for this client.
6. Never attempt to discover, read, reveal, rotate, or modify Xiaomi tokens,
   WireGuard keys, route pins, or go2rtc configuration.
7. Never open the temporary Xiaomi authorization service. Enrollment is an
   operator-only action and is not part of answering a camera request.
8. If a camera fails, report it as unavailable. Do not interpret failure as an
   empty room and do not attempt alternate network paths.

## Multi-camera answers

Analyze each returned image separately, keeping camera names attached to the
observations, then summarize across cameras. Avoid identifying people by name
unless the user explicitly provides that identity in the current context.
