# Security notes

## Secret flow

| Secret | Where it lives | Where it must NEVER be |
|--------|----------------|------------------------|
| `GEMINI_API_KEY` | GitHub secret → runner memory → rendered into `/etc/hermes-agent/hermes.env` (root:root, 0600) on the VM | git, Terraform state, logs, `~/.hermes/.env`, synced files |
| `GCP_SA_KEY` | GitHub secret → `google-github-actions/auth` credentials file on the runner (auto-masked) | git, Terraform state, logs, the VM |
| `TELEGRAM_BOT_TOKEN` (optional) | GitHub secret → runner memory → rendered into `/etc/hermes-agent/hermes.env` (root:root, 0600) | same as `GEMINI_API_KEY` |
| `HERMES_EXTRA_SECRETS` (optional) | GitHub secret (multi-line `KEY=VALUE`) → appended verbatim to `/etc/hermes-agent/hermes.env`, never echoed | same as `GEMINI_API_KEY` |

- `GEMINI_API_KEY` and `TELEGRAM_BOT_TOKEN` are each masked in logs
  (`::add-mask::`) and reach Hermes only via the systemd `EnvironmentFile`.
  Hermes reads them from the process env, so no secret is written under
  `~/.hermes`.
- `HERMES_EXTRA_SECRETS` is arbitrary and multi-line, so it is **not**
  individually `::add-mask::`'d line-by-line; instead `render-env.sh` never
  echoes it (same discipline as the other secrets), and GitHub Actions
  auto-masks any verbatim occurrence of the full secret value in logs
  regardless.
- None of these are **ever** a Terraform variable, so none enters state.
- Rendered secret files are deleted from the runner at the end of every job;
  runners are ephemeral anyway.

## SSH / access

- No long-lived VM SSH private key exists as a GitHub secret.
- Each run generates a fresh ed25519 keypair, registers the public key via OS
  Login with a short TTL, tunnels through IAP, and removes the key afterward
  (`scripts/ssh-iap.sh down`).
- Firewall permits tcp:22 **only** from the IAP range `35.235.240.0/20`. SSH is
  never open to `0.0.0.0/0`.
- Hermes runs localhost-only; no public service listener.

## Telegram gateway (optional)

Enabling `TELEGRAM_BOT_TOKEN` gives Hermes an internet-facing entry point
(Telegram's servers, not a listener on the VM — no firewall change is
needed). Treat the bot token like any other credential (masked in logs,
never committed), and:

- **Always set `TELEGRAM_ALLOWED_USERS`** to your numeric Telegram user ID.
  Without it, unknown DMs fall through to Hermes's pairing flow
  (`unauthorized_dm_behavior`, default `pair`) rather than being fully
  blocked.
- Group chats need their own allowlist (`TELEGRAM_GROUP_ALLOWED_USERS` /
  `TELEGRAM_GROUP_ALLOWED_CHATS`) — being allowed in DMs does not extend to
  groups.
- Rotate `TELEGRAM_BOT_TOKEN` the same way as other secrets (see Rotation &
  cleanup) if it's ever exposed; revoke the old one via BotFather
  (`/revoke`).

## GCP IAM

The deploy workflow is **self-bootstrapping**: at the start of each run it
enables the APIs it needs and self-grants its operational roles. The CI service
account (`GCP_SA_KEY`) therefore needs only **two seed roles**, granted once by a
project Owner:

- `roles/serviceusage.serviceUsageAdmin` — enable required APIs (Cloud Resource
  Manager, Service Usage, Compute, IAM, IAP, OS Login)
- `roles/resourcemanager.projectIamAdmin` — self-grant the operational roles

The **Bootstrap deploy service account IAM roles** step then self-grants:

- `roles/storage.admin` — create/use the Terraform state bucket + remote state
- `roles/compute.admin` — VPC/subnet/firewall/instance + instance IAM bindings
- `roles/iam.serviceAccountAdmin` — create the VM's dedicated service account
- `roles/iam.serviceAccountUser` — attach that service account to the VM
- `roles/iap.admin` — IAP tunnel instance IAM + opening the SSH tunnel
- `roles/compute.osAdminLogin` — SSH into the VM as an OS Login admin

**Security tradeoff.** `roles/resourcemanager.projectIamAdmin` lets the SA grant
itself (or anyone) any role, so a leaked `GCP_SA_KEY` is effectively project
admin. That is the cost of a hands-off, self-contained pipeline.

**Least-privilege alternative (no self-granting).** Grant the SA only the
operational roles directly, pre-enable the APIs (see the root `README.md`
setup), then remove the `Enable required GCP APIs` and `Bootstrap deploy service
account IAM roles` steps from `.github/workflows/deploy.yml`. Minimal
operational set:

- `roles/compute.admin` — or the narrower `roles/compute.instanceAdmin.v1` +
  `roles/compute.networkAdmin` + `roles/compute.securityAdmin`
- `roles/iam.serviceAccountAdmin` + `roles/iam.serviceAccountUser`
- `roles/iap.tunnelResourceAccessor` — IAP SSH (Terraform also binds this and
  `roles/compute.osAdminLogin` at the instance level, so project-level IAP admin
  is not required)
- `roles/storage.admin` — Terraform state bucket (or `roles/storage.objectAdmin`
  if you pre-create the bucket)

The VM's own service account holds no project roles (only
`logging-write`/`monitoring-write` scopes).

**Debug Hermes Agent** (`.github/workflows/debug.yml`) reads no application
secrets and does not self-grant anything; it relies on the project-level
`roles/iap.admin` + `roles/compute.osAdminLogin` bindings Deploy already
self-granted, so it only works after Deploy has run at least once.

## Rotation & cleanup

- **Rotate `GEMINI_API_KEY`**: update the GitHub secret, re-run Deploy (it
  re-renders `hermes.env` and restarts the service). Revoke the old key in
  Google AI Studio.
- **Rotate `TELEGRAM_BOT_TOKEN`**: update the GitHub secret, re-run Deploy.
  Revoke the old token via BotFather (`/mybots` → Bot Settings → API Token →
  Revoke).
- **Rotate `GCP_SA_KEY`**: create a new key for the SA
  (`gcloud iam service-accounts keys create`), update the GitHub secret, delete
  the old key (`gcloud iam service-accounts keys delete`).
- **Remove ephemeral SSH**: `scripts/ssh-iap.sh down` runs on every job; to
  purge manually, `gcloud compute os-login ssh-keys list` then
  `... ssh-keys remove --key=<fingerprint>`.
- **Audit resources**: see the cost/audit section of the root `README.md`.
