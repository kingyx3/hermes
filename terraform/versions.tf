terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0.0, < 7.0.0"
    }
  }

  # Remote state lives in a private, standard-class GCS bucket.
  # The bucket name and prefix are injected at `terraform init` time via
  # `-backend-config` by the deploy workflow, so nothing sensitive or
  # environment-specific is committed here. See terraform/backend.md.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
