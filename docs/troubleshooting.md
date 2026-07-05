# Troubleshooting

## Deploy fails at "Establish ephemeral SSH over IAP"

- Ensure the IAP API is enabled: `gcloud services enable iap.googleapis.com`.
- The CI SA needs `roles/iap.tunnelResourceAccessor` and OS Login access (bound
  at instance level by Terraform; project-level `roles/compute.osAdminLogin`
  also works).
- OS Login must be on (Terraform sets `enable-oslogin=TRUE` in VM metadata).
- Terraform binds these to `var.deploy_sa_email`, which the workflow resolves
  directly from `GCP_SA_KEY`'s `client_email` (not looked up dynamically in
  Terraform, since `google_client_openid_userinfo` is known to silently return
  an empty email with service-account-key auth on some provider versions). If
  IAP/OS-Login access is missing for an unexpected principal, check the
  `deploy_sa_email` value in the generated `terraform.auto.tfvars.json`.

## My Deploy/Debug/Sync run for the VM is stuck "Waiting"

- `deploy.yml`, `destroy.yml`, `debug.yml`, and `sync.yml` all share the
  `hermes-infra` concurrency group and queue rather than run in parallel,
  since they all touch the same VM/SSH session. This is by design — e.g. a
  `debug.yml` restart can't land mid-way through a live `terraform apply`, and
  the daily sync can't rsync a VM whose config Deploy is actively rewriting.
  Wait for the earlier run to finish (or cancel it, if it's stuck).

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

- `sudo journalctl -u hermes-agent -n 200` (or `hermes-ops logs`, or the
  **Debug Hermes Agent** workflow with `action=logs`/`journal-boot` if you'd
  rather not SSH in by hand).
- Verify the binary path: `ls -l /home/hermes/.local/bin/hermes`.
- Re-run `hermes-ops doctor`.
- If the unit fails immediately with an "unknown command" style error, the
  `ExecStart` line may be stale (there is no `hermes gateway run` subcommand,
  only `hermes gateway`) — confirm
  `sudo systemctl cat hermes-agent | grep ExecStart` shows `hermes gateway`
  with nothing after it, and re-run Deploy if not.

## Telegram bot doesn't come online / doesn't respond

- Confirm the token reached the VM without printing it:
  `hermes-ops env-check` (or the **Debug Hermes Agent** workflow,
  `action=env-check`) should list `TELEGRAM_BOT_TOKEN`.
- `hermes gateway` auto-activates Telegram purely from `TELEGRAM_BOT_TOKEN`
  being present — no `config.yaml` change is needed. If it's missing, the
  GitHub secret wasn't set, or Deploy hasn't been re-run since it was added.
- If the bot is online in DMs but silent in a group, Telegram's **privacy
  mode** is likely blocking it — disable it via BotFather (`/mybots` → Bot
  Settings → Group Privacy → Turn off) and re-add the bot to the group, or
  promote it to group admin.
- If nobody can get a response at all, check `TELEGRAM_ALLOWED_USERS` is set
  to your numeric Telegram user ID (from `@userinfobot`), not your
  `@username`.

## I want to check on / debug the VM without SSHing in manually

- Use the **Debug Hermes Agent** workflow (Actions → Debug Hermes Agent → Run
  workflow): `status`, `logs`, `journal-boot`, `env-check`, `doctor`, or
  `restart`. It requires Deploy to have run at least once (it relies on the
  IAP/OS-Login IAM bindings Deploy self-grants).

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
