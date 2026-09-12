#!/usr/bin/env python3
"""Validate a TP-Link WireGuard client export and render a safe wg-quick config.

The router-generated file contains a client private key, so this program never
prints input values. It deliberately accepts only inert WireGuard directives and
rejects wg-quick command hooks or default-route AllowedIPs.
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import re
import sys
from pathlib import Path

SECTION_RE = re.compile(r"^\[(Interface|Peer)\]$")
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")

ALLOWED = {
    "Interface": {"PrivateKey", "Address", "MTU"},
    "Peer": {"PublicKey", "PresharedKey", "AllowedIPs", "Endpoint", "PersistentKeepalive"},
}
REQUIRED = {
    "Interface": {"PrivateKey", "Address"},
    "Peer": {"PublicKey", "AllowedIPs", "Endpoint"},
}
DROP = {"DNS", "ListenPort"}
DANGEROUS = {"PreUp", "PostUp", "PreDown", "PostDown", "Table", "SaveConfig"}
RFC1918 = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
)


def fail(message: str) -> "NoReturn":
    raise ValueError(message)


def parse_lines(text: str) -> list[tuple[str, list[tuple[str, str]]]]:
    sections: list[tuple[str, list[tuple[str, str]]]] = []
    current_name: str | None = None
    current_values: list[tuple[str, str]] | None = None

    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        match = SECTION_RE.fullmatch(line)
        if match:
            current_name = match.group(1)
            current_values = []
            sections.append((current_name, current_values))
            continue
        if current_name is None or current_values is None:
            fail(f"line {lineno}: setting outside [Interface]/[Peer]")
        if "=" not in line:
            fail(f"line {lineno}: expected KEY = VALUE")
        key, value = (part.strip() for part in line.split("=", 1))
        if not KEY_RE.fullmatch(key):
            fail(f"line {lineno}: invalid directive name")
        if key in DANGEROUS:
            fail(f"line {lineno}: wg-quick directive {key} is not permitted")
        if key in DROP:
            continue
        if key not in ALLOWED[current_name]:
            fail(f"line {lineno}: unsupported {current_name} directive {key}")
        if not value or "\x00" in value or "\r" in value or "\n" in value:
            fail(f"line {lineno}: invalid value for {key}")
        current_values.append((key, value))

    interfaces = [values for name, values in sections if name == "Interface"]
    peers = [values for name, values in sections if name == "Peer"]
    if len(interfaces) != 1:
        fail("configuration must contain exactly one [Interface] section")
    if len(peers) != 1:
        fail("configuration must contain exactly one [Peer] section")
    return sections


def validate(sections: list[tuple[str, list[tuple[str, str]]]]) -> None:
    for section_name, values in sections:
        present = {key for key, _ in values}
        missing = REQUIRED[section_name] - present
        if missing:
            fail(f"{section_name} is missing required directives: {', '.join(sorted(missing))}")

        for key, value in values:
            if key == "AllowedIPs":
                networks = []
                for item in value.split(","):
                    item = item.strip()
                    try:
                        network = ipaddress.ip_network(item, strict=False)
                    except ValueError as exc:
                        fail(f"invalid AllowedIPs entry {item!r}: {exc}")
                    if network.prefixlen == 0:
                        fail("default-route AllowedIPs (0.0.0.0/0 or ::/0) are forbidden; choose Home Network Only on TP-Link")
                    if network.version != 4 or not any(network.subnet_of(private) for private in RFC1918):
                        fail(
                            f"AllowedIPs entry {item!r} is not an RFC1918 private network; "
                            "the TP-Link peer must be Home Network Only"
                        )
                    networks.append(network)
                if not networks:
                    fail("AllowedIPs must not be empty")
            elif key == "Address":
                for item in value.split(","):
                    try:
                        ipaddress.ip_interface(item.strip())
                    except ValueError as exc:
                        fail(f"invalid WireGuard interface Address: {exc}")
            elif key == "Endpoint":
                if any(ch.isspace() for ch in value) or ":" not in value:
                    fail("Endpoint must be host:port without whitespace")
            elif key == "PersistentKeepalive":
                try:
                    keepalive = int(value)
                except ValueError:
                    fail("PersistentKeepalive must be an integer")
                if not 0 <= keepalive <= 65535:
                    fail("PersistentKeepalive is outside the valid range")
            elif key == "MTU":
                try:
                    mtu = int(value)
                except ValueError:
                    fail("MTU must be an integer")
                if not 576 <= mtu <= 9000:
                    fail("MTU is outside the accepted range")


def render(sections: list[tuple[str, list[tuple[str, str]]]]) -> str:
    out = ["# Sanitized by hermes camera runtime. Do not edit here."]
    for section_name, values in sections:
        out.append(f"[{section_name}]")
        for key, value in values:
            out.append(f"{key} = {value}")
        if section_name == "Peer" and not any(key == "PersistentKeepalive" for key, _ in values):
            out.append("PersistentKeepalive = 25")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    try:
        text = args.input.read_text(encoding="utf-8")
        sections = parse_lines(text)
        validate(sections)
        safe = render(sections)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(safe)
        os.chmod(args.output, 0o600)
    except (OSError, ValueError) as exc:
        print(f"sanitize-wireguard: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
