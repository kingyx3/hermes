# Folder-bound Google Drive, Docs, and Sheets

Hermes can use Google Drive, Docs, and Sheets through a separate OAuth token
that grants only:

```text
https://www.googleapis.com/auth/drive.file
```

This is deliberately separate from the Gmail and Calendar token. Revoking Drive
access does not disconnect Gmail or Calendar.

## Security boundary

The runtime creates one Google Drive folder named exactly:

```text
hermes
```

It adds a private application marker to the folder and stores the folder ID at:

```text
/home/hermes/.hermes/google_drive_workspace.json
```

The Drive OAuth token is stored at:

```text
/home/hermes/.hermes/google_drive_token.json
```

Every Drive, Docs, or Sheets command validates the managed folder before doing
anything. Files must be direct children of that folder. The client rejects a
file when:

- its parent is not the managed folder;
- it is trashed;
- its Google Workspace type does not match the command;
- the managed folder is renamed, trashed, or missing its application marker.

The client does not search the user's wider Drive and has no broad `drive` or
`drive.readonly` scope.

## Supported operations

Within the managed folder, Hermes can:

- list and inspect files;
- create and read Google Docs;
- append text to Google Docs;
- create Google Sheets;
- read, update, and append Sheet ranges;
- rename or trash managed files after an explicit user request.

It cannot access existing files elsewhere in Drive. This deployment does not
implement Google Picker or a command for importing arbitrary existing files.

## One-time Google Cloud configuration

In **Google Auth Platform**, add this scope to the OAuth consent configuration:

```text
https://www.googleapis.com/auth/drive.file
```

The same Desktop OAuth client JSON already stored in the GitHub secret
`GOOGLE_OAUTH_CLIENT_JSON` is reused.

The workflow enables these APIs automatically:

```text
drive.googleapis.com
docs.googleapis.com
sheets.googleapis.com
```

## One-time authorization

Run these GitHub Actions in order:

1. **Google Drive Workspace OAuth → `provision-client`**.
2. **Google Drive Workspace OAuth → `send-auth-link`**.
3. Open the private Telegram link and approve the per-file Drive permission.
4. Copy the complete failed loopback URL beginning with
   `http://127.0.0.1:1/?code=...`.
5. Create temporary repository secret `GOOGLE_DRIVE_OAUTH_CALLBACK_URL` with the
   complete URL.
6. **Google Drive Workspace OAuth → `exchange-callback`**.
7. Delete `GOOGLE_DRIVE_OAUTH_CALLBACK_URL` immediately.

The exchange workflow creates or recovers the managed folder and should print:

```text
DRIVE_WORKSPACE_AUTHENTICATED: app-owned hermes folder is ready.
```

The managed folder appears in the connected Google Drive as `hermes`.

## Runtime verification

Run **Google Workspace Runtime Repair** after authorization or let it run
automatically after the next successful agent deployment.

Expected markers:

```text
AGENT_RUNTIME_READY_STDLIB
GOOGLE_DRIVE_FOLDER_READY
```

You can also run **Google Drive Workspace OAuth → `check`**. A healthy result
contains:

```text
DRIVE_WORKSPACE_READY: Drive, Docs, and Sheets are restricted to hermes.
```

## Telegram examples

Send a new Telegram message after authorization and runtime repair:

```text
List the files in my Hermes Drive folder.
```

```text
Create a Google Doc named Weekly Notes in the Hermes folder with a heading for this week.
```

```text
Create a Google Sheet named Project Tracker in the Hermes folder with columns Task, Owner, Status, and Due Date.
```

```text
Read the Project Tracker sheet and summarize overdue items.
```

Hermes should load the `google-workspace` skill and use the exact
`google_drive.py` client. It should not use a general browser or another Drive
tool.

## After redeployment

Normal deployment preserves:

```text
/home/hermes/.hermes/google_drive_token.json
/home/hermes/.hermes/google_drive_workspace.json
```

The automatic **Google Workspace Runtime Repair** run restores the client,
wrapper, and skill instructions, then validates the existing managed folder.
No new Drive OAuth callback is normally required.

Run the Drive OAuth flow again only when the Drive check reports a revoked,
invalid, or missing token.

## Revocation

Run:

```text
Google Drive Workspace OAuth → revoke
```

This revokes and deletes the Drive token. It does not delete the `hermes` folder
or its files, and it does not revoke Gmail or Calendar access.
