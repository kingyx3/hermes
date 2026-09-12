#!/usr/bin/env python3
"""Hermes-facing read-only camera client for the local go2rtc service."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_BASE = os.environ.get("CAMERA_GO2RTC_URL", "http://127.0.0.1:1984").rstrip("/")
USER_AGENT = "hermes-camera-api/1"
MAX_FRAME_BYTES = 16 * 1024 * 1024
MAX_IMAGE_BYTES = 8 * 1024 * 1024
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_]{0,79}$")


def request(path: str, timeout: float = 20.0):
    req = urllib.request.Request(API_BASE + path, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def list_cameras() -> list[str]:
    with request("/api/streams", timeout=8.0) as response:
        payload = json.load(response)
    if isinstance(payload, dict):
        names = payload.keys()
    elif isinstance(payload, list):
        names = [item.get("name") for item in payload if isinstance(item, dict)]
    else:
        raise RuntimeError("unexpected response from go2rtc /api/streams")
    return sorted(name for name in names if isinstance(name, str) and NAME_RE.fullmatch(name))


def cache_dir() -> Path:
    hermes_home = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
    target = Path(os.environ.get("CAMERA_CACHE_DIR", str(hermes_home / "cache" / "cameras")))
    target.mkdir(parents=True, exist_ok=True)
    os.chmod(target, 0o700)
    return target


def read_limited(response, limit: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = response.read(65536)
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise RuntimeError(f"camera frame exceeded {limit // (1024 * 1024)} MiB safety limit")
        chunks.append(chunk)
    return b"".join(chunks)


def mp4_to_jpeg(frame: bytes) -> bytes:
    try:
        proc = subprocess.run(
            [
                "/usr/bin/ffmpeg", "-v", "error", "-nostdin",
                "-i", "pipe:0", "-frames:v", "1", "-vf", "scale=1280:-2",
                "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
            ],
            input=frame,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=25,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("ffmpeg snapshot conversion timed out") from exc
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace")[-500:].strip()
        raise RuntimeError(f"ffmpeg snapshot conversion failed: {detail or 'unknown error'}")
    image = proc.stdout
    if len(image) > MAX_IMAGE_BYTES:
        raise RuntimeError("JPEG snapshot exceeded 8 MiB safety limit")
    if len(image) < 4 or not image.startswith(b"\xff\xd8") or not image.endswith(b"\xff\xd9"):
        raise RuntimeError("ffmpeg did not produce a complete JPEG")
    return image


def snapshot(camera: str) -> dict:
    cameras = list_cameras()
    if camera not in cameras:
        raise ValueError(f"unknown camera {camera!r}; available: {', '.join(cameras) or 'none'}")
    query = urllib.parse.urlencode({"src": camera})
    with request("/api/frame.mp4?" + query, timeout=30.0) as response:
        if response.headers.get_content_type() != "video/mp4":
            raise RuntimeError(f"go2rtc returned {response.headers.get_content_type()}, expected video/mp4")
        frame = read_limited(response, MAX_FRAME_BYTES)
    image = mp4_to_jpeg(frame)

    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = cache_dir() / f"{camera}-{stamp}.jpg"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(image)
    return {"camera": camera, "path": str(path), "bytes": len(image), "captured_at_utc": stamp}


def emit(payload: dict, code: int = 0) -> int:
    print(json.dumps(payload, indent=2, sort_keys=True))
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description="Read-only Xiaomi camera snapshots for Hermes")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check")
    sub.add_parser("list")
    one = sub.add_parser("snapshot")
    one.add_argument("camera")
    sub.add_parser("snapshot-all")
    args = parser.parse_args()

    try:
        if args.command == "list":
            cameras = list_cameras()
            return emit({"ok": True, "cameras": cameras})
        if args.command == "check":
            cameras = list_cameras()
            return emit({
                "ok": bool(cameras),
                "go2rtc": "reachable",
                "wireguard_interface": Path("/sys/class/net/home").exists(),
                "cameras": cameras,
                "setup_required": not bool(cameras),
            }, 0 if cameras else 2)
        if args.command == "snapshot":
            return emit({"ok": True, **snapshot(args.camera)})
        if args.command == "snapshot-all":
            cameras = list_cameras()
            if not cameras:
                return emit({"ok": False, "error": "no configured cameras"}, 2)
            images = []
            errors = []
            for camera in cameras:
                try:
                    images.append(snapshot(camera))
                except Exception as exc:
                    errors.append({"camera": camera, "error": str(exc)})
            return emit({"ok": bool(images), "images": images, "errors": errors}, 0 if images else 2)
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
        return emit({"ok": False, "error": str(exc)}, 2)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
