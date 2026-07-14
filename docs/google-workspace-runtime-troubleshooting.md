# Google Workspace runtime dependency troubleshooting

## Symptom

The **Google Workspace OAuth** workflow completes successfully, including the
`check` action, but Hermes later replies with a message similar to:

> The required Google API Python libraries are missing, and the environment is
> restricted from installing them directly via pip.

This can appear after **Deploy Hermes Agent** even though the OAuth token is
still valid.

## Why the workflow check can pass while Hermes fails

The OAuth workflow invokes `/usr/local/bin/hermes-google-workspace`, which
selects Hermes' private Python virtual environment explicitly. The bundled
Google Workspace skill, however, invokes `python` through the gateway's runtime
`PATH`.

Older versions of this repository's systemd unit replaced `PATH` with:

```text
/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin
```

That omitted both supported Hermes virtual-environment locations:

```text
/home/hermes/.hermes/hermes-agent/venv/bin
/home/hermes/.hermes/hermes-agent/.venv/bin
```

As a result, the workflow could import the Google libraries while an agent-run
skill resolved a system Python interpreter that could not.

A Hermes update can also rebuild its virtual environment. The OAuth client and
refresh token remain under `/home/hermes/.hermes`, but optional Python packages
inside the replaced environment may no longer be present.

## Repository fix

The deployment now provides two safeguards:

1. The systemd service places both possible Hermes venv `bin` directories at
   the beginning of `PATH`, so bundled skills use the correct interpreter.
2. On every deploy, when
   `/home/hermes/.hermes/google_client_secret.json` exists, bootstrap verifies
   and, if needed, installs:
   - `google-api-python-client`
   - `google-auth-oauthlib`
   - `google-auth-httplib2`

The Google packages are installed into Hermes' venv, not system Python.

## Recovery steps

After merging the fix:

1. Run **Actions → Deploy Hermes Agent → Run workflow**.
2. Wait for the deploy and post-deploy smoke check to complete.
3. Run **Actions → Google Workspace OAuth** with action `check`.
4. Ask Hermes to read Gmail or list calendar events again.

You normally do **not** need to repeat OAuth authorization. The Desktop OAuth
client and refresh token are preserved across a normal redeploy.

## When reauthorization is actually needed

Repeat `send-auth-link` and `exchange-callback` only when the `check` action
reports an invalid, revoked, expired, or insufficient-scope token. A missing
Python-library message is a runtime dependency problem, not an OAuth consent
problem.

## If the problem continues

Run the following workflows in order:

1. **Google Workspace OAuth → `provision-client`**
2. **Deploy Hermes Agent**
3. **Google Workspace OAuth → `check`**

`provision-client` repairs the helper and dependencies immediately; the deploy
then installs the corrected service `PATH` and makes dependency repair
persistent for future redeploys.
