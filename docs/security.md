# Security notes

## Secret flow

| Secret | Where it lives | Where it must NEVER be |
|--------|----------------|------------------------|
| `GEMINI_API_KEY` | GitHub secret → runner memory → rendered into `/etc/hermes-agent/hermes.env` (root:root, 0600) on the VM | git, Terraform state, logs, `~/.hermes/.env`, synced files |
| `GCP_SA_KEY` | GitHub secret → `google-github-actions/auth` credentials file on the runner (auto-masked) | git, Terraform state, logs, the VM |

- The Gemini key is masked in logs (`::add-mask::`) and reaches Hermes only via
  the systemd `EnvironmentFile`. Hermes reads `GEMINI_API_KEY`/`GOOGLE_API_KEY`
  from the process env, so no secret is written under `~/.hermes`.
- `GEMINI_API_KEY` is **never** a Terraform variable, so it never enters state.
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

## Rotation & cleanup

- **Rotate `GEMINI_API_KEY`**: update the GitHub secret, re-run Deploy (it
  re-renders `hermes.env` and restarts the service). Revoke the old key in
  Google AI Studio.
- **Rotate `GCP_SA_KEY`**: create a new key for the SA
  (`gcloud iam service-accounts keys create`), update the GitHub secret, delete
  the old key (`gcloud iam service-accounts keys delete`).
- **Remove ephemeral SSH**: `scripts/ssh-iap.sh down` runs on every job; to
  purge manually, `gcloud compute os-login ssh-keys list` then
  `... ssh-keys remove --key=<fingerprint>`.
- **Audit resources**: see the cost/audit section of the root `README.md`.
