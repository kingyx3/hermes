#!/usr/bin/env python3
"""Dependency-free Google Drive, Docs, and Sheets CLI for Hermes.

Previously restricted to direct children of one app-owned Drive folder named
"hermes", the client now supports every descendant while validating the full
parent chain back to that managed root. The CLI uses only Python's standard
library.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

DRIVE_API = "https://www.googleapis.com/drive/v3"
DOCS_API = "https://docs.googleapis.com/v1"
SHEETS_API = "https://sheets.googleapis.com/v4"
TOKEN_URI = "https://oauth2.googleapis.com/token"
FOLDER_NAME = "hermes"
FOLDER_MIME = "application/vnd.google-apps.folder"
DOC_MIME = "application/vnd.google-apps.document"
SHEET_MIME = "application/vnd.google-apps.spreadsheet"
MANAGED_KEY = "hermesWorkspace"
MANAGED_VALUE = "v1"
MAX_ANCESTRY_DEPTH = 100
FILE_FIELDS = "id,name,mimeType,parents,trashed,webViewLink,appProperties,modifiedTime,size"


def fail(message: str, *, details: Any | None = None) -> "NoReturn":
    payload: dict[str, Any] = {"error": message}
    if details is not None:
        payload["details"] = details
    print(json.dumps(payload, ensure_ascii=False), file=os.sys.stderr)
    raise SystemExit(1)


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
TOKEN_PATH = CONFIG_DIR / "google_drive_token.json"
STATE_PATH = CONFIG_DIR / "google_drive_workspace.json"


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"Missing file: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Could not read {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"Expected a JSON object in {path}")
    return value


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


def parse_expiry(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def token_is_fresh(payload: dict[str, Any]) -> bool:
    expiry = parse_expiry(payload.get("expiry"))
    return bool(
        payload.get("token")
        and expiry
        and expiry > datetime.now(timezone.utc) + timedelta(seconds=60)
    )


def refresh_token(payload: dict[str, Any]) -> dict[str, Any]:
    required = ("refresh_token", "client_id", "client_secret")
    missing = [name for name in required if not payload.get(name)]
    if missing:
        fail("Stored Drive token cannot be refreshed", details={"missing": missing})
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": payload["refresh_token"],
            "client_id": payload["client_id"],
            "client_secret": payload["client_secret"],
        }
    ).encode("ascii")
    request = urllib.request.Request(
        str(payload.get("token_uri") or TOKEN_URI),
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            details = json.loads(raw)
        except json.JSONDecodeError:
            details = raw
        fail("Google Drive token refresh failed", details=details)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Google Drive token refresh failed: {exc}")
    token = result.get("access_token")
    if not token:
        fail("Drive token refresh returned no access_token", details=result)
    payload["token"] = token
    payload["expiry"] = (
        datetime.now(timezone.utc)
        + timedelta(seconds=int(result.get("expires_in") or 3600))
    ).isoformat()
    if result.get("scope"):
        payload["scopes"] = str(result["scope"]).split()
    write_private_json(TOKEN_PATH, payload)
    return payload


def access_token(*, force_refresh: bool = False) -> str:
    payload = read_json(TOKEN_PATH)
    if force_refresh or not token_is_fresh(payload):
        payload = refresh_token(payload)
    token = payload.get("token")
    if not token:
        fail("Stored Drive token has no access token")
    return str(token)


def api_request(
    method: str,
    url: str,
    *,
    query: dict[str, Any] | None = None,
    body: dict[str, Any] | None = None,
    retry_auth: bool = True,
) -> Any:
    original_url = url
    if query:
        url = f"{url}?{urllib.parse.urlencode(query, doseq=True)}"
    data = None
    headers = {
        "Authorization": f"Bearer {access_token()}",
        "Accept": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            return json.loads(raw.decode("utf-8")) if raw else None
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        if exc.code == 401 and retry_auth:
            refresh_token(read_json(TOKEN_PATH))
            return api_request(
                method,
                original_url,
                query=query,
                body=body,
                retry_auth=False,
            )
        try:
            details = json.loads(raw)
        except json.JSONDecodeError:
            details = raw
        fail(f"Google API request failed with HTTP {exc.code}", details=details)
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"Google API request failed: {exc}")


def output(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def drive_file(file_id: str, *, fields: str = FILE_FIELDS) -> dict[str, Any]:
    encoded = urllib.parse.quote(file_id, safe="")
    result = api_request(
        "GET",
        f"{DRIVE_API}/files/{encoded}",
        query={"fields": fields, "supportsAllDrives": "false"},
    )
    if not isinstance(result, dict):
        fail("Drive returned invalid file metadata")
    return result


def save_workspace(folder: dict[str, Any]) -> None:
    write_private_json(
        STATE_PATH,
        {
            "folder_id": folder["id"],
            "folder_name": FOLDER_NAME,
            "managed_key": MANAGED_KEY,
            "managed_value": MANAGED_VALUE,
            "webViewLink": folder.get("webViewLink"),
        },
    )


def validate_folder(folder: dict[str, Any]) -> dict[str, Any]:
    if folder.get("mimeType") != FOLDER_MIME:
        fail("Configured Drive workspace is not a folder")
    if folder.get("trashed"):
        fail("Configured Drive workspace folder is trashed")
    props = folder.get("appProperties") or {}
    if props.get(MANAGED_KEY) != MANAGED_VALUE:
        fail("Configured Drive folder is not owned by the Hermes workspace")
    if folder.get("name") != FOLDER_NAME:
        fail("Configured Drive workspace folder was renamed", details={"name": folder.get("name")})
    return folder


def find_managed_folder() -> dict[str, Any] | None:
    q = (
        f"mimeType='{FOLDER_MIME}' and trashed=false and "
        f"appProperties has {{ key='{MANAGED_KEY}' and value='{MANAGED_VALUE}' }}"
    )
    result = api_request(
        "GET",
        f"{DRIVE_API}/files",
        query={
            "q": q,
            "spaces": "drive",
            "pageSize": 10,
            "fields": f"files({FILE_FIELDS})",
        },
    )
    files = result.get("files") or []
    for item in files:
        if item.get("name") == FOLDER_NAME:
            return validate_folder(item)
    return None


def ensure_workspace() -> dict[str, Any]:
    if STATE_PATH.exists():
        state = read_json(STATE_PATH)
        folder_id = str(state.get("folder_id") or "")
        if folder_id:
            try:
                folder = drive_file(folder_id)
                validate_folder(folder)
                return folder
            except SystemExit:
                pass
    folder = find_managed_folder()
    if folder is None:
        folder = api_request(
            "POST",
            f"{DRIVE_API}/files",
            query={"fields": FILE_FIELDS},
            body={
                "name": FOLDER_NAME,
                "mimeType": FOLDER_MIME,
                "appProperties": {MANAGED_KEY: MANAGED_VALUE},
            },
        )
        validate_folder(folder)
    save_workspace(folder)
    return folder


def single_parent_id(item: dict[str, Any]) -> str:
    parents = [str(value) for value in (item.get("parents") or []) if value]
    if len(parents) != 1:
        fail(
            "Managed Drive items must have exactly one parent",
            details={"fileId": item.get("id"), "parents": parents},
        )
    return parents[0]


def managed_lineage(
    file_id: str,
    *,
    item: dict[str, Any] | None = None,
    root: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    root = root or ensure_workspace()
    root_id = str(root["id"])
    if file_id == root_id:
        return [root]

    current = item or drive_file(file_id)
    lineage = [current]
    seen = {str(current.get("id") or file_id)}

    for _ in range(MAX_ANCESTRY_DEPTH):
        if current.get("trashed"):
            fail("File or ancestor folder is trashed", details={"fileId": current.get("id")})
        parent_id = single_parent_id(current)
        if parent_id == root_id:
            lineage.append(root)
            return lineage
        if parent_id in seen:
            fail("Drive folder ancestry contains a cycle", details={"fileId": file_id})
        seen.add(parent_id)
        parent = drive_file(parent_id)
        if parent.get("mimeType") != FOLDER_MIME:
            fail(
                "Drive ancestry contains a non-folder parent",
                details={"fileId": file_id, "parentId": parent_id},
            )
        lineage.append(parent)
        current = parent

    fail(
        "Drive folder ancestry is too deep",
        details={"fileId": file_id, "maxDepth": MAX_ANCESTRY_DEPTH},
    )


def managed_file(
    file_id: str,
    *,
    expected_mime: str | None = None,
    allow_root: bool = False,
) -> dict[str, Any]:
    root = ensure_workspace()
    if file_id == str(root["id"]):
        if not allow_root:
            fail("Refusing to modify the managed hermes root folder")
        item = root
    else:
        item = drive_file(file_id)
        managed_lineage(file_id, item=item, root=root)
    if item.get("trashed"):
        fail("File is trashed")
    if expected_mime and item.get("mimeType") != expected_mime:
        fail(
            "File has the wrong Google Workspace type",
            details={"expected": expected_mime, "actual": item.get("mimeType")},
        )
    return item


def managed_folder(folder_id: str | None) -> dict[str, Any]:
    root = ensure_workspace()
    if not folder_id or folder_id == str(root["id"]):
        return root
    return managed_file(folder_id, expected_mime=FOLDER_MIME)


def create_managed_file(
    name: str,
    mime_type: str,
    *,
    parent_id: str | None = None,
) -> dict[str, Any]:
    parent = managed_folder(parent_id)
    result = api_request(
        "POST",
        f"{DRIVE_API}/files",
        query={"fields": FILE_FIELDS},
        body={
            "name": name,
            "mimeType": mime_type,
            "parents": [parent["id"]],
            "appProperties": {MANAGED_KEY: MANAGED_VALUE},
        },
    )
    return managed_file(str(result["id"]), expected_mime=mime_type)


def list_children(parent_id: str, *, max_results: int = 100) -> list[dict[str, Any]]:
    limit = max(1, min(int(max_results), 1000))
    files: list[dict[str, Any]] = []
    page_token: str | None = None
    while len(files) < limit:
        query: dict[str, Any] = {
            "q": f"'{parent_id}' in parents and trashed=false",
            "spaces": "drive",
            "orderBy": "folder,name",
            "pageSize": min(1000, limit - len(files)),
            "fields": f"nextPageToken,files({FILE_FIELDS})",
        }
        if page_token:
            query["pageToken"] = page_token
        result = api_request("GET", f"{DRIVE_API}/files", query=query)
        batch = result.get("files") or []
        files.extend(batch)
        page_token = result.get("nextPageToken")
        if not page_token or not batch:
            break
    return files[:limit]


def workspace_ensure(_: argparse.Namespace) -> None:
    output(ensure_workspace())


def workspace_status(_: argparse.Namespace) -> None:
    folder = ensure_workspace()
    children = list_children(str(folder["id"]), max_results=1)
    output(
        {
            "ready": True,
            "folder": folder,
            "boundary": "managed-descendants-only",
            "driveReachable": isinstance(children, list),
        }
    )


def drive_list(args: argparse.Namespace) -> None:
    parent = managed_folder(args.parent_id)
    output(list_children(str(parent["id"]), max_results=args.max_results))


def drive_tree(args: argparse.Namespace) -> None:
    root = ensure_workspace()
    limit = max(1, min(int(args.max_results), 1000))
    queue: deque[tuple[str, str]] = deque([(str(root["id"]), FOLDER_NAME)])
    items: list[dict[str, Any]] = []
    seen_folders = {str(root["id"])}

    while queue and len(items) < limit:
        parent_id, parent_path = queue.popleft()
        for child in list_children(parent_id, max_results=limit - len(items)):
            child_id = str(child.get("id") or "")
            child_path = f"{parent_path}/{child.get('name') or child_id}"
            enriched = dict(child)
            enriched["path"] = child_path
            items.append(enriched)
            if child.get("mimeType") == FOLDER_MIME and child_id:
                if child_id in seen_folders:
                    fail("Drive folder tree contains a cycle", details={"folderId": child_id})
                seen_folders.add(child_id)
                queue.append((child_id, child_path))
            if len(items) >= limit:
                break

    output({"root": root, "items": items, "truncated": bool(queue)})


def drive_get(args: argparse.Namespace) -> None:
    item = managed_file(args.file_id)
    lineage = managed_lineage(args.file_id, item=item)
    names = [str(entry.get("name") or entry.get("id")) for entry in reversed(lineage)]
    output({"file": item, "path": "/".join(names)})


def drive_mkdir(args: argparse.Namespace) -> None:
    output(create_managed_file(args.name, FOLDER_MIME, parent_id=args.parent_id))


def drive_rename(args: argparse.Namespace) -> None:
    managed_file(args.file_id)
    encoded = urllib.parse.quote(args.file_id, safe="")
    result = api_request(
        "PATCH",
        f"{DRIVE_API}/files/{encoded}",
        query={"fields": FILE_FIELDS},
        body={"name": args.name},
    )
    output(result)


def drive_move(args: argparse.Namespace) -> None:
    item = managed_file(args.file_id)
    target = managed_folder(args.parent_id)
    target_lineage = managed_lineage(str(target["id"]), item=target)
    if item.get("mimeType") == FOLDER_MIME and str(item["id"]) in {
        str(entry.get("id")) for entry in target_lineage
    }:
        fail(
            "Refusing to move a folder into itself or one of its descendants",
            details={"folderId": item["id"], "targetParentId": target["id"]},
        )

    old_parent = single_parent_id(item)
    if old_parent == str(target["id"]):
        output(item)
        return

    encoded = urllib.parse.quote(args.file_id, safe="")
    result = api_request(
        "PATCH",
        f"{DRIVE_API}/files/{encoded}",
        query={
            "addParents": str(target["id"]),
            "removeParents": old_parent,
            "fields": FILE_FIELDS,
        },
        body={},
    )
    output(managed_file(str(result["id"])))


def drive_trash(args: argparse.Namespace) -> None:
    managed_file(args.file_id)
    encoded = urllib.parse.quote(args.file_id, safe="")
    result = api_request(
        "PATCH",
        f"{DRIVE_API}/files/{encoded}",
        query={"fields": "id,name,mimeType,trashed"},
        body={"trashed": True},
    )
    output(result)


def document_text(document: dict[str, Any]) -> str:
    parts: list[str] = []
    for block in ((document.get("body") or {}).get("content") or []):
        paragraph = block.get("paragraph")
        if paragraph:
            for element in paragraph.get("elements") or []:
                run = element.get("textRun") or {}
                if run.get("content"):
                    parts.append(str(run["content"]))
        table = block.get("table")
        if table:
            for row in table.get("tableRows") or []:
                cells: list[str] = []
                for cell in row.get("tableCells") or []:
                    cell_parts: list[str] = []
                    for content in cell.get("content") or []:
                        for element in ((content.get("paragraph") or {}).get("elements") or []):
                            text = (element.get("textRun") or {}).get("content")
                            if text:
                                cell_parts.append(str(text).strip())
                    cells.append(" ".join(part for part in cell_parts if part))
                parts.append("\t".join(cells) + "\n")
    return "".join(parts).strip()


def docs_create(args: argparse.Namespace) -> None:
    item = create_managed_file(args.title, DOC_MIME, parent_id=args.parent_id)
    if args.text:
        encoded = urllib.parse.quote(str(item["id"]), safe="")
        api_request(
            "POST",
            f"{DOCS_API}/documents/{encoded}:batchUpdate",
            body={"requests": [{"insertText": {"location": {"index": 1}, "text": args.text}}]},
        )
    output(item)


def docs_get(args: argparse.Namespace) -> None:
    item = managed_file(args.file_id, expected_mime=DOC_MIME)
    encoded = urllib.parse.quote(args.file_id, safe="")
    doc = api_request("GET", f"{DOCS_API}/documents/{encoded}")
    output({"file": item, "title": doc.get("title"), "text": document_text(doc)})


def docs_append(args: argparse.Namespace) -> None:
    managed_file(args.file_id, expected_mime=DOC_MIME)
    encoded = urllib.parse.quote(args.file_id, safe="")
    doc = api_request("GET", f"{DOCS_API}/documents/{encoded}")
    content = ((doc.get("body") or {}).get("content") or [])
    end_index = max((int(block.get("endIndex") or 1) for block in content), default=1)
    result = api_request(
        "POST",
        f"{DOCS_API}/documents/{encoded}:batchUpdate",
        body={
            "requests": [
                {
                    "insertText": {
                        "location": {"index": max(1, end_index - 1)},
                        "text": args.text,
                    }
                }
            ]
        },
    )
    output(result)


def parse_values(value: str) -> list[list[Any]]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        fail(f"--values-json must be valid JSON: {exc}")
    if not isinstance(parsed, list) or any(not isinstance(row, list) for row in parsed):
        fail("--values-json must be a JSON array of row arrays")
    return parsed


def sheets_create(args: argparse.Namespace) -> None:
    item = create_managed_file(args.title, SHEET_MIME, parent_id=args.parent_id)
    if args.values_json:
        values = parse_values(args.values_json)
        encoded_id = urllib.parse.quote(str(item["id"]), safe="")
        encoded_range = urllib.parse.quote(args.range, safe="")
        api_request(
            "PUT",
            f"{SHEETS_API}/spreadsheets/{encoded_id}/values/{encoded_range}",
            query={"valueInputOption": "USER_ENTERED"},
            body={"range": args.range, "majorDimension": "ROWS", "values": values},
        )
    output(item)


def sheets_get(args: argparse.Namespace) -> None:
    item = managed_file(args.file_id, expected_mime=SHEET_MIME)
    encoded_id = urllib.parse.quote(args.file_id, safe="")
    encoded_range = urllib.parse.quote(args.range, safe="")
    result = api_request(
        "GET",
        f"{SHEETS_API}/spreadsheets/{encoded_id}/values/{encoded_range}",
    )
    output({"file": item, "values": result})


def sheets_update(args: argparse.Namespace) -> None:
    managed_file(args.file_id, expected_mime=SHEET_MIME)
    values = parse_values(args.values_json)
    encoded_id = urllib.parse.quote(args.file_id, safe="")
    encoded_range = urllib.parse.quote(args.range, safe="")
    result = api_request(
        "PUT",
        f"{SHEETS_API}/spreadsheets/{encoded_id}/values/{encoded_range}",
        query={"valueInputOption": args.value_input_option},
        body={"range": args.range, "majorDimension": "ROWS", "values": values},
    )
    output(result)


def sheets_append(args: argparse.Namespace) -> None:
    managed_file(args.file_id, expected_mime=SHEET_MIME)
    values = parse_values(args.values_json)
    encoded_id = urllib.parse.quote(args.file_id, safe="")
    encoded_range = urllib.parse.quote(args.range, safe="")
    result = api_request(
        "POST",
        f"{SHEETS_API}/spreadsheets/{encoded_id}/values/{encoded_range}:append",
        query={
            "valueInputOption": args.value_input_option,
            "insertDataOption": "INSERT_ROWS",
        },
        body={"range": args.range, "majorDimension": "ROWS", "values": values},
    )
    output(result)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    services = root.add_subparsers(dest="service", required=True)

    workspace = services.add_parser("workspace")
    workspace_cmds = workspace.add_subparsers(dest="workspace_command", required=True)
    workspace_cmds.add_parser("ensure").set_defaults(handler=workspace_ensure)
    workspace_cmds.add_parser("status").set_defaults(handler=workspace_status)

    drive = services.add_parser("drive")
    drive_cmds = drive.add_subparsers(dest="drive_command", required=True)
    list_cmd = drive_cmds.add_parser("list")
    list_cmd.add_argument("--parent-id")
    list_cmd.add_argument("--max", dest="max_results", type=int, default=100)
    list_cmd.set_defaults(handler=drive_list)
    tree_cmd = drive_cmds.add_parser("tree")
    tree_cmd.add_argument("--max", dest="max_results", type=int, default=500)
    tree_cmd.set_defaults(handler=drive_tree)
    get_cmd = drive_cmds.add_parser("get")
    get_cmd.add_argument("file_id")
    get_cmd.set_defaults(handler=drive_get)
    mkdir_cmd = drive_cmds.add_parser("mkdir")
    mkdir_cmd.add_argument("--name", required=True)
    mkdir_cmd.add_argument("--parent-id")
    mkdir_cmd.set_defaults(handler=drive_mkdir)
    rename_cmd = drive_cmds.add_parser("rename")
    rename_cmd.add_argument("file_id")
    rename_cmd.add_argument("--name", required=True)
    rename_cmd.set_defaults(handler=drive_rename)
    move_cmd = drive_cmds.add_parser("move")
    move_cmd.add_argument("file_id")
    move_cmd.add_argument("--parent-id", required=True)
    move_cmd.set_defaults(handler=drive_move)
    trash_cmd = drive_cmds.add_parser("trash")
    trash_cmd.add_argument("file_id")
    trash_cmd.set_defaults(handler=drive_trash)

    docs = services.add_parser("docs")
    docs_cmds = docs.add_subparsers(dest="docs_command", required=True)
    create_doc = docs_cmds.add_parser("create")
    create_doc.add_argument("--title", required=True)
    create_doc.add_argument("--text", default="")
    create_doc.add_argument("--parent-id")
    create_doc.set_defaults(handler=docs_create)
    get_doc = docs_cmds.add_parser("get")
    get_doc.add_argument("file_id")
    get_doc.set_defaults(handler=docs_get)
    append_doc = docs_cmds.add_parser("append")
    append_doc.add_argument("file_id")
    append_doc.add_argument("--text", required=True)
    append_doc.set_defaults(handler=docs_append)

    sheets = services.add_parser("sheets")
    sheets_cmds = sheets.add_subparsers(dest="sheets_command", required=True)
    create_sheet = sheets_cmds.add_parser("create")
    create_sheet.add_argument("--title", required=True)
    create_sheet.add_argument("--range", default="Sheet1!A1")
    create_sheet.add_argument("--values-json")
    create_sheet.add_argument("--parent-id")
    create_sheet.set_defaults(handler=sheets_create)
    get_sheet = sheets_cmds.add_parser("get")
    get_sheet.add_argument("file_id")
    get_sheet.add_argument("--range", default="Sheet1")
    get_sheet.set_defaults(handler=sheets_get)
    update_sheet = sheets_cmds.add_parser("update")
    update_sheet.add_argument("file_id")
    update_sheet.add_argument("--range", required=True)
    update_sheet.add_argument("--values-json", required=True)
    update_sheet.add_argument(
        "--value-input-option",
        choices=("RAW", "USER_ENTERED"),
        default="USER_ENTERED",
    )
    update_sheet.set_defaults(handler=sheets_update)
    append_sheet = sheets_cmds.add_parser("append")
    append_sheet.add_argument("file_id")
    append_sheet.add_argument("--range", required=True)
    append_sheet.add_argument("--values-json", required=True)
    append_sheet.add_argument(
        "--value-input-option",
        choices=("RAW", "USER_ENTERED"),
        default="USER_ENTERED",
    )
    append_sheet.set_defaults(handler=sheets_append)
    return root


def main() -> None:
    args = parser().parse_args()
    handler = getattr(args, "handler", None)
    if handler is None:
        fail("No command selected")
    handler(args)


if __name__ == "__main__":
    main()
