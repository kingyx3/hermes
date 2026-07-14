#!/usr/bin/env python3
"""Least-privilege Gmail + Google Calendar OAuth helper for Hermes.

The helper is designed for a headless VM. It creates a PKCE authorization URL,
accepts the final loopback redirect URL via stdin, and stores the resulting
Google authorized-user token in the location expected by Hermes' bundled
Google Workspace skill.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCOPES = (
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar.events",
)
REDIRECT_URI = "http://127.0.0.1:1"
REQUIRED_PACKAGES = (
    "google-api-python-client",
    "google-auth-oauthlib",
    "google-auth-httplib2",
)


def config_dir() -> Path:
    explicit = os.environ.get("HERMES_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser().resolve()

    hermes_home = os.environ.get("HERMES_HOME")
    if hermes_home:
        candidate = Path(hermes_home).expanduser().resolve()
        return candidate if candidate.name == ".hermes" else candidate / ".hermes"

    return Path.home() / ".hermes"


CONFIG_DIR = config_dir()
CLIENT_SECRET_PATH = CONFIG_DIR / "google_client_secret.json"
TOKEN_PATH = CONFIG_DIR / "google_token.json"
PENDING_PATH = CONFIG_DIR / "google_oauth_pending.json"


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.parent.chmod(0o700)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
        temporary_path.chmod(0o600)
        os.replace(temporary_path, path)
        path.chmod(0o600)
    finally:
        temporary_path.unlink(missing_ok=True)


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"missing file: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not read {path}: {exc}")
    if not isinstance(data, dict):
        fail(f"expected a JSON object in {path}")
    return data


def validate_client_secret() -> None:
    payload = load_json(CLIENT_SECRET_PATH)
    installed = payload.get("installed")
    if not isinstance(installed, dict):
        fail("OAuth credentials must be a Google Desktop app client (missing 'installed')")
    if not installed.get("client_id") or not installed.get("client_secret"):
        fail("OAuth Desktop app JSON is missing client_id or client_secret")


def dependencies_available() -> bool:
    try:
        import googleapiclient.discovery  # noqa: F401
        import google_auth_oauthlib.flow  # noqa: F401
        import google.auth.transport.requests  # noqa: F401
    except ImportError:
        return False
    return True


def install_dependencies() -> None:
    if dependencies_available():
        print("DEPENDENCIES_OK")
        return

    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "--version"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        subprocess.run(
            [sys.executable, "-m", "ensurepip", "--upgrade"],
            check=True,
            stdout=subprocess.DEVNULL,
        )

    subprocess.run(
        [sys.executable, "-m", "pip", "install", "--quiet", *REQUIRED_PACKAGES],
        check=True,
    )
    if not dependencies_available():
        fail("Google API dependencies were installed but cannot be imported")
    print("DEPENDENCIES_INSTALLED")


def ensure_dependencies() -> None:
    if not dependencies_available():
        fail("Google API dependencies are missing; run the provision-client workflow action")


def authorization_url() -> None:
    validate_client_secret()
    ensure_dependencies()

    from google_auth_oauthlib.flow import Flow

    flow = Flow.from_client_secrets_file(
        str(CLIENT_SECRET_PATH),
        scopes=list(SCOPES),
        redirect_uri=REDIRECT_URI,
        autogenerate_code_verifier=True,
    )
    url, state = flow.authorization_url(access_type="offline", prompt="consent")
    if not flow.code_verifier:
        fail("OAuth library did not generate a PKCE verifier")

    write_private_json(
        PENDING_PATH,
        {
            "state": state,
            "code_verifier": flow.code_verifier,
            "redirect_uri": REDIRECT_URI,
            "scopes": list(SCOPES),
            "created_at": datetime.now(timezone.utc).isoformat(),
        },
    )
    print(url)


def extract_code_and_state(value: str) -> tuple[str, str | None, list[str] | None]:
    value = value.strip()
    if not value:
        fail("empty OAuth callback")

    if not value.startswith(("http://", "https://")):
        return value, None, None

    parsed = urllib.parse.urlparse(value)
    params = urllib.parse.parse_qs(parsed.query)
    error = (params.get("error") or [None])[0]
    if error:
        fail(f"Google returned OAuth error: {error}")
    code = (params.get("code") or [None])[0]
    if not code:
        fail("OAuth callback URL has no code parameter")
    state = (params.get("state") or [None])[0]
    scope_text = (params.get("scope") or [""])[0].strip()
    scopes = scope_text.split() if scope_text else None
    return code, state, scopes


def exchange_callback(callback: str) -> None:
    validate_client_secret()
    ensure_dependencies()
    pending = load_json(PENDING_PATH)

    expected_state = pending.get("state")
    verifier = pending.get("code_verifier")
    redirect_uri = pending.get("redirect_uri") or REDIRECT_URI
    requested_scopes = pending.get("scopes") or list(SCOPES)
    if not expected_state or not verifier:
        fail("pending OAuth session is incomplete; generate a new authorization URL")

    code, returned_state, returned_scopes = extract_code_and_state(callback)
    if returned_state and returned_state != expected_state:
        fail("OAuth state mismatch; generate a new authorization URL")

    from google_auth_oauthlib.flow import Flow

    granted_scopes = returned_scopes or requested_scopes
    flow = Flow.from_client_secrets_file(
        str(CLIENT_SECRET_PATH),
        scopes=granted_scopes,
        redirect_uri=redirect_uri,
        state=expected_state,
        code_verifier=verifier,
    )
    os.environ["OAUTHLIB_RELAX_TOKEN_SCOPE"] = "1"
    try:
        flow.fetch_token(code=code)
    except Exception as exc:  # google-auth raises several provider-specific types
        fail(f"token exchange failed: {exc}")

    credentials = flow.credentials
    payload = json.loads(credentials.to_json())
    payload["type"] = "authorized_user"
    actual_scopes = list(getattr(credentials, "granted_scopes", None) or granted_scopes)
    payload["scopes"] = actual_scopes

    missing = sorted(set(SCOPES) - set(actual_scopes))
    if missing:
        fail("Google did not grant all required Gmail and Calendar scopes")

    write_private_json(TOKEN_PATH, payload)
    PENDING_PATH.unlink(missing_ok=True)
    print("AUTHENTICATED")


def load_credentials():
    ensure_dependencies()
    if not TOKEN_PATH.exists():
        fail("not authenticated; generate an authorization URL first")

    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials

    try:
        credentials = Credentials.from_authorized_user_file(str(TOKEN_PATH))
    except Exception as exc:
        fail(f"could not load token: {exc}")

    if credentials.expired and credentials.refresh_token:
        try:
            credentials.refresh(Request())
        except Exception as exc:
            fail(f"token refresh failed: {exc}")
        payload = json.loads(credentials.to_json())
        payload["type"] = "authorized_user"
        payload["scopes"] = list(credentials.scopes or SCOPES)
        write_private_json(TOKEN_PATH, payload)

    if not credentials.valid:
        fail("stored Google token is invalid; re-authorize")
    return credentials


def check_live() -> None:
    credentials = load_credentials()
    from googleapiclient.discovery import build

    try:
        build("gmail", "v1", credentials=credentials, cache_discovery=False).users().getProfile(
            userId="me"
        ).execute()
        build("calendar", "v3", credentials=credentials, cache_discovery=False).events().list(
            calendarId="primary",
            maxResults=1,
            singleEvents=True,
            timeMin=datetime.now(timezone.utc).isoformat(),
        ).execute()
    except Exception as exc:
        fail(f"live Gmail/Calendar check failed: {exc}")

    print("AUTHENTICATED: Gmail and Calendar API checks passed")


def revoke() -> None:
    if not TOKEN_PATH.exists():
        PENDING_PATH.unlink(missing_ok=True)
        print("NOT_AUTHENTICATED")
        return

    payload = load_json(TOKEN_PATH)
    token = payload.get("refresh_token") or payload.get("token")
    if token:
        request = urllib.request.Request(
            "https://oauth2.googleapis.com/revoke",
            data=urllib.parse.urlencode({"token": token}).encode("ascii"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=20):
                pass
        except Exception as exc:
            print(f"WARNING: remote revocation failed: {exc}", file=sys.stderr)

    TOKEN_PATH.unlink(missing_ok=True)
    PENDING_PATH.unlink(missing_ok=True)
    print("REVOKED")


def show_paths() -> None:
    print(
        json.dumps(
            {
                "config_dir": str(CONFIG_DIR),
                "client_secret": str(CLIENT_SECRET_PATH),
                "token": str(TOKEN_PATH),
                "pending": str(PENDING_PATH),
                "redirect_uri": REDIRECT_URI,
                "scopes": list(SCOPES),
            },
            indent=2,
        )
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("install-deps", help="Install Google API packages in this interpreter")
    subparsers.add_parser("auth-url", help="Create and print a PKCE authorization URL")
    auth_code = subparsers.add_parser("auth-code", help="Exchange a callback URL or code")
    auth_code.add_argument("callback")
    subparsers.add_parser("auth-code-stdin", help="Read callback URL or code from standard input")
    subparsers.add_parser("check", help="Refresh the token and test Gmail and Calendar")
    subparsers.add_parser("revoke", help="Revoke and delete the stored token")
    subparsers.add_parser("paths", help="Print configured paths and requested scopes")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "install-deps":
        install_dependencies()
    elif args.command == "auth-url":
        authorization_url()
    elif args.command == "auth-code":
        exchange_callback(args.callback)
    elif args.command == "auth-code-stdin":
        exchange_callback(sys.stdin.read())
    elif args.command == "check":
        check_live()
    elif args.command == "revoke":
        revoke()
    elif args.command == "paths":
        show_paths()


if __name__ == "__main__":
    main()
