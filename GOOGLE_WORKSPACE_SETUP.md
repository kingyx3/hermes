# Google Workspace setup and operations

This is the operator entry point for connecting Hermes to a personal Gmail
account and Google Calendar without running commands locally.

Detailed references:

- [Full browser-only OAuth setup](docs/google-workspace.md)
- [Telegram and runtime troubleshooting](docs/google-workspace-runtime-troubleshooting.md)

## Runtime design

OAuth setup and normal Gmail/Calendar usage use separate implementations:

- **Google Workspace OAuth** uses the Google authentication libraries only for
  creating, exchanging, refreshing, checking, and revoking OAuth credentials.
- **Google Workspace Runtime Repair** installs a separate Gmail/Calendar client
  written entirely with Python's standard library.

The active runtime client is installed at:

```text
/home/hermes/.hermes/skills/productivity/google-workspace/scripts/google_api.py
```

It does not import `googleapiclient`, `google-auth`, or any pip package. Runtime
requests therefore continue working even when Hermes' private virtual
environment is replaced or unavailable.

## Workflows

| Workflow | Purpose |
|---|---|
| **Deploy Hermes Agent** | Creates or updates the VM and restarts Hermes. |
| **Google Workspace Runtime Repair** | Overwrites the active Google skill and `google_api.py` with the repository-managed standard-library versions, then performs live Gmail and Calendar checks. Runs automatically after every successful deploy. |
| **Google Workspace OAuth** | Provisions the Desktop OAuth client, sends the authorization link, exchanges the callback, checks OAuth, or revokes the token. |

## One-time Google Cloud configuration

Use the same Google Cloud project as the Hermes deployment.

1. Open **Google Auth Platform** in Google Cloud Console.
2. Configure Branding with an app name, support email, and developer contact.
3. For a personal Gmail account, set Audience to **External**.
4. While the app is in Testing, add the Gmail account as a test user.
5. Declare these scopes when requested:

   ```text
   https://www.googleapis.com/auth/gmail.modify
   https://www.googleapis.com/auth/calendar.events
   ```

6. Create an OAuth client with application type **Desktop app**.
7. Download the client JSON.

An External app left in Testing normally receives a refresh token that expires
after seven days for these scopes. Review the Google Auth Platform publishing
status after testing.

## One-time GitHub configuration

Under **Settings → Secrets and variables → Actions**:

1. Create secret `GOOGLE_OAUTH_CLIENT_JSON` containing the complete downloaded
   Desktop OAuth JSON.
2. Confirm secret `TELEGRAM_BOT_TOKEN` exists.
3. Confirm variable `TELEGRAM_ALLOWED_USERS` contains your numeric Telegram user
   ID, or set `GOOGLE_OAUTH_TELEGRAM_CHAT_ID` to the desired private chat ID.

`GOOGLE_OAUTH_CALLBACK_URL` is temporary and should exist only during callback
exchange.

## Initial setup sequence

Run the workflows in this order:

1. **Deploy Hermes Agent**.
2. **Google Workspace OAuth → `provision-client`**.
3. **Google Workspace OAuth → `send-auth-link`**.
4. Open the link delivered privately through Telegram and approve access.
5. Copy the complete failed loopback URL beginning with
   `http://127.0.0.1:1/?code=...` from the browser address bar.
6. Create temporary secret `GOOGLE_OAUTH_CALLBACK_URL` with that complete URL.
7. **Google Workspace OAuth → `exchange-callback`**.
8. Delete `GOOGLE_OAUTH_CALLBACK_URL` immediately after success.
9. **Google Workspace Runtime Repair**.
10. **Google Workspace OAuth → `check`**.

The runtime-repair log must contain:

```text
AGENT_RUNTIME_READY_STDLIB: active skill client passed Gmail and Calendar without googleapiclient.
```

The OAuth check should contain:

```text
AUTHENTICATED: Gmail and Calendar API checks passed
```

## Verify from Telegram

Send a new message after runtime repair completes:

```text
Review my Gmail inbox and summarize messages in the last 30 days.
```

Expected behavior:

- Hermes loads the `google-workspace` skill.
- It defines the active script path under
  `$HERMES_HOME/skills/productivity/google-workspace/scripts/google_api.py`.
- It runs `/usr/bin/python3 "$GAPI" check`.
- It searches Gmail with `/usr/bin/python3 "$GAPI" gmail search ...`.
- It does not check for `googleapiclient`.
- It does not load Himalaya or attempt `pip install`.

The managed skill searches:

```text
in:inbox newer_than:30d
```

and fetches full bodies for important or ambiguous messages before producing a
priority- and topic-based summary.

## After any redeploy

No OAuth callback is normally required.

1. Let the automatic **Google Workspace Runtime Repair** workflow complete.
2. Confirm `AGENT_RUNTIME_READY_STDLIB`.
3. Retry the Telegram request in a new message.
4. Run **Google Workspace OAuth → `check`** only when you want an additional
   OAuth-helper check.

A normal deploy preserves:

```text
/home/hermes/.hermes/google_client_secret.json
/home/hermes/.hermes/google_token.json
```

Runtime repair deliberately overwrites the active skill instructions and
`google_api.py`, because a Hermes update may reseed bundled skill files.

## Repair sequence

When Telegram mentions missing Google Python libraries, a missing command, or
Himalaya:

1. Run **Google Workspace Runtime Repair** manually.
2. Confirm `AGENT_RUNTIME_READY_STDLIB`.
3. Send the Gmail request as a new Telegram message.

When runtime repair reports that the token is absent, repeat only the OAuth
authorization steps: `send-auth-link`, temporary callback secret, and
`exchange-callback`, then rerun runtime repair.

Do not configure a Gmail App Password or Himalaya unless you intentionally want
a second, separate email integration.

## Revoke access

Run:

```text
Google Workspace OAuth → revoke
```

This revokes and deletes the stored user token. It leaves the Desktop OAuth
client installed so authorization can be completed again later.
