# Hermes Agent on GCP Free Tier — IaC + CI/CD

Infrastructure-as-code and CI/CD to run the **official
[Nous Research Hermes Agent](https://github.com/nousresearch/hermes-agent)** on a
Google Cloud **Free-Tier `e2-micro`** VM, configured to use **Gemini** as its
model provider, with the VM's `.hermes` and `workspace` synced back to this repo
**daily at midnight Singapore time**.

The VM is a thin runtime host; **all heavy work (Terraform, rendering, SSH,
rsync, git) runs on GitHub Actions runners**. Only **two GitHub secrets** are
required and **no repository variables** are needed. Everything else —
including an optional **Telegram gateway** so you can talk to the agent
directly — is opt-in via additional secrets/variables; see
[Telegram (optional)](#telegram-optional) and
[Controlling Hermes via env vars](#controlling-hermes-via-env-vars).

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
- [Telegram (optional)](#telegram-optional)
- [Controlling Hermes via env vars](#controlling-hermes-via-env-vars)
- [Operating the service](#operating-the-service)
- [Debugging](#debugging)
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
- Hermes runs as `hermes-agent.service` (`hermes gateway`, unattended,
  localhost-only, with an optional Telegram gateway — see below).
- Sync pulls files with `rsync` on the runner and commits with `GITHUB_TOKEN`.

See [`docs/architecture.md`](docs/architecture.md) for a diagram and details.

## Repository structure

```
terraform/    GCP infra (VM, VPC/subnet w/ PGA, IAP firewall, SA, IAM), vars,
              outputs, Free-Tier validation, backend docs
scripts/      VM-side helpers (bootstrap, configure, service, ops) +
              runner-side helpers (render env, ephemeral SSH/IAP, sync) +
              sync-excludes.txt + systemd/env templates
.github/workflows/  deploy.yml, debug.yml, sync.yml, pr-validate.yml, destroy.yml
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

### Optional secrets (Telegram + generic extras)

Add these only if you want them; leaving them unset keeps the corresponding
feature disabled. See [Telegram (optional)](#telegram-optional) and
[Controlling Hermes via env vars](#controlling-hermes-via-env-vars).

| Secret | Purpose |
|--------|---------|
| `TELEGRAM_BOT_TOKEN` | Telegram bot API token from [@BotFather](https://t.me/BotFather). Telegram **auto-activates** in Hermes purely from this being set — no other config needed. |
| `HERMES_EXTRA_SECRETS` | Multi-line `KEY=VALUE` block of any other secret runtime env vars (e.g. another provider's API key), appended verbatim to the VM's env file. Never printed in logs. |

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
| `TELEGRAM_ALLOWED_USERS` | *(unset — see security note below)* |
| `TELEGRAM_GROUP_ALLOWED_USERS` | *(unset)* |
| `TELEGRAM_GROUP_ALLOWED_CHATS` | *(unset)* |
| `TELEGRAM_HOME_CHANNEL` | *(unset)* |
| `TELEGRAM_REACTIONS` | *(unset)* |
| `HERMES_EXTRA_ENV` | *(unset)* — multi-line `KEY=VALUE` block of any other non-secret runtime env vars |

`hermes_config_dir` (`$HERMES_HOME/.hermes`) and `workspace_dir`
(`$HERMES_HOME/workspace`) are derived automatically.

## GCP service account & IAM

The deploy workflow is **self-bootstrapping**: on each run it enables the GCP
APIs it needs and self-grants its operational IAM roles. The CI service account
therefore needs only **two seed roles**, granted once by a project Owner:

- `roles/serviceusage.serviceUsageAdmin` — enable the required APIs (including
  Cloud Resource Manager, which project IAM changes are served by)
- `roles/resourcemanager.projectIamAdmin` — self-grant the operational roles below

With those, the **Bootstrap deploy service account IAM roles** step grants the
SA the rest of what the deploy uses: `roles/storage.admin` (state bucket +
remote state), `roles/compute.admin` (VPC/subnet/firewall/instance + instance
IAM), `roles/iam.serviceAccountAdmin` + `roles/iam.serviceAccountUser` (create
and attach the VM's SA), `roles/iap.admin` (IAP tunnel IAM + SSH tunnel), and
`roles/compute.osAdminLogin` (SSH via OS Login).

> `roles/resourcemanager.projectIamAdmin` lets the SA grant itself any role, so a
> leaked key is high-impact. To run without self-granting privileges, pre-grant
> the operational set and drop the bootstrap/enable steps — see the
> least-privilege alternative in [`docs/security.md`](docs/security.md).

## One-time setup

```bash
# 1. Create the CI service account + key, granting only the two seed roles.
#    The deploy self-grants the operational roles (and enables APIs) on each run.
gcloud iam service-accounts create hermes-ci --display-name="Hermes CI"
SA="hermes-ci@${PROJECT_ID}.iam.gserviceaccount.com"
for R in roles/serviceusage.serviceUsageAdmin \
         roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA}" --role="${R}"
done
gcloud iam service-accounts keys create sa-key.json --iam-account="${SA}"

# 2. (Optional) The deploy enables required APIs itself via serviceUsageAdmin.
#    To pre-enable them anyway:
gcloud services enable cloudresourcemanager.googleapis.com serviceusage.googleapis.com \
  compute.googleapis.com iam.googleapis.com iap.googleapis.com oslogin.googleapis.com

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

**The VM (only):** the Hermes runtime (`hermes gateway`), state under
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
`HERMES_HOME`, works in `workspace`, runs `hermes gateway` (unattended,
no public listener; picks up Telegram and any other configured messaging
platform purely from the env file), restarts on failure with conservative
limits, and logs to journald (capped at 200 MB / 1 week).

## Telegram (optional)

Link Hermes to Telegram so you can message it directly (it also still runs
fine standalone with no messaging platform configured):

1. Create a bot via [@BotFather](https://t.me/BotFather) (`/newbot`) to get a
   token like `123456789:ABCdefGHIjklMNOpqrSTUvwxYZ`.
2. Get your numeric Telegram user ID from [@userinfobot](https://t.me/userinfobot)
   (**not** your `@username`).
3. Add the GitHub secret `TELEGRAM_BOT_TOKEN` = the bot token.
4. Add the GitHub repo variable `TELEGRAM_ALLOWED_USERS` = your numeric user ID
   (comma-separate for multiple people). **Strongly recommended** — without an
   allowlist, unknown DMs fall through to Hermes's pairing flow instead of
   being fully blocked.
5. Re-run **Deploy Hermes Agent**. Telegram auto-activates purely from
   `TELEGRAM_BOT_TOKEN` being present in the env file — no config.yaml change
   is needed. The bot should come online within seconds of the service
   restarting.

Optional variables for group chats and more: `TELEGRAM_GROUP_ALLOWED_USERS`,
`TELEGRAM_GROUP_ALLOWED_CHATS`, `TELEGRAM_HOME_CHANNEL`, `TELEGRAM_REACTIONS`
(`true`/`false`). By default the bot can't see regular group messages
(Telegram privacy mode) — disable it via BotFather (`/mybots` → Bot Settings →
Group Privacy → Turn off) and re-add the bot to the group, or promote it to
group admin.

## Controlling Hermes via env vars

Every runtime setting Hermes reads from the environment can be pushed from
GitHub with no workflow code change:

- **Named settings** (Telegram, model, etc.) are explicit GitHub
  secrets/variables, listed above — edit one and re-run **Deploy**.
- **Anything else** — another model provider's API key, `TERMINAL_BACKEND`, or
  any future Hermes env var — goes in the generic passthrough:
  - `HERMES_EXTRA_ENV` (repo **variable**, non-secret): one `KEY=VALUE` pair
    per line.
  - `HERMES_EXTRA_SECRETS` (GitHub **secret**): same format, for values that
    must never appear in a log.

Both are appended verbatim to `/etc/hermes-agent/hermes.env` by
`scripts/render-env.sh` and take effect on the next **Deploy** run (which
re-renders the env file and restarts the service). Use `env-check` (see
[Debugging](#debugging)) to confirm a key landed on the VM without ever
printing its value.

## Operating the service

On the VM (or over IAP SSH), via the installed `hermes-ops` helper:

```bash
hermes-ops start | stop | restart | status | logs | journal-boot | env-check | doctor | update
```

- `logs` tails the last `LINES` (default 200) journal lines; `journal-boot`
  dumps the full journal since the last boot (crash-loop debugging).
- `env-check` lists which env var **keys** are set in the VM's env file, with
  values redacted — confirms e.g. `TELEGRAM_BOT_TOKEN` made it across without
  ever printing it.
- `update` runs `hermes update` then restarts the service.

To SSH in directly:

```bash
gcloud compute ssh hermes-agent --zone us-central1-a --tunnel-through-iap
```

## Debugging

The **Debug Hermes Agent** workflow (Actions → Debug Hermes Agent → Run
workflow) runs any of the `hermes-ops` actions above over an ephemeral IAP SSH
session and prints the result in the run's log — no manual SSH needed to check
on the agent. Inputs: `action` (`logs` default, `status`, `journal-boot`,
`env-check`, `doctor`, `restart`) and `lines` (for `logs`).

It reads no application secrets itself (`GEMINI_API_KEY`, `TELEGRAM_BOT_TOKEN`,
etc. never pass through this workflow) and requires **Deploy** to have run at
least once, since it relies on the IAP/OS-Login IAM bindings deploy
self-grants. It shares a concurrency group with Deploy/Destroy/Sync (they all
touch the same VM), so it queues rather than races if one of those is
already running.

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
secrets required (Telegram/extras are opt-in); no long-lived VM SSH key; no
PAT/deploy key; ephemeral IAP SSH; `GITHUB_TOKEN` for commits; VM secret file
is root-owned 0600; Hermes and SSH are never publicly exposed; all secrets
(`GEMINI_API_KEY`, `GCP_SA_KEY`, `TELEGRAM_BOT_TOKEN`, `HERMES_EXTRA_SECRETS`)
never enter git, Terraform state, or logs; secret-bearing files are excluded
from sync; **set `TELEGRAM_ALLOWED_USERS`** if you enable the Telegram
gateway, or unknown users fall through to Hermes's pairing flow.

## Assumptions, limitations & troubleshooting

- **e2-micro is small (1 GB RAM).** The install can be memory-tight; use the
  `enable_swap` deploy input if needed. No local LLM inference — Gemini serves
  all inference.
- **Gateway mode.** `hermes gateway` is used as the unattended entrypoint; it
  serves locally and works without any messaging platform configured. See
  [Telegram (optional)](#telegram-optional) to connect one, or
  [Controlling Hermes via env vars](#controlling-hermes-via-env-vars) for any
  other runtime config — add the secret/variable and re-run **Deploy**.
- **Free Tier is not free-forever or guaranteed** — verify current pricing and
  set a budget alert.
- Common issues and fixes: [`docs/troubleshooting.md`](docs/troubleshooting.md).
