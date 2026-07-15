---
name: google-workspace
description: "Personal Gmail and Google Calendar through the repository-managed OAuth integration. Always prefer this skill over Himalaya when Google credentials are configured."
version: 1.1.0
platforms: [linux]
required_credential_files:
  - path: google_token.json
    description: Google OAuth2 authorized-user token
  - path: google_client_secret.json
    description: Google OAuth2 Desktop client
metadata:
  hermes:
    tags: [Google, Gmail, Calendar, Email, OAuth]
---

# Google Workspace — managed Hermes deployment

Use the repository-managed Google OAuth integration for Gmail and Calendar.
This deployment is already configured through GitHub Actions; do not start a
new OAuth flow from Telegram unless the user explicitly asks to reauthorize.

The API client installed at the path below uses only Python's standard library.
It does **not** import `googleapiclient`, `google-auth`, or any pip package.

## Routing rules

1. For every Gmail or Google Calendar request, use this skill first.
2. Do **not** switch to the `himalaya` skill merely because a request mentions
   email only. Himalaya is an unrelated App Password setup and is not required.
3. Do **not** run `pip`, `pip install`, `setup.py`, `ensurepip`, or attempt to
   alter system Python from an agent conversation.
4. Do not test for `googleapiclient`; this managed runtime does not use it.
5. Use the exact script and interpreter below. Do not rely on command discovery,
   shell aliases, a virtual environment, or `/usr/local/bin` being on `PATH`.
6. If the exact script is missing, report only that **Google Workspace Runtime
   Repair** must be run. Do not recommend Himalaya or manual browser checking.

## Required command prefix

Define this before every Gmail or Calendar operation:

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"
test -f "$GAPI" || { echo "Google Workspace Runtime Repair is required: $GAPI is missing" >&2; exit 1; }
```

Run the client only as:

```bash
/usr/bin/python3 "$GAPI"
```

`hermes-google-api` is also installed as a convenience, but the exact script
path above is authoritative and must be used when command discovery is unclear.

## Health check

Run this before the first Gmail or Calendar operation in a conversation:

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"
/usr/bin/python3 "$GAPI" check
```

A healthy response is JSON containing:

```json
{
  "authenticated": true,
  "calendarReachable": true,
  "runtime": "python-stdlib"
}
```

## Gmail

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"

# Search inbox messages from the last 30 days.
/usr/bin/python3 "$GAPI" gmail search "in:inbox newer_than:30d" --max 100

# Search unread messages.
/usr/bin/python3 "$GAPI" gmail search "in:inbox is:unread" --max 50

# Read a full message after obtaining its ID from search results.
/usr/bin/python3 "$GAPI" gmail get MESSAGE_ID

# List labels.
/usr/bin/python3 "$GAPI" gmail labels

# Send only after explicit user approval.
/usr/bin/python3 "$GAPI" gmail send --to user@example.com --subject "Subject" --body "Body"

# Reply only after explicit user approval.
/usr/bin/python3 "$GAPI" gmail reply MESSAGE_ID --body "Body"
```

### Inbox-summary procedure

For requests such as “review my Gmail inbox and summarize messages in the last
30 days”:

1. Run the standard-library health check above.
2. Search with `in:inbox newer_than:30d` and `--max 100`.
3. Use sender, subject, date, labels, and snippet to group routine mail.
4. Fetch full bodies with `gmail get` for messages that appear important,
   ambiguous, action-required, financial, travel-related, security-related, or
   time-sensitive.
5. Summarize by priority and topic. Clearly state how many messages were
   reviewed and whether 100 results were returned.
6. Do not mark messages read, modify labels, reply, send, archive, or delete
   unless the user explicitly requests that action.

## Calendar

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"

# Upcoming events.
/usr/bin/python3 "$GAPI" calendar list

# Explicit date range.
/usr/bin/python3 "$GAPI" calendar list --start 2026-07-15T00:00:00+08:00 --end 2026-07-16T00:00:00+08:00

# Create only after explicit user approval.
/usr/bin/python3 "$GAPI" calendar create --summary "Meeting" --start 2026-07-15T10:00:00+08:00 --end 2026-07-15T10:30:00+08:00
```

Do not create, update, delete, or invite attendees without explicit user
approval. Use Asia/Singapore when the user does not provide another timezone.

## Operator-managed setup

Setup and recovery are performed from GitHub Actions:

- **Google Workspace Runtime Repair** installs this skill and its dependency-free
  API script at the exact paths above and performs live Gmail/Calendar checks.
- **Google Workspace OAuth → provision-client** installs the Desktop client.
- **Google Workspace OAuth → send-auth-link** sends the consent link.
- **Google Workspace OAuth → exchange-callback** stores the token.
- **Google Workspace OAuth → check** verifies the OAuth helper path.
- **Google Workspace OAuth → revoke** revokes the token.

The complete browser-only procedure is documented in
`GOOGLE_WORKSPACE_SETUP.md` and `docs/google-workspace.md` in the deployment
repository.
