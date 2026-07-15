# Google Workspace setup and operations

This is the operator entry point for connecting Hermes to Gmail, Google
Calendar, and a folder-bound Google Drive workspace without running commands
locally.

Detailed references:

- [Gmail and Calendar browser-only OAuth](docs/google-workspace.md)
- [Folder-bound Drive, Docs, and Sheets](docs/google-drive-workspace.md)
- [Telegram and runtime troubleshooting](docs/google-workspace-runtime-troubleshooting.md)

## Runtime design

Hermes uses dependency-free standard-library clients at these active paths:

```text
/home/hermes/.hermes/skills/productivity/google-workspace/scripts/google_api.py
/home/hermes/.hermes/skills/productivity/google-workspace/scripts/google_drive.py
```

`google_api.py` handles Gmail and Calendar. `google_drive.py` handles Drive,
Docs, and Sheets, and rejects every file outside the app-owned folder named
`hermes`.

## Workflows

| Workflow | Purpose |
|---|---|
| **Deploy Hermes Agent** | Creates or updates the VM and restarts Hermes. |
| **Google Workspace Runtime Repair** | Restores both active clients and the managed skill after every successful deploy. It validates Gmail/Calendar when authorized and validates the managed Drive folder when its separate token exists. |
| **Google Workspace OAuth** | Provisions and manages the Gmail/Calendar OAuth token. |
| **Google Drive Workspace OAuth** | Provisions and manages the per-file Drive token, then creates or recovers the app-owned `hermes` folder. |

## Google Cloud configuration

Use the same Google Cloud project and Desktop OAuth client as the Hermes
deployment.

Under **Google Auth Platform**, declare:

```text
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/calendar.events
https://www.googleapis.com/auth/drive.file
```

`drive.file` is the only Drive permission requested. The workflows enable:

```text
gmail.googleapis.com
calendar-json.googleapis.com
drive.googleapis.com
docs.googleapis.com
sheets.googleapis.com
```

For a personal Gmail account, keep the OAuth app's test-user and publishing
configuration current. An External app left in Testing may issue short-lived
refresh authorization depending on Google's current policy.

## GitHub configuration

Under **Settings → Secrets and variables → Actions**:

1. `GOOGLE_OAUTH_CLIENT_JSON`: the complete Desktop OAuth client JSON.
2. `TELEGRAM_BOT_TOKEN`: the Hermes Telegram bot token.
3. `TELEGRAM_ALLOWED_USERS`: your numeric Telegram user ID, or configure
   `GOOGLE_OAUTH_TELEGRAM_CHAT_ID`.

Temporary callback secrets:

```text
GOOGLE_OAUTH_CALLBACK_URL
GOOGLE_DRIVE_OAUTH_CALLBACK_URL
```

Delete each immediately after its callback exchange succeeds.

## Initial Gmail and Calendar authorization

1. Run **Google Workspace OAuth → `provision-client`**.
2. Run **Google Workspace OAuth → `send-auth-link`**.
3. Approve the link sent through Telegram.
4. Copy the complete failed `http://127.0.0.1:1/?code=...` URL.
5. Store it temporarily as `GOOGLE_OAUTH_CALLBACK_URL`.
6. Run **Google Workspace OAuth → `exchange-callback`**.
7. Delete the temporary callback secret.
8. Run **Google Workspace Runtime Repair**.

Expected markers:

```text
AUTHENTICATED: Gmail and Calendar API checks passed
AGENT_RUNTIME_READY_STDLIB
```

## Initial Drive, Docs, and Sheets authorization

This is a separate browser consent because existing OAuth tokens cannot gain a
new scope automatically.

1. Add `https://www.googleapis.com/auth/drive.file` to the Google Auth Platform
   consent configuration.
2. Run **Google Drive Workspace OAuth → `provision-client`**.
3. Run **Google Drive Workspace OAuth → `send-auth-link`**.
4. Approve the per-file Drive permission.
5. Copy the complete failed `http://127.0.0.1:1/?code=...` URL.
6. Store it temporarily as `GOOGLE_DRIVE_OAUTH_CALLBACK_URL`.
7. Run **Google Drive Workspace OAuth → `exchange-callback`**.
8. Delete the temporary callback secret.

The exchange creates or recovers a folder named exactly `hermes` and should
print:

```text
DRIVE_WORKSPACE_AUTHENTICATED: app-owned hermes folder is ready.
```

Then run **Google Workspace Runtime Repair** and confirm:

```text
GOOGLE_DRIVE_FOLDER_READY
```

## Drive safety boundary

The Drive client stores its token and workspace state at:

```text
/home/hermes/.hermes/google_drive_token.json
/home/hermes/.hermes/google_drive_workspace.json
```

It lists only direct children of the managed folder and validates the parent ID
before every read or mutation. It cannot search the user's wider Drive. Docs
and Sheets are created directly inside the managed folder.

## Telegram verification

Gmail:

```text
Review my Gmail inbox and summarize messages in the last 30 days.
```

Drive:

```text
List the files in my Hermes Drive folder.
```

Docs:

```text
Create a Google Doc named Weekly Notes in the Hermes folder.
```

Sheets:

```text
Create a Google Sheet named Project Tracker in the Hermes folder with columns Task, Owner, Status, and Due Date.
```

Hermes should load the `google-workspace` skill and use the exact standard-library
scripts. It must not use Himalaya for Gmail, pip-install Google libraries, or
use a general browser/Drive tool to bypass the folder boundary.

## After any redeploy

Normal deployment preserves all OAuth tokens and the managed Drive folder ID.
The automatic **Google Workspace Runtime Repair** run restores clients and skill
instructions. No new browser callback is normally required.

Expected post-deploy markers depend on which services are authorized:

```text
AGENT_RUNTIME_READY_STDLIB
GOOGLE_DRIVE_FOLDER_READY
```

When Drive has not yet been authorized, runtime repair prints:

```text
GOOGLE_DRIVE_AUTHORIZATION_REQUIRED
```

## Revocation

Gmail and Calendar:

```text
Google Workspace OAuth → revoke
```

Drive, Docs, and Sheets:

```text
Google Drive Workspace OAuth → revoke
```

Revoking Drive access leaves the `hermes` folder and its files in Google Drive.
Because both flows reuse the same Google OAuth client, review both live checks
after any revocation if Google invalidates other grants for that client.
