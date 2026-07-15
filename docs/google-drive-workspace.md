# Folder-bound Google Drive, Docs, and Sheets

Hermes uses only:

```text
https://www.googleapis.com/auth/drive.file
```

The runtime creates one app-owned folder named `hermes`, stores its ID in
`~/.hermes/google_drive_workspace.json`, and permits operations only on that
folder and descendants created or opened through the app-authorized workspace.
It never searches or operates across the user's wider Drive.

## Authorization

Use **Actions → Google Workspace Setup**:

1. Select `service=drive` and `action=send-auth-link`.
2. Approve the private Telegram link.
3. Save the complete failed loopback URL temporarily as
   `GOOGLE_OAUTH_CALLBACK_URL`.
4. Run `service=drive` and `action=exchange-callback`.
5. Delete the temporary callback secret.

A successful exchange prints:

```text
DRIVE_WORKSPACE_AUTHENTICATED: app-owned hermes folder is ready.
```

Existing Drive authorization remains valid after enabling subfolders. No new
OAuth scope or reauthorization is required.

## Security boundary

Every request validates that:

- the managed root is named `hermes`, is not trashed, and retains its app marker;
- the requested item has a complete parent chain back to that root;
- every ancestor is an untrashed folder;
- the requested Google Workspace type matches the command;
- source and destination are both managed before a move;
- the root cannot be renamed, moved, or trashed;
- a folder cannot be moved into itself or one of its descendants;
- ancestry cycles, excessive depth, and ambiguous multi-parent items are rejected.

The runtime reports this boundary as:

```text
managed-descendants-only
```

## Folder and file commands

List the root, a subfolder, or the complete tree:

```bash
/usr/bin/python3 "$DAPI" drive list --max 100
/usr/bin/python3 "$DAPI" drive list --parent-id FOLDER_ID --max 100
/usr/bin/python3 "$DAPI" drive tree --max 500
/usr/bin/python3 "$DAPI" drive get FILE_OR_FOLDER_ID
```

Create folders and nested subfolders:

```bash
/usr/bin/python3 "$DAPI" drive mkdir --name "Trips"
/usr/bin/python3 "$DAPI" drive mkdir --name "Japan" --parent-id TRIPS_FOLDER_ID
```

Rename, move, or trash managed items:

```bash
/usr/bin/python3 "$DAPI" drive rename FILE_OR_FOLDER_ID --name "New name"
/usr/bin/python3 "$DAPI" drive move FILE_OR_FOLDER_ID --parent-id DESTINATION_FOLDER_ID
/usr/bin/python3 "$DAPI" drive trash FILE_OR_FOLDER_ID
```

Create Docs and Sheets in a managed subfolder:

```bash
/usr/bin/python3 "$DAPI" docs create \
  --title "Japan Trip Plan Nov 2026" \
  --parent-id JAPAN_FOLDER_ID \
  --text "Initial content"

/usr/bin/python3 "$DAPI" sheets create \
  --title "Japan Budget" \
  --parent-id JAPAN_FOLDER_ID \
  --range "Sheet1!A1" \
  --values-json '[["Item","Cost"]]'
```

Read and update commands work at any managed depth because the runtime validates
the full ancestry before accessing the Docs or Sheets API.

Hermes must ask for explicit confirmation before creating a folder or file,
renaming, moving, editing, or trashing an item. Read-only listing, tree, get,
Docs read, and Sheets read operations do not require confirmation.

## Runtime

**Google Workspace Runtime Repair** restores and checks the Drive client after
deployments. A healthy run prints:

```text
GOOGLE_DRIVE_FOLDER_READY
```

Normal deployments preserve:

```text
~/.hermes/google_drive_token.json
~/.hermes/google_drive_workspace.json
```
