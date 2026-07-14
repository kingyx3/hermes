# Personal Gmail and Google Calendar on Hermes

This setup connects one Google user account to Hermes without running `gcloud`,
SSH, SCP, Python, or any other command locally. The only local interaction is
using a browser to configure Google Cloud, GitHub, and Google's consent page.
All VM work is performed by the **Google Workspace OAuth** GitHub Actions
workflow through the repository's existing ephemeral SSH-over-IAP path.

## What this enables

Hermes can use its bundled Google Workspace commands to:

- search, read, send, reply to, and label Gmail messages;
- list, create, update, and delete events on calendars the account can edit.

The custom helper requests only these scopes:

- `https://www.googleapis.com/auth/gmail.modify`
- `https://www.googleapis.com/auth/calendar.events`

`gmail.modify` includes reading, composing, sending, and modifying Gmail, but it
does not permit bypassing Trash for immediate permanent deletion. The Calendar
scope permits viewing and editing events without granting calendar sharing,
ACL, or calendar-management permissions.

This intentionally avoids the broader Drive, Docs, Sheets, Contacts, and full
Calendar scopes currently requested by the upstream Hermes setup helper.

## Security model

- The OAuth Desktop client JSON is stored as the GitHub secret
  `GOOGLE_OAUTH_CLIENT_JSON`.
- The client is installed as
  `/home/hermes/.hermes/google_client_secret.json`, owned by `hermes`, mode
  `0600`.
- The refresh token is stored as `/home/hermes/.hermes/google_token.json`, owned
  by `hermes`, mode `0600`.
- OAuth URLs are delivered privately through Telegram and are never printed in
  this public repository's Actions logs.
- The one-time callback is supplied through a temporary GitHub secret instead
  of a workflow input or log.
- The nightly sync excludes token, credential, and secret files, so these files
  are not committed back to GitHub.
- The workflow uses PKCE and validates OAuth `state` before exchanging the code.

## Prerequisites

1. **Deploy Hermes Agent** has completed successfully at least once. This creates
   the VM and grants the CI service account its IAP, OS Login, and Service Usage
   permissions.
2. Telegram is configured:
   - GitHub secret `TELEGRAM_BOT_TOKEN`;
   - GitHub variable `TELEGRAM_ALLOWED_USERS` containing your numeric Telegram
     user ID.
3. You can edit Google Cloud OAuth settings and GitHub Actions secrets for this
   repository.

You may instead set `GOOGLE_OAUTH_TELEGRAM_CHAT_ID` as a repository variable if
the OAuth link should go to a different private Telegram chat. Otherwise the
workflow uses the first ID in `TELEGRAM_ALLOWED_USERS`.

## Step 1: Configure Google Auth Platform

Use the **same Google Cloud project** already used by this Hermes deployment.
That is the project selected by `GCP_PROJECT_ID`, or the `project_id` contained
in `GCP_SA_KEY` when no override is set.

Open Google Cloud Console, select that project, then open **Google Auth
Platform**.

### Branding

Configure at least:

- App name: for example `Hermes Personal Agent`
- User support email: your Google account
- Developer contact email: your Google account

### Audience

For a normal personal `@gmail.com` account:

1. Select **External**.
2. While the app is in Testing, add the exact Google account Hermes will use as
   a **Test user**.

For a managed Google Workspace account, **Internal** is available only when the
Cloud project belongs to that Workspace organization and only organization
members will authorize it.

### Data Access

Add the scopes below if the console asks you to declare scopes:

```text
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/calendar.events
```

Gmail classifies `gmail.modify` as a restricted scope. A private app used only
by its owner may show Google's unverified-app warning. Do not publish this OAuth
client for unrelated third parties without reviewing Google's verification and
user-data requirements.

### Testing versus Production

Google documents that an External OAuth app with publishing status **Testing**
receives refresh tokens that expire after seven days when it requests scopes
beyond basic identity. That is useful for an initial test, but it requires
weekly reauthorization.

After testing, review the warnings in Google Auth Platform and move the app to
**Production** if appropriate for your private use. Production does not make the
repository or token public; it changes the OAuth app's publishing state.

Official references:

- <https://developers.google.com/identity/protocols/oauth2/native-app>
- <https://developers.google.com/identity/protocols/oauth2#expiration>
- <https://developers.google.com/workspace/gmail/api/auth/scopes>
- <https://developers.google.com/workspace/calendar/api/auth>

## Step 2: Create a Desktop OAuth client

In **Google Auth Platform → Clients**:

1. Click **Create client**.
2. Select application type **Desktop app**.
3. Name it, for example `Hermes VM`.
4. Create it.
5. Download the JSON file.

Do not create a Web application client. The workflow expects the downloaded
JSON to contain an `installed` object.

## Step 3: Store the client JSON in GitHub

Open this repository in GitHub:

1. Go to **Settings → Secrets and variables → Actions → Secrets**.
2. Create a repository secret named `GOOGLE_OAUTH_CLIENT_JSON`.
3. Open the downloaded JSON file in a text editor.
4. Paste the complete JSON object as the secret value.

The JSON's project must match the Hermes GCP project. The workflow rejects a
client from a different project so it can safely enable the Gmail and Calendar
APIs in the correct project.

## Step 4: Provision the VM

Open **Actions → Google Workspace OAuth → Run workflow** and select:

```text
provision-client
```

This run:

