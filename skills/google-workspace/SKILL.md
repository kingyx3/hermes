---
name: google-workspace
description: "Managed personal Google services for Gmail, Calendar, Contacts, and a folder-bound Drive/Docs/Sheets workspace. Use this skill for every configured Google service request."
version: 1.4.0
platforms: [linux]
required_credential_files:
  - path: google_token.json
    description: Gmail and Calendar OAuth2 authorized-user token
  - path: google_client_secret.json
    description: Google OAuth2 Desktop client
metadata:
  hermes:
    tags: [Google, Gmail, Calendar, Contacts, People, Drive, Docs, Sheets, Email, OAuth]
---

# Google Workspace — managed Hermes deployment

Use the repository-managed integrations for Gmail, Calendar, Google Contacts,
Drive, Docs, and Sheets. The services use separately stored least-privilege
OAuth tokens. Contacts uses the People API with read/write access, while Drive,
Docs, and Sheets remain restricted to the app-owned `hermes` folder and all of
its descendants.

All runtime clients use only Python's standard library. They do **not** import
`googleapiclient`, `google-auth`, or any pip package.

## Routing rules

1. For Gmail, Google Calendar, Google Contacts, People API, Drive, Docs, or
   Sheets requests, use this skill.
2. A request mentioning a contact, contact list, address book, person, phone
   number, or saved email address must use the Contacts client below. Do not
   substitute Drive, Docs, Sheets, or a contact spreadsheet.
3. Never claim Contacts are unavailable before testing the Contacts runtime and
   token with the documented health command.
4. A request to organize files, create folders or subfolders, list a folder,
   move a managed file, or create a Doc/Sheet in a named folder must use the
   recursive Drive client below. Do not claim nested folders are unsupported.
5. Do **not** switch to `himalaya` merely because a request mentions email only.
6. Do **not** run `pip`, `pip install`, `setup.py`, or `ensurepip`.
7. Use the exact scripts and `/usr/bin/python3`; do not depend on shell `PATH`.
8. If a script is missing, report that **Google Workspace Runtime Repair** must
   be run.
9. Never broaden Drive access or use another Drive tool. Every Drive, Docs, and
   Sheets operation must remain beneath the managed `hermes` root.

## Exact runtime paths

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"
DAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_drive.py"
CAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-contacts/scripts/google_contacts.py"

test -f "$GAPI" || { echo "Google Workspace Runtime Repair is required: $GAPI is missing" >&2; exit 1; }
test -f "$DAPI" || { echo "Google Workspace Runtime Repair is required: $DAPI is missing" >&2; exit 1; }
test -f "$CAPI" || { echo "Google Workspace Runtime Repair is required: $CAPI is missing" >&2; exit 1; }
```

Run them only as:

```bash
/usr/bin/python3 "$GAPI"
/usr/bin/python3 "$DAPI"
/usr/bin/python3 "$CAPI"
```

## Gmail and Calendar health check

```bash
/usr/bin/python3 "$GAPI" check
```

A healthy response contains `"authenticated": true`,
`"calendarReachable": true`, and `"runtime": "python-stdlib"`.

## Gmail

```bash
# Search inbox messages from the last 30 days.
/usr/bin/python3 "$GAPI" gmail search "in:inbox newer_than:30d" --max 100

# Search unread messages.
/usr/bin/python3 "$GAPI" gmail search "in:inbox is:unread" --max 50

# Read a full message.
/usr/bin/python3 "$GAPI" gmail get MESSAGE_ID

# List labels.
/usr/bin/python3 "$GAPI" gmail labels

# Send or reply only after explicit user approval.
/usr/bin/python3 "$GAPI" gmail send --to user@example.com --subject "Subject" --body "Body"
/usr/bin/python3 "$GAPI" gmail reply MESSAGE_ID --body "Body"
```

For inbox summaries, search with `in:inbox newer_than:30d`, fetch important or
ambiguous bodies, summarize by priority and topic, state the reviewed count, and
do not modify mail unless explicitly requested.

## Calendar

```bash
# Upcoming events.
/usr/bin/python3 "$GAPI" calendar list

# Explicit date range.
/usr/bin/python3 "$GAPI" calendar list --start 2026-07-15T00:00:00+08:00 --end 2026-07-16T00:00:00+08:00

# Create only after explicit user approval.
/usr/bin/python3 "$GAPI" calendar create --summary "Meeting" --start 2026-07-15T10:00:00+08:00 --end 2026-07-15T10:30:00+08:00
```

Do not create, update, delete, or invite attendees without explicit approval.
Use Asia/Singapore when the user provides no other timezone.

## Google Contacts

Contacts uses a separate read/write token at
`~/.hermes/google_contacts_token.json` and the People API.

### Contacts health check

Run before the first Contacts operation in a conversation:

```bash
/usr/bin/python3 "$CAPI" check
```

A healthy response contains `"contactsReachable": true`,
`"scope": "https://www.googleapis.com/auth/contacts"`, and
`"runtime": "python-stdlib"`.

When the Contacts token is missing, tell the operator to run **Google Workspace
Setup** with `service=contacts`. Do not redirect the user to a spreadsheet and
do not start OAuth from Telegram.

### List, search, and read contacts

These read operations do not require confirmation:

```bash
/usr/bin/python3 "$CAPI" list --max 100
/usr/bin/python3 "$CAPI" search "Ada" --max 25
/usr/bin/python3 "$CAPI" get people/CONTACT_ID
```

Search before acting when a name is ambiguous. Use only a `people/...` resource
name returned by this client; never invent or guess a contact ID.

### Create contacts

Only after explicit user confirmation:

```bash
/usr/bin/python3 "$CAPI" create \
  --given-name "Ada" \
  --family-name "Lovelace" \
  --email "ada@example.com" \
  --phone "+65 6123 4567" \
  --company "Example Ltd" \
  --job-title "Engineer"
