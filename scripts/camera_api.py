#!/usr/bin/env python3
"""Hermes-facing client for the constrained local camera broker."""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
from pathlib import Path

BROKER_SOCKET = os.environ.get("CAMERA_BROKER_SOCKET", "/run/hermes-camera/camera.sock")
MAX_HEADER_BYTES = 8192
MAX_IMAGE_BYTES = 8 * 1024 * 1024
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_]{0,79}$")


def _recv_line(sock: socket.socket, limit: int = MAX_HEADER_BYTES) -> bytes:
    data = bytearray()
    while len(data) <= limit:
        chunk = sock.recv(1)
        if not chunk:
            break
        data += chunk
        if chunk == b"\n":
            return bytes(data)
    raise RuntimeError("camera broker returned an invalid response")


def _recv_exact(sock: socket.socket, length: int) -> bytes:
    if length < 0 or length > MAX_IMAGE_BYTES:
        raise RuntimeError("camera broker returned an invalid image length")
    data = bytearray()
    while len(data) < length:
        chunk = sock.recv(min(65536, length - len(data)))
        if not chunk:
            raise RuntimeError("camera broker closed before completing the image")
        data += chunk
    return bytes(data)


def broker_request(payload: dict, *, expect_image: bool = False, timeout: float = 35.0) -> tuple[dict, bytes | None]:
    wire = json.dumps(payload, separators=(",", ":")).encode() + b"\n"
    if len(wire) > 4096:
        raise ValueError("camera request is too large")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(BROKER_SOCKET)
        sock.sendall(wire)
        header = json.loads(_recv_line(sock))
        if not isinstance(header, dict):
            raise RuntimeError("camera broker returned an invalid response")
        if not header.get("ok"):
            raise RuntimeError(str(header.get("error") or "camera request failed"))
        if not expect_image:
            return header, None
        length = header.get("length")
        if not isinstance(length, int):
            raise RuntimeError("camera broker omitted image length")
        return header, _recv_exact(sock, length)
    finally:
        sock.close()


def list_cameras() -> list[dict]:
    header, _ = broker_request({"action": "list"}, timeout=8.0)
    cameras = header.get("cameras")
    if not isinstance(cameras, list):
        raise RuntimeError("camera broker returned an invalid camera list")
    return [item for item in cameras if isinstance(item, dict) and isinstance(item.get("name"), str)]


def cache_dir() -> Path:
    hermes_home = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
    target = Path(os.environ.get("CAMERA_CACHE_DIR", str(hermes_home / "cache" / "cameras")))
    target.mkdir(parents=True, exist_ok=True)
    os.chmod(target, 0o700)
    return target


def snapshot(camera: str) -> dict:
    if not NAME_RE.fullmatch(camera):
        raise ValueError("invalid camera name")
    header, image = broker_request({"action": "snapshot", "camera": camera}, expect_image=True)
    assert image is not None
    stamp = str(header.get("captured_at_utc") or "snapshot")
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
            header, _ = broker_request({"action": "check"}, timeout=8.0)
            return emit(header, 0 if header.get("ok") else 2)
        if args.command == "snapshot":
            return emit({"ok": True, **snapshot(args.camera)})
        if args.command == "snapshot-all":
            cameras = [item["name"] for item in list_cameras()]
            if not cameras:
                return emit({"ok": False, "error": "no configured cameras"}, 2)
            images, errors = [], []
            for camera in cameras:
                try:
                    images.append(snapshot(camera))
                except Exception as exc:
                    errors.append({"camera": camera, "error": str(exc)[:160]})
            return emit({"ok": bool(images), "images": images, "errors": errors}, 0 if images else 2)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError, socket.timeout) as exc:
        return emit({"ok": False, "error": str(exc)[:240]}, 2)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
