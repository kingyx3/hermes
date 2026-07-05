# ---------------------------------------------------------------------------
# Core GCP identifiers
# ---------------------------------------------------------------------------
variable "project_id" {
  description = "GCP project ID. Inferred by CI from the project_id field of GCP_SA_KEY unless the optional GCP_PROJECT_ID repo variable is set."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "GCP region. Must be a Free-Tier-eligible region."
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-west1", "us-central1", "us-east1"], var.region)
    error_message = "region must be one of the Free-Tier-eligible regions: us-west1, us-central1, or us-east1."
  }
}

variable "zone" {
  description = "GCP zone. Must reside within a Free-Tier-eligible region."
  type        = string
  default     = "us-central1-a"

  validation {
    condition = anytrue([
      startswith(var.zone, "us-west1-"),
      startswith(var.zone, "us-central1-"),
      startswith(var.zone, "us-east1-"),
    ])
    error_message = "zone must be within us-west1, us-central1, or us-east1 (e.g. us-central1-a)."
  }
}

# ---------------------------------------------------------------------------
# VM shape — locked to Free-Tier by validation
# ---------------------------------------------------------------------------
variable "machine_type" {
  description = "Compute Engine machine type. Free Tier allows exactly e2-micro."
  type        = string
  default     = "e2-micro"

  validation {
    condition     = var.machine_type == "e2-micro"
    error_message = "machine_type must be e2-micro to remain Free-Tier compatible. Any other type may create charges and is rejected by default."
  }
}

variable "disk_size_gb" {
  description = "Boot disk size in GB. Free Tier allows up to 30 GB of standard persistent disk."
  type        = number
  default     = 30

  validation {
    condition     = var.disk_size_gb >= 10 && var.disk_size_gb <= 30
    error_message = "disk_size_gb must be between 10 and 30. Disks larger than 30 GB exceed the Free-Tier allowance and may create charges."
  }
}

variable "disk_type" {
  description = "Boot disk type. Free Tier requires standard persistent disk (pd-standard)."
  type        = string
  default     = "pd-standard"

  validation {
    condition     = var.disk_type == "pd-standard"
    error_message = "disk_type must be pd-standard. SSD (pd-ssd/pd-balanced) and regional disks are not Free-Tier eligible and are rejected by default."
  }
}

# ---------------------------------------------------------------------------
# Networking / access
# ---------------------------------------------------------------------------
variable "allow_temporary_external_ip" {
  description = "When true, attaches an EPHEMERAL external IPv4 to the VM. Used ONLY during bootstrap so the VM can install OS packages / Hermes, then set back to false to strip it. The default steady state has NO external IP. An attached external IPv4 and its outbound transfer MAY create charges."
  type        = bool
  default     = false
}

variable "iap_source_range" {
  description = "Source CIDR permitted to reach tcp:22 for IAP TCP forwarding. This is Google's fixed IAP range; do not widen it to 0.0.0.0/0."
  type        = string
  default     = "35.235.240.0/20"

  validation {
    condition     = var.iap_source_range != "0.0.0.0/0"
    error_message = "iap_source_range must not be 0.0.0.0/0. SSH must never be exposed to the public internet."
  }
}

variable "cicd_members" {
  description = "Optional list of additional IAM principals (e.g. serviceAccount:foo@bar.iam.gserviceaccount.com) granted IAP tunnel + OS Login access. The CI service account itself is granted automatically."
  type        = list(string)
  default     = []
}

variable "deploy_sa_email" {
  description = "Email of the CI/deploy service account (the one authenticating this apply), granted IAP tunnel + OS Login access automatically. Resolved by the calling workflow from GCP_SA_KEY's client_email field, not looked up in-provider (see main.tf for why)."
  type        = string

  validation {
    condition     = length(trimspace(var.deploy_sa_email)) > 0
    error_message = "deploy_sa_email must not be empty -- pass the CI service account's client_email (e.g. via jq on GOOGLE_APPLICATION_CREDENTIALS in the calling workflow)."
  }
}

# ---------------------------------------------------------------------------
# Naming / Hermes layout
# ---------------------------------------------------------------------------
variable "vm_name" {
  description = "Name of the Compute Engine VM."
  type        = string
  default     = "hermes-agent"
}

variable "github_repo" {
  description = "The owner/repo this deployment belongs to (from github.repository). Recorded as a VM label/metadata for traceability."
  type        = string
  default     = ""
}

variable "hermes_user" {
  description = "Dedicated non-root Linux user that owns and runs Hermes Agent."
  type        = string
  default     = "hermes"
}

variable "hermes_home" {
  description = "Home directory of the Hermes user."
  type        = string
  default     = "/home/hermes"
}

variable "hermes_config_dir" {
  description = "Hermes config/home directory (HERMES_HOME)."
  type        = string
  default     = "/home/hermes/.hermes"
}

variable "workspace_dir" {
  description = "Hermes workspace directory."
  type        = string
  default     = "/home/hermes/workspace"
}

variable "labels" {
  description = "Optional labels applied to created resources."
  type        = map(string)
  default     = {}
}
