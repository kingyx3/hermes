#!/usr/bin/env python3
"""Discover Xiaomi cameras through go2rtc's private Unix API and render safe state."""
from __future__ import annotations

import argparse
import http.client
import ipaddress
import json
import os
import re
import socket
import urllib.parse
from pathlib import Path

GO2RTC_SOCKET = os.environ.get("GO2RTC_API_SOCKET", "/run/go2rtc/api.sock")
USER_AGENT = "hermes-camera-refresh/2"


class SetupRequired(RuntimeError):
    pass


PRIVATE_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, socket_path: str, timeout: float):
        super().__init__("localhost", timeout=timeout)
        self.socket_path = socket_path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.socket_path)
        self.sock = sock


def get_json(path: str, timeout: float = 12.0):
    conn = UnixHTTPConnection(GO2RTC_SOCKET, timeout)
    try:
        conn.request("GET", path, headers={"User-Agent": USER_AGENT})
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(f"go2rtc returned HTTP {response.status}")
        body = response.read(1024 * 1024 + 1)
        if len(body) > 1024 * 1024:
            raise RuntimeError("go2rtc discovery response exceeded safety limit")
        return json.loads(body)
    finally:
        conn.close()


def slugify(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[^a-z0-9]+", "_", value).strip("_")
    return value or "camera"


def validate_source_url(source_url: str) -> str:
    parsed = urllib.parse.urlsplit(source_url)
    if parsed.scheme != "xiaomi":
        raise ValueError("unexpected non-Xiaomi source")
    if not parsed.hostname:
        raise ValueError("Xiaomi source has no camera IP")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise ValueError("Xiaomi camera source must use an IP address") from exc
    if address.version != 4 or not any(address in network for network in PRIVATE_V4):
        raise ValueError("refusing Xiaomi source whose camera IP is not RFC1918 private")
    return source_url


def build_streams(sources: list[dict]) -> tuple[dict, list[dict]]:
    streams: dict[str, str] = {}
    cameras: list[dict] = []
    used: set[str] = set()

    for source in sources:
        if not isinstance(source, dict):
            continue
        source_url = source.get("url")
        if not isinstance(source_url, str):
            continue
        try:
            source_url = validate_source_url(source_url)
        except ValueError:
            continue

        display = str(source.get("name") or "camera").strip() or "camera"
        parsed = urllib.parse.urlsplit(source_url)
        query = urllib.parse.parse_qs(parsed.query)
        did = (query.get("did") or [""])[0]
        model = (query.get("model") or [""])[0]
        base = slugify(display)
        name = base
        if name in used:
            suffix = re.sub(r"[^0-9A-Za-z]", "", did)[-6:] or str(len(used) + 1)
            name = f"{base}_{suffix.lower()}"
        while name in used:
            name += "_2"
        used.add(name)

        streams[name] = source_url
        cameras.append({
            "name": name,
            "display_name": display,
            "ip": parsed.hostname,
            "did": did,
            "model": model,
        })

    return streams, cameras


def discover(region: str) -> tuple[dict, list[dict]]:
    users = get_json("/api/xiaomi")
    if not isinstance(users, list) or not users:
        raise SetupRequired("Xiaomi authorization is not configured in go2rtc")

    all_sources: list[dict] = []
    for user_id in users:
        if not isinstance(user_id, str) or not user_id.isdigit():
            continue
        query = urllib.parse.urlencode({"id": user_id, "region": region})
        result = get_json("/api/xiaomi?" + query, timeout=20.0)
        if isinstance(result, dict) and isinstance(result.get("sources"), list):
            result = result["sources"]
        if isinstance(result, list):
            all_sources.extend(item for item in result if isinstance(item, dict))

    streams, cameras = build_streams(all_sources)
    if not cameras:
        raise RuntimeError(f"no Xiaomi cameras discovered in region {region!r}")
    return streams, cameras


def atomic_write_json(path: Path, payload: dict, mode: int = 0o640) -> bool:
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    try:
        old = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        old = None
    if old == rendered:
        return False
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(rendered, encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--region", default=os.environ.get("XIAOMI_REGION", "sg"))
    parser.add_argument("--streams", type=Path, default=Path("/var/lib/go2rtc/streams.json"))
    parser.add_argument("--inventory", type=Path, default=Path("/var/lib/go2rtc/cameras.json"))
    parser.add_argument("--changed-marker", type=Path, default=Path("/var/lib/go2rtc/.refresh_changed"))
    args = parser.parse_args()

    try:
        streams, cameras = discover(args.region)
        changed_streams = atomic_write_json(args.streams, {"streams": streams})
        changed_inventory = atomic_write_json(args.inventory, {"cameras": cameras, "region": args.region})
        if changed_streams:
            args.changed_marker.write_text("changed\n", encoding="utf-8")
            os.chmod(args.changed_marker, 0o600)
        else:
            args.changed_marker.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "camera_count": len(cameras), "changed": changed_streams or changed_inventory}))
        return 0
    except SetupRequired as exc:
        args.changed_marker.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "setup_required": True, "reason": str(exc)}))
        return 0
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        args.changed_marker.unlink(missing_ok=True)
        print(json.dumps({"ok": False, "error": str(exc)[:240]}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
