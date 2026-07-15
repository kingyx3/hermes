# Google Workspace runtime and Telegram troubleshooting

## Symptoms

OAuth and runtime-repair workflows report success, but Telegram still says:

- `googleapiclient` or other Google Python libraries are missing;
- pip is unavailable;
- `hermes-google-api` cannot be found; or
- Himalaya should be used instead.

These messages can come from stale skill instructions or from an older
`google_api.py`. They do not prove that the OAuth token is invalid.

## Current runtime does not use googleapiclient

The repository-managed runtime client is:

```text
/home/hermes/.hermes/skills/productivity/google-workspace/scripts/google_api.py
```

It uses only Python's standard library:

- `urllib` for OAuth refresh and Google REST requests;
- `json` for request and response data;
- `email` and `base64` for Gmail messages;
- `argparse` for its CLI.

It does not import `googleapiclient`, `google-auth`, or `google-auth-oauthlib`.
The active skill invokes it with the fixed interpreter `/usr/bin/python3`, so
normal Gmail and Calendar usage is independent of Hermes' venv and pip.

The Google authentication libraries remain relevant only to the separate OAuth
setup helper and **Google Workspace OAuth** workflow.

## Why a previous runtime repair could still appear broken

Earlier runtime repair versions verified a wrapper under `/usr/local/bin` that
selected Hermes' venv. That test could pass over SSH while Telegram later used
stale bundled instructions, plain `python`, or a different command-discovery
path.

The current repair is stricter. It:

1. overwrites the active `SKILL.md`;
2. overwrites the exact active `scripts/google_api.py` path;
3. installs convenience wrappers in both `/usr/local/bin` and
   `/home/hermes/.local/bin`;
4. restarts `hermes-agent.service`;
5. calls the active script directly with `/usr/bin/python3`;
6. performs live Gmail and Calendar requests without importing any optional
   package.

## Recovery steps

After merging the current fix:

1. Run **Actions → Google Workspace Runtime Repair → Run workflow**.
2. Confirm the log contains exactly:

   ```text
   AGENT_RUNTIME_READY_STDLIB: active skill client passed Gmail and Calendar without googleapiclient.
   ```

3. Send a **new** Telegram message:

   ```text
   Review my Gmail inbox and summarize messages in the last 30 days.
   ```

A new message matters because a prior conversation turn may already contain the
incorrect conclusion that Google libraries are required.

Expected terminal commands include:

```bash
GAPI="${HERMES_HOME:-$HOME/.hermes}/skills/productivity/google-workspace/scripts/google_api.py"
/usr/bin/python3 "$GAPI" check
/usr/bin/python3 "$GAPI" gmail search "in:inbox newer_than:30d" --max 100
```

The trace should not show `himalaya --version`, `pip`, or an import check for
`googleapiclient`.

## Full repair sequence

Run these workflows in order when the runtime marker is not produced:

1. **Deploy Hermes Agent**
2. wait for the automatic **Google Workspace Runtime Repair** run
3. **Google Workspace OAuth → `provision-client`**
4. complete `send-auth-link` and `exchange-callback` only when no token exists
5. run **Google Workspace Runtime Repair** manually

Do not reauthorize merely because Telegram mentions missing libraries.
Reauthorize only when the runtime repair or OAuth check reports a missing,
revoked, expired, or insufficient-scope token.

## Interpreting runtime-repair results

### `AGENT_RUNTIME_READY_STDLIB`

The exact active skill script ran through `/usr/bin/python3`, refreshed the
token when necessary, reached Gmail and Calendar, and did not require
`googleapiclient`.

### `GOOGLE_RUNTIME_READY_NOT_AUTHENTICATED`

The dependency-free client and skill are installed, but `google_token.json` is
absent. Complete the authorization link and callback exchange documented in
[`google-workspace.md`](google-workspace.md), then rerun runtime repair.

### `Google Workspace Runtime Repair is required: ...google_api.py is missing`

The active skill file exists but its managed script was not installed. Rerun
runtime repair and inspect its file-install step.

### OAuth refresh failure

The token exists but Google rejected its refresh token. Generate a fresh auth
link, exchange the newest callback, delete the temporary callback secret, and
rerun runtime repair.

### Network or DNS failure

The VM must have outbound HTTPS access to Google's OAuth, Gmail, and Calendar
endpoints. With Telegram enabled, the deployment normally retains an ephemeral
external IPv4. Check the deploy workflow's steady-state egress verification.

## Operator instruction for an existing Telegram conversation

When Hermes is repeating the old dependency conclusion, send:

```text
Discard the previous Google Python dependency diagnosis. The active
Google Workspace client is standard-library-only. Load the google-workspace
skill again and execute the exact /usr/bin/python3 command documented there.
Do not check for googleapiclient, use pip, or load Himalaya.
```

Starting a new Telegram conversation/message after service restart is still the
preferred verification method.
