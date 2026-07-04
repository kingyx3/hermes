# Troubleshooting

## Deploy fails at "Establish ephemeral SSH over IAP"

- Ensure the IAP API is enabled: `gcloud services enable iap.googleapis.com`.
- The CI SA needs `roles/iap.tunnelResourceAccessor` and OS Login access (bound
  at instance level by Terraform; project-level `roles/compute.osAdminLogin`
  also works).
- OS Login must be on (Terraform sets `enable-oslogin=TRUE` in VM metadata).

## SSH connects but sudo/rsync fails during sync

- The CI principal needs **OS Admin Login** (passwordless sudo). Terraform binds
  `roles/compute.osAdminLogin` at the instance; if you overrode IAM, restore it.

## `hermes doctor` reports the Gemini key as invalid

- Confirm the GitHub secret `GEMINI_API_KEY` is a valid Google AI Studio key.
- Re-run Deploy to re-render `/etc/hermes-agent/hermes.env` and restart.
- Check the service picked up the env: on the VM,
  `sudo systemctl show hermes-agent -p EnvironmentFiles`.

## VM cannot reach the Gemini API in steady state

- Private Google Access must be enabled on the subnet (Terraform sets it). Verify:
  `gcloud compute networks subnets describe hermes-agent-subnet --region <region> --format='value(privateIpGoogleAccess)'` → `True`.
- Confirm there is no leftover deny-egress firewall rule.

## Service won't start

- `sudo journalctl -u hermes-agent -n 200` (or `hermes-ops logs`).
- Verify the binary path: `ls -l /home/hermes/.local/bin/hermes`.
- Re-run `hermes-ops doctor`.

## Sync commits nothing

- Expected when the VM produced no new `.hermes`/workspace changes — the job
  skips the commit by design.

## Sync push rejected

- Branch protection on `main` blocks `GITHUB_TOKEN`. The job auto-falls back to
  the `hermes-sync` branch and opens a PR — merge it. Or allow the
  `github-actions` bot to push to `main`.

## e2-micro runs out of memory during first install

- Re-run Deploy with the `enable_swap` input checked (adds a 1 GiB swap file).

## Terraform validation rejects my settings

- By design: non-Free-Tier machine types, regions, disk types, or disk sizes
  > 30 GB fail fast. Use `e2-micro`, a us-west1/us-central1/us-east1 region,
  `pd-standard`, and ≤ 30 GB.
