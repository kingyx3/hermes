#!/usr/bin/env python3
"""Pin WireGuard AllowedIPs to the first verified camera inventory.

The TP-Link export is retained as a root-only bootstrap file. After the first
successful Xiaomi discovery, exactly the expected number of camera IPs are
pinned and the runtime WireGuard config is rewritten to /32 routes. Later IP
drift fails closed until an operator explicitly re-pins after verification.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
from pathlib import Path

PRIVATE_V4 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)
ALLOWED_RE = re.compile(r"^(\s*AllowedIPs\s*=\s*)(.+?)\s*$", re.IGNORECASE)


def private_ip(value: str) -> ipaddress.IPv4Address:
    address = ipaddress.ip_address(value)
    if not isinstance(address, ipaddress.IPv4Address) or not any(address in net for net in PRIVATE_V4):
        raise ValueError(f"camera IP {value!r} is not RFC1918 IPv4")
    return address


def bootstrap_networks(text: str) -> list[ipaddress.IPv4Network]:
    matches = [ALLOWED_RE.match(line) for line in text.splitlines()]
    values = [match.group(2) for match in matches if match]
    if len(values) != 1:
        raise ValueError("bootstrap WireGuard config must contain exactly one AllowedIPs line")
    networks: list[ipaddress.IPv4Network] = []
    for item in values[0].split(","):
        network = ipaddress.ip_network(item.strip(), strict=False)
        if not isinstance(network, ipaddress.IPv4Network) or not any(network.subnet_of(p) for p in PRIVATE_V4):
            raise ValueError("bootstrap AllowedIPs must stay inside RFC1918 IPv4")
        networks.append(network)
    return networks


def inventory_ips(path: Path, expected_count: int, allowed: list[ipaddress.IPv4Network]) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    cameras = payload.get("cameras") if isinstance(payload, dict) else None
    if not isinstance(cameras, list):
        raise ValueError("camera inventory is invalid")
    addresses: list[ipaddress.IPv4Address] = []
    for item in cameras:
        if not isinstance(item, dict) or not isinstance(item.get("ip"), str):
            continue
        address = private_ip(item["ip"])
        if not any(address in network for network in allowed):
            raise ValueError(f"camera IP {address} is outside the TP-Link bootstrap routes")
        addresses.append(address)
    unique = sorted({str(address) for address in addresses}, key=lambda value: int(ipaddress.ip_address(value)))
    if unique and len(unique) != expected_count:
        raise ValueError(f"expected exactly {expected_count} unique cameras, discovered {len(unique)}")
    return unique


def render_runtime(bootstrap: str, ips: list[str]) -> str:
    replacement = ", ".join(f"{ip}/32" for ip in ips)
    count = 0
    output: list[str] = []
    for line in bootstrap.splitlines():
        match = ALLOWED_RE.match(line)
        if match:
            output.append(f"{match.group(1)}{replacement}")
            count += 1
        else:
            output.append(line)
    if count != 1:
        raise ValueError("bootstrap WireGuard config must contain exactly one AllowedIPs line")
    return "\n".join(output) + "\n"


def atomic_write(path: Path, content: str, mode: int = 0o600) -> bool:
    try:
        old = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        old = None
    if old == content:
        os.chmod(path, mode)
        return False
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap", type=Path, default=Path("/etc/wireguard/home.bootstrap.conf"))
    parser.add_argument("--runtime", type=Path, default=Path("/etc/wireguard/home.conf"))
    parser.add_argument("--inventory", type=Path, default=Path("/var/lib/go2rtc/cameras.json"))
    parser.add_argument("--pin", type=Path, default=Path("/etc/hermes-camera/camera-ips.json"))
    parser.add_argument("--changed-marker", type=Path, default=Path("/run/hermes-camera/routes.changed"))
    parser.add_argument("--expected-count", type=int, default=int(os.environ.get("CAMERA_EXPECTED_COUNT", "3")))
    parser.add_argument("--repin", action="store_true")
    args = parser.parse_args()

    try:
        if not 1 <= args.expected_count <= 16:
            raise ValueError("expected camera count must be between 1 and 16")
        bootstrap = args.bootstrap.read_text(encoding="utf-8")
        allowed = bootstrap_networks(bootstrap)

        pinned: list[str] | None = None
        if args.pin.exists():
            payload = json.loads(args.pin.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and isinstance(payload.get("camera_ips"), list):
                pinned = [str(private_ip(value)) for value in payload["camera_ips"] if isinstance(value, str)]
                pinned = sorted(set(pinned), key=lambda value: int(ipaddress.ip_address(value)))
                if len(pinned) != args.expected_count:
                    raise ValueError("pinned camera IP count does not match expected camera count")

        discovered: list[str] | None = None
        if args.inventory.exists():
            discovered = inventory_ips(args.inventory, args.expected_count, allowed)
            if not discovered:
                discovered = None

        if discovered is None and pinned is None:
            args.changed_marker.unlink(missing_ok=True)
            print(json.dumps({"ok": True, "configured": False, "reason": "camera inventory not pinned yet"}))
            return 0

        if discovered is not None:
            if pinned is not None and pinned != discovered and not args.repin:
                raise ValueError(
                    "camera IP drift detected; refusing to widen/change VPN routes until an operator verifies DHCP reservations and re-pins"
                )
            if pinned != discovered:
                args.pin.parent.mkdir(parents=True, exist_ok=True)
                atomic_write(args.pin, json.dumps({"camera_ips": discovered}, indent=2) + "\n")
                pinned = discovered

        assert pinned is not None
        changed = atomic_write(args.runtime, render_runtime(bootstrap, pinned))
        args.changed_marker.parent.mkdir(parents=True, exist_ok=True)
        if changed:
            args.changed_marker.write_text("changed\n", encoding="utf-8")
            os.chmod(args.changed_marker, 0o600)
        else:
            args.changed_marker.unlink(missing_ok=True)
        print(json.dumps({"ok": True, "camera_ips": pinned, "runtime_changed": changed}))
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        args.changed_marker.unlink(missing_ok=True)
        print(json.dumps({"ok": False, "error": str(exc)[:300]}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
