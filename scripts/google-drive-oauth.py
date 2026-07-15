#!/usr/bin/env python3
"""Dependency-free OAuth helper for Hermes' folder-bound Drive workspace."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

SCOPE = "https://www.googleapis.com/auth/drive.file"
REDIRECT_URI = "http://127.0.0.1:1"
AUTH_URI = "https://accounts.google.com/o/oauth2/auth"
TOKEN_URI = "https://oauth2.googleapis.com/token"
REVOKE_URI = "https://oauth2.googleapis.com/revoke"
DRIVE_API = "https://www.googleapis.com/drive/v3"


def fail(message: str, details: Any | None = None) -> "NoReturn":
    suffix = f": {json.dumps(details, ensure_ascii=False)}" if details is not None else ""
    print(f"ERROR: {message}{suffix}", file=os.sys.stderr)
    raise SystemExit(1)


def config_dir() -> Path:
    explicit = os.environ.get("HERMES_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser().resolve()
    home = os.environ.get("HERMES_HOME")
    if home:
        path = Path(home).expanduser().resolve()
        return path if path.name == ".hermes" else path / ".hermes"
    return Path.home() / ".hermes"


CONFIG_DIR = config_dir()
CLIENT_PATH = CONFIG_DIR / "google_client_secret.json"
TOKEN_PATH = CONFIG_DIR / "google_drive_token.json"
PENDING_PATH = CONFIG_DIR / "google_drive_oauth_pending.json"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing file: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"expected a JSON object in {path}")
    return value


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary.chmod(0o600)
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        temporary.unlink(missing_ok=True)


def client() -> dict[str, str]:
    installed = read_json(CLIENT_PATH).get("installed")
    if not isinstance(installed, dict):
        fail("OAuth credentials must be a Google Desktop app client")
    client_id = installed.get("client_id")
    client_secret = installed.get("client_secret")
    if not client_id or not client_secret:
        fail("OAuth Desktop client is missing client_id or client_secret")
    return {
        "client_id": str(client_id),
        "client_secret": str(client_secret),
        "auth_uri": str(installed.get("auth_uri") or AUTH_URI),
        "token_uri": str(installed.get("token_uri") or TOKEN_URI),
    }


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def post_form(url: str, values: dict[str, str]) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode("ascii"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return json.loads(raw.decode("utf-8")) if raw else {}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            details = json.loads(raw)
        except json.JSONDecodeError:
            details = raw
        fail(f"OAuth request failed with HTTP {exc.code}", details)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"OAuth request failed: {exc}")


def auth_url() -> None:
    cfg = client()
    verifier = b64url(secrets.token_bytes(48))
    state = b64url(secrets.token_bytes(24))
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    write_private_json(
        PENDING_PATH,
        {"state": state, "code_verifier": verifier, "created_at": datetime.now(timezone.utc).isoformat()},
    )
    query = urllib.parse.urlencode(
        {
            "client_id": cfg["client_id"],
            "redirect_uri": REDIRECT_URI,
            "response_type": "code",
            "scope": SCOPE,
            "access_type": "offline",
            "prompt": "consent",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
        }
    )
    print(f"{cfg['auth_uri']}?{query}")


def parse_callback(value: str) -> tuple[str, str | None, list[str] | None]:
    value = value.strip()
    if not value:
        fail("empty OAuth callback")
    if not value.startswith(("http://", "https://")):
        return value, None, None
    params = urllib.parse.parse_qs(urllib.parse.urlparse(value).query)
    if (params.get("error") or [None])[0]:
        fail(f"Google returned OAuth error: {(params.get('error') or [''])[0]}")
    code = (params.get("code") or [None])[0]
    if not code:
        fail("OAuth callback URL has no code parameter")
    state = (params.get("state") or [None])[0]
    scopes = ((params.get("scope") or [""])[0]).split() or None
    return str(code), state, scopes


def exchange_callback(callback: str) -> None:
    cfg = client()
    pending = read_json(PENDING_PATH)
    code, returned_state, returned_scopes = parse_callback(callback)
    if returned_state and returned_state != pending.get("state"):
        fail("OAuth state mismatch; generate a new authorization URL")
    result = post_form(
        cfg["token_uri"],
        {
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "code": code,
            "code_verifier": str(pending.get("code_verifier") or ""),
            "grant_type": "authorization_code",
            "redirect_uri": REDIRECT_URI,
        },
    )
    if not result.get("access_token") or not result.get("refresh_token"):
        fail("Drive OAuth exchange did not return access and refresh tokens", result)
    scopes = str(result.get("scope") or " ".join(returned_scopes or [SCOPE])).split()
    if SCOPE not in scopes:
        fail("Google did not grant the required drive.file scope", {"scopes": scopes})
    write_private_json(
        TOKEN_PATH,
        {
            "type": "authorized_user",
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "refresh_token": result["refresh_token"],
            "token": result["access_token"],
            "token_uri": cfg["token_uri"],
            "scopes": scopes,
            "expiry": (
                datetime.now(timezone.utc)
                + timedelta(seconds=int(result.get("expires_in") or 3600))
            ).isoformat(),
        },
    )
    PENDING_PATH.unlink(missing_ok=True)
    print("DRIVE_AUTHENTICATED")


def refresh(payload: dict[str, Any]) -> dict[str, Any]:
    result = post_form(
        str(payload.get("token_uri") or TOKEN_URI),
        {
            "client_id": str(payload.get("client_id") or ""),
            "client_secret": str(payload.get("client_secret") or ""),
            "refresh_token": str(payload.get("refresh_token") or ""),
            "grant_type": "refresh_token",
        },
    )
    token = result.get("access_token")
    if not token:
        fail("Drive token refresh returned no access_token", result)
    payload["token"] = token
    payload["expiry"] = (
        datetime.now(timezone.utc) + timedelta(seconds=int(result.get("expires_in") or 3600))
    ).isoformat()
    write_private_json(TOKEN_PATH, payload)
    return payload


def check() -> None:
    payload = refresh(read_json(TOKEN_PATH))
    request = urllib.request.Request(
        f"{DRIVE_API}/about?fields=user",
        headers={"Authorization": f"Bearer {payload['token']}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            about = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        fail(f"Drive live check failed with HTTP {exc.code}", exc.read().decode("utf-8", errors="replace"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Drive live check failed: {exc}")
    print(json.dumps({"authenticated": True, "scope": SCOPE, "user": about.get("user")}, ensure_ascii=False))


def revoke() -> None:
    if TOKEN_PATH.exists():
        token = read_json(TOKEN_PATH).get("refresh_token")
        if token:
            try:
                post_form(REVOKE_URI, {"token": str(token)})
            except SystemExit:
                print("WARNING: remote revocation failed", file=os.sys.stderr)
    TOKEN_PATH.unlink(missing_ok=True)
    PENDING_PATH.unlink(missing_ok=True)
    print("DRIVE_REVOKED")


def paths() -> None:
    print(json.dumps({"client": str(CLIENT_PATH), "token": str(TOKEN_PATH), "pending": str(PENDING_PATH), "scope": SCOPE, "redirect_uri": REDIRECT_URI}, indent=2))


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("auth-url")
    auth_code = commands.add_parser("auth-code")
    auth_code.add_argument("callback")
    commands.add_parser("auth-code-stdin")
    commands.add_parser("check")
    commands.add_parser("revoke")
    commands.add_parser("paths")
    return root


def main() -> None:
    args = parser().parse_args()
    if args.command == "auth-url":
        auth_url()
    elif args.command == "auth-code":
        exchange_callback(args.callback)
    elif args.command == "auth-code-stdin":
        exchange_callback(os.sys.stdin.read())
    elif args.command == "check":
        check()
    elif args.command == "revoke":
        revoke()
    elif args.command == "paths":
        paths()


if __name__ == "__main__":
    main()
