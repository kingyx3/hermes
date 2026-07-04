# Hermes Agent on GCP Free Tier — IaC + CI/CD

Infrastructure-as-code and CI/CD to run the **official
[Nous Research Hermes Agent](https://github.com/nousresearch/hermes-agent)** on a
Google Cloud **Free-Tier `e2-micro`** VM, configured to use **Gemini** as its
model provider, with the VM's `.hermes` and `workspace` synced back to this repo
**daily at midnight Singapore time**.

The VM is a thin runtime host; **all heavy work (Terraform, rendering, SSH,
rsync, git) runs on GitHub Actions runners**. Only **two GitHub secrets** are
required and **no repository variables** are needed.

---

## Contents

- [Architecture overview](#architecture-overview)
- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Required GitHub secrets](#required-github-secrets)
- [Optional repository variable overrides](#optional-repository-variable-overrides)
- [GCP service account & IAM](#gcp-service-account--iam)
- [One-time setup](#one-time-setup)
- [Deploying](#deploying)
- [What runs where](#what-runs-where-github-actions-vs-vm)
- [Hermes install & Gemini config](#hermes-install--gemini-configuration)
- [Operating the service](#operating-the-service)
- [Daily & manual sync](#daily--manual-sync)
- [Terraform & state](#terraform--state)
- [GCP Free Tier & cost warnings](#gcp-free-tier--cost-warnings)
- [Rotating secrets](#rotating-secrets)
- [Destroying infrastructure](#destroying-infrastructure)
- [Checking for leftover billable resources](#checking-for-leftover-billable-resources)
- [Security](#security)
- [Assumptions, limitations & troubleshooting](#assumptions-limitations--troubleshooting)

---

## Architecture overview

- One **`e2-micro`** VM (Debian 12), one **`pd-standard` 30 GB** boot disk, in a
  Free-Tier region (`us-central1` by default).
- **No external IPv4 in steady state.** The VM reaches the Gemini API for free
  via **Private Google Access** (no Cloud NAT). A temporary ephemeral external IP
  is attached only during bootstrap and then removed.
- SSH via **IAP TCP forwarding** with **ephemeral, per-run OS Login keys**.
- Hermes runs as `hermes-agent.service` (`hermes gateway run`, unattended,
  localhost-only).
- Sync pulls files with `rsync` on the runner and commits with `GITHUB_TOKEN`.

See [`docs/architecture.md`](docs/architecture.md) for a diagram and details.

## Repository structure

```
terraform/    GCP infra (VM, VPC/subnet w/ PGA, IAP firewall, SA, IAM), vars,
              outputs, Free-Tier validation, backend docs
scripts/      VM-side helpers (bootstrap, configure, service, ops) +
              runner-side helpers (render env, ephemeral SSH/IAP, sync) +
              sync-excludes.txt + systemd/env templates
.github/workflows/  deploy.yml, sync.yml, pr-validate.yml, destroy.yml
ansible/      intentionally unused (see ansible/README.md)
docs/         architecture, security, troubleshooting
```

## Prerequisites

- A GCP project with billing enabled and these APIs on:
  `compute.googleapis.com`, `iap.googleapis.com`, `iam.googleapis.com`,
  `storage.googleapis.com`.
- A **Google AI Studio** Gemini API key.
- Permission to add GitHub Actions secrets to this repo.

## Required GitHub secrets

Only these two (Settings → Secrets and variables → Actions → **Secrets**):

| Secret | Purpose |
|--------|---------|
| `GEMINI_API_KEY` | Gemini/Google AI Studio API key. Injected into the VM's env file at deploy time. |
| `GCP_SA_KEY` | JSON key of the CI service account. Used to authenticate to GCP. The **project ID is inferred** from its `project_id` field. |

**No GitHub repository variables are required.**

## Optional repository variable overrides

If present (Settings → Secrets and variables → Actions → **Variables**) they
override defaults; workflows work fine without them:

| Variable | Default |
|----------|---------|
| `GCP_PROJECT_ID` | inferred from `GCP_SA_KEY.project_id` |
| `GCP_REGION` | `us-central1` |
| `GCP_ZONE` | `us-central1-a` |
| `GCP_VM_NAME` | `hermes-agent` |
| `GCP_MACHINE_TYPE` | `e2-micro` |
| `GCP_DISK_SIZE_GB` | `30` |
| `HERMES_USER` | `hermes` |
| `HERMES_HOME` | `/home/hermes` |

`hermes_config_dir` (`$HERMES_HOME/.hermes`) and `workspace_dir`
(`$HERMES_HOME/workspace`) are derived automatically.

## GCP service account & IAM

Create a **minimally privileged** CI service account. Least-privilege roles:

- `roles/compute.instanceAdmin.v1`
- `roles/compute.networkAdmin`
- `roles/compute.securityAdmin`
- `roles/iam.serviceAccountUser`
- `roles/iap.tunnelResourceAccessor`
- `roles/storage.admin` (for the Terraform state bucket; or pre-create the
  bucket and grant only `roles/storage.objectAdmin`)

> `roles/editor` works as a **temporary bootstrap shortcut**, but switch to the
> least-privilege set for steady state. Full details in
> [`docs/security.md`](docs/security.md).

## One-time setup

```bash
# 1. Create the CI service account + key
gcloud iam service-accounts create hermes-ci --display-name="Hermes CI"
SA="hermes-ci@${PROJECT_ID}.iam.gserviceaccount.com"
for R in roles/compute.instanceAdmin.v1 roles/compute.networkAdmin \
         roles/compute.securityAdmin roles/iam.serviceAccountUser \
         roles/iap.tunnelResourceAccessor roles/storage.admin; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA}" --role="${R}"
done
gcloud iam service-accounts keys create sa-key.json --iam-account="${SA}"

# 2. Enable required APIs
gcloud services enable compute.googleapis.com iap.googleapis.com \
  iam.googleapis.com storage.googleapis.com

# 3. Add GitHub secrets (via the UI, or gh):
#    GCP_SA_KEY   = contents of sa-key.json
#    GEMINI_API_KEY = your Google AI Studio key
# Then delete the local key file:
rm -f sa-key.json
```

## Deploying

Run the **Deploy Hermes Agent** workflow (Actions → Deploy Hermes Agent → Run
workflow). Optional inputs: `enable_swap` (helps first install on e2-micro) and
`hermes_model` (defaults to `gemini-flash-latest`).

The workflow: authenticates to GCP → infers project ID → ensures the state
bucket → generates `terraform.auto.tfvars.json` → `init/fmt/validate/plan` →
`apply` with a temporary external IP → renders the env file + unit → opens
ephemeral SSH over IAP → installs the official Hermes Agent → writes
`/etc/hermes-agent/hermes.env` (root, 0600) → configures Gemini → installs &
restarts the systemd service → runs `hermes doctor` → tears down SSH → `apply`
to **remove the external IP** → **verifies no external IP remains**.

### How temporary bootstrap internet works

The default VM has no external IP. Bootstrap needs general internet (apt,
github, Node, uv), so Terraform attaches an **ephemeral** external IP only when
`allow_temporary_external_ip=true`. The deploy re-applies with `false` at the
end, and a verification step fails the run if any external IP is still attached.
The VM then reaches the Gemini API via **Private Google Access**.

## What runs where (GitHub Actions vs VM)

**GitHub Actions runners:** Terraform (install/fmt/validate/plan/apply),
`GCP_SA_KEY` parsing, tfvars generation, ephemeral SSH keygen + tunnel, env/unit
rendering, copying rendered files to the VM, rsync pull, sync diff/commit/push,
SSH/IP cleanup, external-IP verification, shellcheck.

**The VM (only):** the Hermes runtime (`hermes gateway run`), state under
`.hermes`, files under `workspace`, `/etc/hermes-agent/hermes.env`, minimal OS
packages, size-capped journald logs, and lightweight `hermes-ops` commands.

The VM never runs Terraform/Ansible, never holds GitHub credentials, never
commits to git, and never runs heavy build/test/lint/package jobs.

## Hermes install & Gemini configuration

- Installed with the official installer, non-interactive and lightweight:
  `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-setup --skip-browser`
  (browser/Playwright skipped — the VM does no browser automation or local
  inference). Installs under `~/.hermes` for the `hermes` user.
- **Gemini is a native Hermes provider.** Config (`~/.hermes/config.yaml`) is set
  non-interactively via `hermes config set`:
  `provider: gemini`, `base_url: https://generativelanguage.googleapis.com/v1beta`,
  model `gemini-flash-latest` (override with the `hermes_model` input).
- Hermes reads the key from the environment under **either** `GEMINI_API_KEY`
  **or** `GOOGLE_API_KEY`. We set **both** (to the same value) in
  `/etc/hermes-agent/hermes.env` for compatibility.

### `/etc/hermes-agent/hermes.env`

Rendered on the runner from `scripts/hermes.env.tmpl`, copied to the VM, and
installed **root:root, mode 0600**:

```
GEMINI_API_KEY=<secret>
GOOGLE_API_KEY=<same secret>
HERMES_HOME=/home/hermes/.hermes
HERMES_WORKSPACE=/home/hermes/workspace
```

It is never committed, never synced back, and never printed. The systemd unit
loads it via `EnvironmentFile=`.

### The systemd service

`hermes-agent.service` runs as the `hermes` user, loads the env file, sets
`HERMES_HOME`, works in `workspace`, runs `hermes gateway run` (unattended,
no public listener), restarts on failure with conservative limits, and logs to
journald (capped at 200 MB / 1 week).

## Operating the service

On the VM (or over IAP SSH), via the installed `hermes-ops` helper:

```bash
hermes-ops start | stop | restart | status | logs | doctor | update
```

`update` runs `hermes update` then restarts the service. To SSH in:

```bash
gcloud compute ssh hermes-agent --zone us-central1-a --tunnel-through-iap
```

## Daily & manual sync

The **Sync Hermes Snapshot** workflow runs on `cron: "0 16 * * *"` (16:00 UTC =
**00:00 Asia/Singapore**) and can also be run manually (inputs: `dry_run`,
`branch`). It: auths to GCP → opens ephemeral SSH over IAP → `rsync` pulls
`/home/hermes/.hermes` → `.hermes/` and `/home/hermes/workspace` → `workspace/`
applying [`scripts/sync-excludes.txt`](scripts/sync-excludes.txt) → normalizes
permissions → `git diff` → **commits only if changed** (message
`chore(sync): update Hermes workspace snapshot`, author `hermes-agent[bot]`) →
pushes to `main` with `GITHUB_TOKEN`.

**Branch protection fallback:** if a direct push to `main` is rejected, the job
pushes to the `hermes-sync` branch and opens/updates a PR for you to merge.

### What is synced vs excluded

- **Synced:** non-sensitive `.hermes` config/state (`config.yaml`, `SOUL.md`,
  `memories/`, `skills/`, `cron/`) and `workspace/` files.
- **Excluded:** `.env`/`auth.json`/credentials/tokens, `logs/`, `sessions/`,
  `cache/`, venvs, `node_modules`, `dist`/`build`, `.git`, terraform state,
  `*.pem`/`*.key`, `*secret*`/`*credential*`, downloaded models, and large
  archives. Full list in `scripts/sync-excludes.txt`.

The VM needs **no** GitHub PAT, deploy key, SSH key, git credentials, or push
cron — all git work happens on the runner.

## Terraform & state

State is stored in a **private, standard-class GCS bucket**
(`<project>-hermes-tfstate`, versioning on) created automatically by the deploy
workflow. Nothing sensitive is in state (`GEMINI_API_KEY` is never a variable).
See [`terraform/backend.md`](terraform/backend.md) for details and the
local-state fallback.

Terraform **validation blocks non-Free-Tier choices** by default: machine type
must be `e2-micro`; region must be `us-west1`/`us-central1`/`us-east1`; disk type
must be `pd-standard`; disk size ≤ 30 GB; SSH source must not be `0.0.0.0/0`. No
static IP, Cloud NAT, load balancer, snapshot, GPU, SSD/regional/extra disk,
MIG, or managed database is ever created.

## GCP Free Tier & cost warnings

Defaults target Google Cloud's Free Tier: **one `e2-micro`** (in
`us-west1`/`us-central1`/`us-east1`) with a **standard 30 GB** disk,
non-preemptible, no external IP in steady state.

> **Free-Tier limits and network pricing can change.** Always verify against
> current Google Cloud documentation and set a budget alert.

Free Tier includes a limited monthly **outbound (egress) transfer** allowance
(historically ~1 GB/month from North America, excluding some destinations);
traffic beyond it is billed. Keep sync payloads small (excludes help).

**These can create charges:** external IPv4 addresses, egress beyond the free
allowance, Cloud NAT, load balancers, snapshots, SSD/regional disks, disks
> 30 GB, extra VMs, GPUs, managed databases, artifact registries, large Cloud
Logging volumes, large Cloud Storage usage, and long bootstrap periods with a
public IP attached. This project avoids all of these by default, but **you
should create a budget alert** (Billing → Budgets & alerts).

## Rotating secrets

- **`GEMINI_API_KEY`:** update the GitHub secret → re-run **Deploy** (re-renders
  the env file and restarts the service) → revoke the old key in AI Studio.
- **`GCP_SA_KEY`:** `gcloud iam service-accounts keys create` a new key → update
  the GitHub secret → `gcloud iam service-accounts keys delete` the old one.

More in [`docs/security.md`](docs/security.md).

## Destroying infrastructure

Run the **Destroy Hermes Infrastructure** workflow and type `destroy` to
confirm. It runs `terraform destroy`. The **state bucket is not deleted** —
remove it manually for a clean slate:

```bash
gcloud storage rm -r "gs://${PROJECT_ID}-hermes-tfstate"
```

## Checking for leftover billable resources

```bash
gcloud compute instances list
gcloud compute disks list
gcloud compute addresses list          # static/ephemeral external IPs
gcloud compute snapshots list
gcloud compute forwarding-rules list   # load balancers
gcloud compute routers list            # Cloud NAT / routers
gcloud storage buckets list
# Billing / cost:  Console → Billing → Reports (and set a Budget alert)
```

## Security

Highlights (full notes in [`docs/security.md`](docs/security.md)): only two
secrets; no long-lived VM SSH key; no PAT/deploy key; ephemeral IAP SSH;
`GITHUB_TOKEN` for commits; VM secret file is root-owned 0600; Hermes and SSH
are never publicly exposed; `GEMINI_API_KEY`/`GCP_SA_KEY` never enter git,
Terraform state, or logs; secret-bearing files are excluded from sync.

## Assumptions, limitations & troubleshooting

- **e2-micro is small (1 GB RAM).** The install can be memory-tight; use the
  `enable_swap` deploy input if needed. No local LLM inference — Gemini serves
  all inference.
- **Gateway mode.** `hermes gateway run` is used as the unattended entrypoint; it
  serves locally and works without any messaging platform. To connect a chat
  platform later, add its token to the env file and re-deploy.
- **Free Tier is not free-forever or guaranteed** — verify current pricing and
  set a budget alert.
- Common issues and fixes: [`docs/troubleshooting.md`](docs/troubleshooting.md).
