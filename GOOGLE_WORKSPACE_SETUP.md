# Google Workspace setup and operations

This is the operator entry point for connecting Hermes to a personal Gmail
account and Google Calendar without running commands locally.

Detailed references:

- [Full browser-only OAuth setup](docs/google-workspace.md)
- [Telegram and runtime troubleshooting](docs/google-workspace-runtime-troubleshooting.md)

## Workflows

| Workflow | Purpose |
|---|---|
| **Deploy Hermes Agent** | Creates or updates the VM and restarts Hermes. |
| **Google Workspace Runtime Repair** | Installs the managed Google skill, explicit venv-backed API wrapper, and verifies Gmail access. Runs automatically after every successful deploy. |
| **Google Workspace OAuth** | Provisions the Desktop OAuth client, sends the authorization link, exchanges the callback, checks access, or revokes the token. |

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
2. Wait for the automatic **Google Workspace Runtime Repair** run.
3. **Google Workspace OAuth → `provision-client`**.
4. **Google Workspace OAuth → `send-auth-link`**.
5. Open the link delivered privately through Telegram and approve access.
6. Copy the complete failed loopback URL beginning with
   `http://127.0.0.1:1/?code=...` from the browser address bar.
7. Create temporary secret `GOOGLE_OAUTH_CALLBACK_URL` with that complete URL.
8. **Google Workspace OAuth → `exchange-callback`**.
9. Delete `GOOGLE_OAUTH_CALLBACK_URL` immediately after success.
10. **Google Workspace Runtime Repair**.
11. **Google Workspace OAuth → `check`**.

The runtime-repair log should contain:

```text
AGENT_RUNTIME_READY: managed Google skill and Gmail API command passed.
```

The OAuth check should contain:

```text
AUTHENTICATED: Gmail and Calendar API checks passed
```

## Verify from Telegram

Send:

```text
Review my Gmail inbox and summarize messages in the last 30 days.
```

Expected behavior:

- Hermes loads the `google-workspace` skill.
- It runs `hermes-google-workspace check`.
- It uses `hermes-google-api` for Gmail.
- It does not load Himalaya or run `himalaya --version`.
- It does not attempt `pip install` from the conversation.

The managed skill instructs Hermes to search:

```text
in:inbox newer_than:30d
```

and to fetch full bodies for important or ambiguous messages before producing a
priority- and topic-based summary.

## After any redeploy

No OAuth callback is normally required.

1. Let the automatic **Google Workspace Runtime Repair** workflow complete.
2. Run **Google Workspace OAuth → `check`** when you want an explicit live check.
3. Retry the Telegram request.

A normal deploy preserves:

```text
/home/hermes/.hermes/google_client_secret.json
/home/hermes/.hermes/google_token.json
```

The runtime-repair workflow re-applies the managed skill and wrappers because a
Hermes update can replace bundled skill instructions or its Python environment.

## Repair sequence

When Telegram mentions missing Python libraries or Himalaya:

1. Run **Google Workspace Runtime Repair** manually.
2. Confirm `AGENT_RUNTIME_READY`.
3. Run **Google Workspace OAuth → `check`**.
4. Retry the request in a new Telegram message.

When runtime repair says the token is missing, repeat only the authorization
steps: `send-auth-link`, temporary callback secret, and `exchange-callback`.

Do not configure a Gmail App Password or Himalaya unless you intentionally want
a second, separate email integration.

## Revoke access

Run:

```text
Google Workspace OAuth → revoke
```

This revokes and deletes the stored user token. It leaves the Desktop OAuth
client installed so authorization can be completed again later.
