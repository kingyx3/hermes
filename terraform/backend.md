# Terraform state

Terraform state is stored **remotely in a private GCS bucket** (`backend "gcs"`
in `versions.tf`). State is never committed to the repository (see `.gitignore`).

## Why GCS remote state

CI runners are ephemeral, so local state would be lost between workflow runs and
would risk orphaned, billable GCP resources. A GCS backend keeps a single source
of truth that both the deploy and destroy workflows share, with state locking.

## How the bucket is configured

The `deploy.yml` workflow creates the bucket on first run (idempotent) with
Free-Tier-friendly, private settings:

```bash
gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access \
  --public-access-prevention
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

- **Bucket name**: `${PROJECT_ID}-hermes-tfstate` (globally unique, derived from
  the project ID — no secret needed).
- **Prefix / object path**: `terraform/state`.
- **Location**: the same Free-Tier region as the VM (default `us-central1`).
- **Class**: `STANDARD`.
- **Access**: uniform bucket-level access + public-access-prevention (private).
- **Versioning**: enabled, so a bad apply can be rolled back.

`terraform init` receives these via `-backend-config`:

```bash
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=terraform/state"
```

## Cost note

A GCS bucket under **5 GB of Standard storage in a US region** is within the
Google Cloud Storage always-free allowance, and Terraform state is a few KB.
However, **Free-Tier limits and pricing can change**, and heavy object
versioning or operations could eventually create small charges. See the cost
section of the root `README.md`.

## Never in state

- `GEMINI_API_KEY` / `GOOGLE_API_KEY` are **never** passed as Terraform
  variables and therefore never land in state. They are rendered only into the
  VM-side `/etc/hermes-agent/hermes.env` during deployment.
- The GCP service-account key (`GCP_SA_KEY`) is used only to authenticate the
  provider and is never written to state.

## Local-state fallback (not recommended)

If you must avoid the bucket, delete the `backend "gcs" {}` block from
`versions.tf` and run Terraform locally. Tradeoff: state lives only on your
machine, CI cannot manage the resources, and a lost state file can orphan
billable resources that you must then clean up manually (see the "check for
leftover billable resources" section of the README).
