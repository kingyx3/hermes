#!/usr/bin/env python3
"""Privileged-boundary broker for Hermes camera snapshots.

Hermes can access only this Unix socket. The broker is the only process in the
Hermes path that can access go2rtc's private Unix socket, and it exposes only
list/check/snapshot operations for camera names already present in the validated
inventory.
"""
from __future__ import annotations

import datetime as dt
import http.client
import ipaddress
import json
import os
import re
import socket
import socketserver
import subprocess
import urllib.parse
from pathlib import Path

CLIENT_SOCKET = Path(os.environ.get("CAMERA_BROKER_SOCKET", "/run/hermes-camera/camera.sock"))
GO2RTC_SOCKET = os.environ.get("GO2RTC_API_SOCKET", "/run/go2rtc/api.sock")
INVENTORY = Path(os.environ.get("CAMERA_INVENTORY", "/var/lib/go2rtc/cameras.json"))
MAX_REQUEST_BYTES = 4096
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_IMAGE_BYTES = 8 * 1024 * 1024
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_]{0,79}$")
PRIVATE_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def audit(event: str, *, camera: str | None = None, status: str = "ok") -> None:
    payload = {
        "event": event,
        "status": status,
        "time_utc": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
    }
    if camera:
        payload["camera"] = camera
    print(json.dumps(payload, sort_keys=True), flush=True)


def _valid_private_ip(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return address.version == 4 and any(address in network for network in PRIVATE_V4)


def load_inventory() -> dict[str, dict]:
    data = INVENTORY.read_bytes()
    if len(data) > 128 * 1024:
        raise RuntimeError("camera inventory exceeds safety limit")
    payload = json.loads(data)
    items = payload.get("cameras") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        raise RuntimeError("camera inventory is invalid")

    cameras: dict[str, dict] = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        ip = item.get("ip")
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            continue
        if not isinstance(ip, str) or not _valid_private_ip(ip):
            continue
        if name in cameras:
            raise RuntimeError("camera inventory contains duplicate names")
        cameras[name] = {
            "name": name,
            "display_name": str(item.get("display_name") or name),
            "ip": ip,
            "model": str(item.get("model") or ""),
        }
    return cameras


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def _read_limited(response: http.client.HTTPResponse, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(65536)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise RuntimeError("camera frame exceeded safety limit")
        chunks.append(chunk)
    return b"".join(chunks)


def fetch_mp4(camera: str) -> bytes:
    query = urllib.parse.urlencode({"src": camera})
    conn = UnixHTTPConnection(GO2RTC_SOCKET, timeout=30.0)
    try:
        conn.request("GET", "/api/frame.mp4?" + query, headers={"User-Agent": "hermes-camera-broker/2"})
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f"camera bridge returned HTTP {response.status}")
        content_type = response.getheader("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "video/mp4":
            raise RuntimeError("camera bridge returned unexpected content type")
        return _read_limited(response, MAX_FRAME_BYTES)
    finally:
        conn.close()


def mp4_to_jpeg(frame: bytes) -> bytes:
    try:
        proc = subprocess.run(
            [
                "/usr/bin/ffmpeg", "-v", "error", "-nostdin", "-threads", "1",
                "-i", "pipe:0", "-frames:v", "1", "-vf", "scale=1280:-2",
                "-filter_threads", "1", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
            ],
            input=frame,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=25,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("snapshot conversion timed out") from exc
    if proc.returncode != 0:
        raise RuntimeError("snapshot conversion failed")
    image = proc.stdout
    if len(image) > MAX_IMAGE_BYTES:
        raise RuntimeError("JPEG snapshot exceeded safety limit")
    if len(image) < 4 or not image.startswith(b"\xff\xd8") or not image.endswith(b"\xff\xd9"):
        raise RuntimeError("snapshot converter did not produce a complete JPEG")
    return image


def snapshot(camera: str) -> tuple[dict, bytes]:
    cameras = load_inventory()
    if camera not in cameras:
        raise ValueError("unknown camera")
    image = mp4_to_jpeg(fetch_mp4(camera))
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return {
        "ok": True,
        "camera": camera,
        "bytes": len(image),
        "captured_at_utc": stamp,
        "length": len(image),
    }, image


def _safe_error(exc: Exception) -> str:
    if isinstance(exc, ValueError):
        return str(exc)[:160]
    if isinstance(exc, FileNotFoundError):
        return "camera runtime is not ready"
    return "camera request failed"


class Handler(socketserver.StreamRequestHandler):
    def _send_json(self, payload: dict) -> None:
        self.wfile.write(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode() + b"\n")
        self.wfile.flush()

    def handle(self) -> None:
        camera: str | None = None
        action = "invalid"
        try:
            line = self.rfile.readline(MAX_REQUEST_BYTES + 1)
            if not line or len(line) > MAX_REQUEST_BYTES or not line.endswith(b"\n"):
                raise ValueError("invalid request")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("invalid request")
            action = request.get("action")
            if action == "list":
                cameras = load_inventory()
                self._send_json({
                    "ok": True,
                    "cameras": [
                        {"name": item["name"], "display_name": item["display_name"], "model": item["model"]}
                        for item in cameras.values()
                    ],
                })
                audit("list")
                return
            if action == "check":
                cameras = load_inventory()
                self._send_json({
                    "ok": bool(cameras),
                    "cameras": sorted(cameras),
                    "wireguard_interface": Path("/sys/class/net/home").exists(),
                    "setup_required": not bool(cameras),
                })
                audit("check", status="ok" if cameras else "setup_required")
                return
            if action != "snapshot":
                raise ValueError("unsupported action")
            camera = request.get("camera")
            if not isinstance(camera, str) or not NAME_RE.fullmatch(camera):
                raise ValueError("invalid camera name")
            header, image = snapshot(camera)
            self._send_json(header)
            self.wfile.write(image)
            self.wfile.flush()
            audit("snapshot", camera=camera)
        except (BrokenPipeError, ConnectionResetError):
            audit(action, camera=camera, status="client_disconnected")
        except Exception as exc:
            try:
                self._send_json({"ok": False, "error": _safe_error(exc)})
            except (BrokenPipeError, ConnectionResetError):
                pass
            audit(action, camera=camera, status="error")


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    request_queue_size = 4


def main() -> int:
    CLIENT_SOCKET.parent.mkdir(parents=True, exist_ok=True)
    try:
        CLIENT_SOCKET.unlink()
    except FileNotFoundError:
        pass
    old_umask = os.umask(0o117)
    try:
        server = ThreadingUnixServer(str(CLIENT_SOCKET), Handler)
    finally:
        os.umask(old_umask)
    os.chmod(CLIENT_SOCKET, 0o660)
    audit("broker_start")
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        try:
            CLIENT_SOCKET.unlink()
        except FileNotFoundError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
