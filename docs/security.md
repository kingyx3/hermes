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

## Least-privilege GCP IAM

The CI service account (`GCP_SA_KEY`) needs, at minimum:

- `roles/compute.instanceAdmin.v1` — create/manage the VM
- `roles/compute.networkAdmin` — VPC/subnet
- `roles/compute.securityAdmin` — firewall + instance IAM bindings
- `roles/iam.serviceAccountUser` — attach the VM service account
- `roles/iap.tunnelResourceAccessor` — IAP SSH (also bound at instance level by TF)
- `roles/storage.admin` — create/use the Terraform state bucket (or
  `roles/storage.objectAdmin` if you pre-create the bucket)

Broader `roles/editor` works as a **temporary bootstrap shortcut**, but move to
the least-privilege set above for steady state. The VM's own service account
holds no project roles (only `logging-write`/`monitoring-write` scopes).

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
