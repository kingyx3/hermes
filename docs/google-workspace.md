# Gmail and Google Calendar on Hermes

Hermes manages Gmail and Google Calendar through the `core` authorization
service. Existing tokens and runtime commands are unchanged.

Use the single **Google Workspace Setup** workflow with:

```text
service: core
```

Available actions are `provision-client`, `send-auth-link`,
`exchange-callback`, `check`, and `disconnect`.

The complete browser-only procedure and shared secret names are maintained in
[`GOOGLE_WORKSPACE_SETUP.md`](../GOOGLE_WORKSPACE_SETUP.md).

Google Contacts is authorized separately with `service=contacts`, so enabling
Contacts does not replace the Gmail or Calendar token.
