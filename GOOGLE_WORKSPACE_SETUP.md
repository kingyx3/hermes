# Google Workspace setup and operations

Hermes uses one browser-only setup workflow and one idempotent runtime-repair
workflow for all Google integrations.

## Least-privilege authorization domains

| Setup service | Google services | OAuth scope(s) | Token |
|---|---|---|---|
| `core` | Gmail, Calendar | `gmail.modify`, `calendar.events` | `~/.hermes/google_token.json` |
| `drive` | Drive, Docs, Sheets | `drive.file` | `~/.hermes/google_drive_token.json` |
| `contacts` | Google Contacts | `contacts` | `~/.hermes/google_contacts_token.json` |

Drive remains restricted to the app-owned folder named `hermes` and every
validated descendant beneath it. Contacts authorization is separate so it can
be enabled without changing existing Gmail, Calendar, or Drive tokens.

## Google Cloud configuration

Use **Google Auth Platform → Data Access** to declare:

```text
https://www.googleapis.com/auth/gmail.modify
https://www.googleapis.com/auth/calendar.events
https://www.googleapis.com/auth/drive.file
https://www.googleapis.com/auth/contacts
```

The workflows idempotently enable:

```text
gmail.googleapis.com
calendar-json.googleapis.com
drive.googleapis.com
docs.googleapis.com
sheets.googleapis.com
people.googleapis.com
```

The existing OAuth Desktop app JSON remains in:

```text
GOOGLE_OAUTH_CLIENT_JSON
```

## Single setup workflow

Open **Actions → Google Workspace Setup**.

Inputs:

- `service`: `core`, `drive`, or `contacts`
- `action`: `provision-client`, `send-auth-link`, `exchange-callback`, `check`,
  or `disconnect`

### Provision

Run once, or safely rerun after workflow changes:

```text
service: core
action: provision-client
```

This installs every managed Google runtime and OAuth helper, enables all
required APIs, validates the Desktop client, and restarts Hermes.

### Authorize a service

For the desired service:

1. Run `send-auth-link`.
2. Open the private Telegram link.
3. Copy the complete failed `http://127.0.0.1:1/?code=...` URL.
4. Store it temporarily as `GOOGLE_OAUTH_CALLBACK_URL`.
5. Run `exchange-callback`.
6. Delete `GOOGLE_OAUTH_CALLBACK_URL`.

Contacts success marker:

```text
GOOGLE_CONTACTS_AUTHENTICATED: read/write Contacts access is ready.
```

Drive success marker:

```text
DRIVE_WORKSPACE_AUTHENTICATED: app-owned hermes folder is ready.
```

## Workflow consolidation

The former **Google Workspace OAuth** and **Google Drive Workspace OAuth**
workflows are replaced by **Google Workspace Setup**.

Existing Gmail, Calendar, Contacts, and Drive tokens remain valid. Enabling
recursive folders does not change the `drive.file` scope and does not require
Drive reauthorization.

The setup workflow accepts the former `GOOGLE_DRIVE_OAUTH_CALLBACK_URL` as a
temporary fallback, but `GOOGLE_OAUTH_CALLBACK_URL` is now the standard secret
for every service.

## Runtime repair

**Google Workspace Runtime Repair** runs automatically after successful Hermes
deployments and may be dispatched manually. It:

- enables all required Google APIs;
- installs all managed OAuth helpers, runtime clients, wrappers, and skills;
- preserves tokens and Drive workspace state;
- restarts Hermes;
- validates each service that has a token.

Expected markers:

```text
AGENT_RUNTIME_READY_STDLIB
GOOGLE_CONTACTS_READY
GOOGLE_DRIVE_FOLDER_READY
```

Missing optional authorization produces a clear marker without breaking other
services:

```text
GOOGLE_CONTACTS_AUTHORIZATION_REQUIRED
GOOGLE_DRIVE_AUTHORIZATION_REQUIRED
```

## Contacts behavior

Hermes can list, search, read, create, update, clear fields on, and delete
Google Contacts. It must obtain explicit confirmation before every create,
update, clear, or delete operation.

Example Telegram requests:

```text
Find Ada's phone number in my Google Contacts.
```

```text
Create a Google Contact for Ada Lovelace with email ada@example.com.
```

```text
Update Ada Lovelace's phone number to +65 6123 4567.
```

## Drive behavior

Hermes can create folders at the managed root or under another managed folder,
list a chosen folder, show the complete tree, create Docs and Sheets in any
managed subfolder, and move managed items between managed folders.

The runtime validates the full parent chain for every request. Items outside the
`hermes` tree remain inaccessible. It also blocks moving a folder into itself or
one of its descendants.

Examples:

```text
Create a Trips folder in hermes, then create a Japan subfolder inside it.
```

```text
Move Japan Trip Plan Nov 2026 into the Japan folder.
```

```text
Create a Japan Budget sheet inside hermes/Trips/Japan.
```

Hermes must obtain explicit confirmation before creating, renaming, moving,
editing, or trashing folders and files. Listing and reading do not require
confirmation.

After merging a Drive runtime change, run **Google Workspace Runtime Repair**
once to install the updated client and skill on the VM. OAuth does not need to
be repeated.

## Local disconnect

Run `action=disconnect` for the selected service. This deletes only the local
token and pending OAuth state. It does not remotely revoke other grants issued
to the same OAuth client.
