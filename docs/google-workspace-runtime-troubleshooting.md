# Google Workspace runtime and Telegram troubleshooting

## Symptoms

The **Google Workspace OAuth** workflow completes successfully, including the
`check` action, but Telegram shows one or both of these behaviors:

- Hermes says the Google API Python libraries are missing or cannot be installed.
- Hermes loads the `himalaya` skill and runs `himalaya --version`, even though
  Google OAuth is already configured.

These are runtime or skill-routing problems. They do not normally mean the
Google OAuth token is invalid.

## Why OAuth check can pass while Hermes fails

The OAuth workflow invokes `/usr/local/bin/hermes-google-workspace`, which
selects Hermes' private Python virtual environment explicitly. Older bundled
Google Workspace instructions invoked `google_api.py` using plain `python`.
Depending on the shell environment, that could resolve system Python instead of
Hermes' venv.

A Hermes update can also rebuild its virtual environment. The OAuth client and
refresh token remain under `/home/hermes/.hermes`, while optional Python
packages inside the replaced environment may need to be installed again.

## Why Hermes selected Himalaya

The upstream Google Workspace skill currently tells the agent that an
email-only request should use the related `himalaya` skill. That advice is
appropriate for a user choosing between two fresh setups, but it is incorrect
for this deployment after Google OAuth is already configured.

For example, the request:

```text
Review my Gmail inbox and summarize messages in the last 30 days.
```

may be classified as “email only,” causing Hermes to inspect Himalaya even
though the repository-managed Gmail integration is ready.

## Repository-managed fix

This repository installs three safeguards:

1. The Hermes venv directories are present on the gateway service `PATH`.
2. Deploy bootstrap verifies the Google API Python packages whenever a Google
   OAuth client is configured.
3. **Google Workspace Runtime Repair** installs:
   - `/usr/local/bin/hermes-google-workspace` for OAuth checks;
   - `/usr/local/bin/hermes-google-api` for Gmail and Calendar operations;
   - a managed `google-workspace` skill overlay that prefers configured Google
     OAuth for email-only requests and does not fall back to Himalaya.

The API wrapper selects Hermes' venv directly and runs the bundled
`google_api.py`; it never depends on plain `python` shell resolution.

The repair workflow runs automatically after each successful **Deploy Hermes
Agent** workflow. It can also be run manually.

## Recovery steps

After merging the fix:

1. Run **Actions → Google Workspace Runtime Repair → Run workflow**.
2. Confirm the log contains:

   ```text
   AGENT_RUNTIME_READY: managed Google skill and Gmail API command passed.
   ```

3. Run **Actions → Google Workspace OAuth** with action `check`.
4. Ask Hermes again:

   ```text
   Review my Gmail inbox and summarize messages in the last 30 days.
   ```

The Telegram trace should show the `google-workspace` skill and
`hermes-google-api`, not the Himalaya skill.

You normally do **not** need to repeat OAuth authorization. The Desktop OAuth
client and refresh token survive normal redeploys.

## Full repair sequence

When a normal runtime-repair run does not pass, run these workflows in order:

1. **Google Workspace OAuth → `provision-client`**
2. **Google Workspace Runtime Repair**
3. **Google Workspace OAuth → `check`**
4. **Deploy Hermes Agent** if the gateway itself is unhealthy
5. Wait for the automatic post-deploy **Google Workspace Runtime Repair** run

Do not configure Himalaya or a Gmail App Password unless you deliberately want
a separate mail-client integration.

## When reauthorization is actually needed

Repeat `send-auth-link` and `exchange-callback` only when the OAuth `check`
action reports an invalid, revoked, expired, or insufficient-scope token.
Missing libraries, a missing wrapper, or Himalaya routing are not OAuth consent
failures.

## Interpreting runtime-repair results

### `AGENT_RUNTIME_READY`

The managed skill is installed, OAuth is valid, and a Gmail API command passed
using the exact wrapper the skill is instructed to call.

### `GOOGLE_RUNTIME_READY_NOT_AUTHENTICATED`

The wrapper and skill are installed, but `google_token.json` is absent. Complete
the authorization link and callback exchange documented in
[`google-workspace.md`](google-workspace.md).

### `Hermes Python venv not found`

Run **Deploy Hermes Agent** successfully, then rerun runtime repair.

### Google dependency installation fails

The VM needs outbound access while dependencies are repaired. With Telegram
enabled, this deployment normally retains an ephemeral external IPv4 for
outbound polling and API access. Check the deploy workflow and VM egress mode.