1. enables `gmail.googleapis.com` and `calendar-json.googleapis.com`;
2. validates the Desktop OAuth JSON without printing it;
3. opens an ephemeral SSH-over-IAP tunnel;
4. installs the least-privilege OAuth helper;
5. installs the client JSON with mode `0600`;
6. installs Google API dependencies inside Hermes' own Python environment;
7. removes all temporary files and the SSH key.

A successful run ends with `GOOGLE_WORKSPACE_PROVISIONED` and prints only
non-secret paths and scope names.

## Step 5: Send the authorization link privately

Run the workflow again with:

```text
send-auth-link
```

The workflow creates a new PKCE authorization session on the VM and sends the
Google authorization URL to your private Telegram chat. It does not put the URL
in the Actions log.

Open the link in your normal browser, sign in with the Google account Hermes
should use, and approve the requested Gmail and Calendar access.

Google then redirects the browser to an address beginning with:

```text
http://127.0.0.1:1/?code=...
```

The page will usually show a connection error. That is expected: port 1 is used
only as a loopback redirect target and there is no local web server.

Copy the **entire URL from the browser address bar**, including the `code`,
`scope`, and `state` query parameters. Use the newest browser tab and callback;
a code can be exchanged only once and expires quickly.

## Step 6: Exchange the callback safely

In GitHub:

1. Go to **Settings → Secrets and variables → Actions → Secrets**.
2. Create a temporary repository secret named
   `GOOGLE_OAUTH_CALLBACK_URL`.
3. Paste the complete `http://127.0.0.1:1/?code=...` URL as its value.
4. Run **Google Workspace OAuth** with:

```text
exchange-callback
```

The workflow passes the callback to the VM over standard input, exchanges the
one-time code, stores the refresh token, and performs live Gmail and Calendar
API checks. Neither the callback nor token is printed.

After the run succeeds, **delete `GOOGLE_OAUTH_CALLBACK_URL` immediately**. The
code is single-use, but keeping it is unnecessary.

## Step 7: Verify at any time

Run the workflow with:

```text
check
```

It refreshes the token when necessary, calls Gmail `users.getProfile`, and
lists at most one upcoming event from the primary calendar. A healthy result is:

```text
AUTHENTICATED: Gmail and Calendar API checks passed
```

## Step 8: Use it through Hermes

Example requests to your Hermes Telegram bot:

```text
Show my unread Gmail messages from the last 24 hours.
```

```text
What is on my primary calendar tomorrow in Asia/Singapore?
```

```text
Create a calendar event called Dentist on Friday from 3:00 PM to 4:00 PM
Asia/Singapore.
```

```text
Draft a reply to the latest email from Alex, but do not send it until I approve.
```

For safety, explicitly tell Hermes when it must ask before sending email,
modifying labels, deleting events, or inviting attendees.

## Reauthorize, rotate, or revoke

### Reauthorize

Run these workflow actions in order:

1. `send-auth-link`
2. replace `GOOGLE_OAUTH_CALLBACK_URL` with the newest callback URL
3. `exchange-callback`
4. delete `GOOGLE_OAUTH_CALLBACK_URL`

A successful exchange replaces the existing token.

### Rotate the OAuth client

1. Create a new Desktop OAuth client in the same project.
2. Replace `GOOGLE_OAUTH_CLIENT_JSON`.
3. Run `provision-client`.
4. Complete reauthorization.
5. Delete the old OAuth client in Google Cloud after the new token passes
   `check`.

### Revoke

Run the workflow with:

```text
revoke
```

The helper asks Google to revoke the token and deletes the VM token and pending
OAuth session. It leaves the Desktop client installed so you can authorize
again later.

## Troubleshooting

### `Missing GOOGLE_OAUTH_CLIENT_JSON`

Create the repository secret with the full downloaded Desktop OAuth JSON, then
run `provision-client` again.

### OAuth client project does not match

Create the Desktop OAuth client in the same Cloud project used by the Hermes
infrastructure. This workflow intentionally does not operate across two GCP
projects.

### `Error 403: access_denied`

Confirm that:

- the OAuth app Audience is External for a personal Gmail account;
- your exact Google account is listed as a test user while the app is Testing;
- a Workspace administrator has not blocked the client or requested scopes.

Generate a new link after correcting the configuration.

### `redirect_uri_mismatch`

The OAuth client must be a **Desktop app**, not a Web application. Replace the
GitHub client secret with the correct downloaded JSON and rerun
`provision-client`.

### `token exchange failed`

The callback may have expired, been used already, or come from an older tab.
Run `send-auth-link` again and exchange only the newest callback URL.

### Token stops working after seven days

The OAuth app is probably External and still in Testing. Review the Google Auth
Platform publishing status and the official refresh-token expiration guidance.

### `Hermes Python venv not found`

Run **Deploy Hermes Agent** successfully first. The OAuth workflow installs
packages into Hermes' existing venv rather than changing the system Python.

### Telegram link was not delivered

Confirm:

- `TELEGRAM_BOT_TOKEN` is valid;
- `GOOGLE_OAUTH_TELEGRAM_CHAT_ID` is set to a numeric private chat ID, or the
  first value in `TELEGRAM_ALLOWED_USERS` is your numeric Telegram user ID;
- you have started a private chat with the bot so it is allowed to message you.

### Shared calendars are missing

The helper grants event access, but Hermes commands default to the `primary`
calendar. Specify the desired calendar ID when supported by the bundled skill.
The helper does not grant calendar-list management or sharing/ACL permissions.