```

Multiple `--email`, `--phone`, and `--url` flags are supported.

### Update or clear contact fields

Only after explicit user confirmation. The client fetches the latest People API
metadata and etag before updating:

```bash
/usr/bin/python3 "$CAPI" update people/CONTACT_ID \
  --email "new@example.com" \
  --phone "+65 6987 6543"

/usr/bin/python3 "$CAPI" update people/CONTACT_ID --clear-phones
/usr/bin/python3 "$CAPI" update people/CONTACT_ID --clear-notes
```

Supported writable fields are names, email addresses, phone numbers, company,
job title, notes, birthday, and URLs.

### Delete contacts

Only after explicit user confirmation:

```bash
/usr/bin/python3 "$CAPI" delete people/CONTACT_ID
```

## Drive workspace boundary

Drive authorization remains limited to the non-sensitive `drive.file` scope.
The client creates one app-owned folder named exactly:

```text
hermes
```

The client permits the managed root and any depth of folders, Docs, or Sheets
beneath it. Every operation validates the complete parent chain back to that
marked root. It rejects items outside the root, trashed ancestors, ancestry
cycles, non-folder parents, and ambiguous multi-parent items.

Folder and file moves validate both the source and destination. The managed
`hermes` root cannot be renamed, moved, or trashed, and a folder cannot be moved
into itself or one of its descendants.

Do not bypass these checks, use raw Drive URLs, or substitute another Drive
tool. File IDs must come from `drive list`, `drive tree`, `drive get`, or a prior
result from this client.

### Drive workspace health

Run before the first Drive, Docs, or Sheets operation in a conversation:

```bash
/usr/bin/python3 "$DAPI" workspace status
```

A healthy response contains `"ready": true`, folder name `"hermes"`, and
`"boundary": "managed-descendants-only"`.

When `google_drive_token.json` is missing, tell the operator to run **Google
Workspace Setup** with `service=drive`. Do not start OAuth from Telegram.

### Inspect folders and files

These read operations do not require confirmation:

```bash
# List direct children of the hermes root.
/usr/bin/python3 "$DAPI" drive list --max 100

# List direct children of a managed subfolder.
/usr/bin/python3 "$DAPI" drive list --parent-id FOLDER_ID --max 100

# Return the complete managed tree with computed paths.
/usr/bin/python3 "$DAPI" drive tree --max 500

# Inspect one managed file or folder and its path.
/usr/bin/python3 "$DAPI" drive get FILE_ID
```

Use `drive tree` or progressively use `drive list --parent-id` to resolve a
folder by name. When duplicate names exist, show the matching paths and ask the
user to choose before performing a mutation.

### Create folders and subfolders

Only after explicit user confirmation:

```bash
# Create a folder directly under hermes.
/usr/bin/python3 "$DAPI" drive mkdir --name "Trips"

# Create a nested folder under a validated managed folder.
/usr/bin/python3 "$DAPI" drive mkdir --name "Japan" --parent-id TRIPS_FOLDER_ID
```

### Rename, move, or trash managed items

Only after explicit user confirmation:

```bash
/usr/bin/python3 "$DAPI" drive rename FILE_OR_FOLDER_ID --name "New name"
/usr/bin/python3 "$DAPI" drive move FILE_OR_FOLDER_ID --parent-id DESTINATION_FOLDER_ID
/usr/bin/python3 "$DAPI" drive trash FILE_OR_FOLDER_ID
```

Before a move, resolve the destination folder through this client. Never guess a
folder ID. Moving to the root uses the root folder ID returned by `workspace
status` or `drive tree`.

### Google Docs

```bash
# Create in the hermes root, only after explicit user confirmation.
/usr/bin/python3 "$DAPI" docs create --title "Meeting notes" --text "Initial content"

# Create in a managed subfolder, only after explicit user confirmation.
/usr/bin/python3 "$DAPI" docs create --title "Japan Trip Plan Nov 2026" --parent-id JAPAN_FOLDER_ID --text "Initial content"

# Read a managed document at any depth.
/usr/bin/python3 "$DAPI" docs get FILE_ID

# Append only when the user asks to update the document.
/usr/bin/python3 "$DAPI" docs append FILE_ID --text $'\nNew section'
```

### Google Sheets

```bash
# Create in the hermes root, only after explicit user confirmation.
/usr/bin/python3 "$DAPI" sheets create --title "Tracker" --range "Sheet1!A1" --values-json '[["Task","Owner"],["Example","J"]]'

# Create in a managed subfolder, only after explicit user confirmation.
/usr/bin/python3 "$DAPI" sheets create --title "Japan Budget" --parent-id JAPAN_FOLDER_ID --range "Sheet1!A1" --values-json '[["Item","Cost"]]'

# Read a managed range at any depth.
/usr/bin/python3 "$DAPI" sheets get FILE_ID --range "Sheet1!A1:Z100"

# Update or append only when explicitly requested.
/usr/bin/python3 "$DAPI" sheets update FILE_ID --range "Sheet1!A1:B2" --values-json '[["Task","Owner"],["Example","J"]]'
/usr/bin/python3 "$DAPI" sheets append FILE_ID --range "Sheet1!A:B" --values-json '[["Next task","J"]]'
```

## Operator-managed workflows

- **Google Workspace Setup** manages the separately stored `core`, `contacts`,
  and `drive` authorization domains.
- **Google Workspace Runtime Repair** installs all managed clients and skills,
  restarts Hermes, and validates every authorized service.

The complete browser-only procedures are documented in
`GOOGLE_WORKSPACE_SETUP.md`, `docs/google-contacts.md`, and
`docs/google-drive-workspace.md`.
