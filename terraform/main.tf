# ===========================================================================
# Nous Research Hermes Agent — GCP Free-Tier infrastructure
#
# Provisions exactly ONE e2-micro VM with a standard 30 GB boot disk, no
# external IP in steady state, Private Google Access for free egress to
# Google APIs (incl. the Gemini API), and IAP-only SSH ingress.
#
# NOT created (would break Free Tier / spec): static IP, Cloud NAT, load
# balancers, snapshots, GPUs, SSD/regional/extra disks, managed instance
# groups, Cloud SQL/Redis/Filestore/GKE/Run/Artifact Registry.
# ===========================================================================

locals {
  common_labels = merge(
    {
      managed-by = "terraform"
      component  = "hermes-agent"
    },
    var.github_repo != "" ? { github-repo = replace(lower(var.github_repo), "/", "_") } : {},
    var.labels,
  )
}

# ---------------------------------------------------------------------------
# Network: minimal custom VPC + one subnet with Private Google Access.
# Private Google Access lets the no-external-IP VM reach *.googleapis.com
# (including generativelanguage.googleapis.com for Gemini) at no charge and
# WITHOUT Cloud NAT.
# ---------------------------------------------------------------------------
resource "google_compute_network" "hermes" {
  name                    = "${var.vm_name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "hermes" {
  name                     = "${var.vm_name}-subnet"
  ip_cidr_range            = "10.10.0.0/28"
  region                   = var.region
  network                  = google_compute_network.hermes.id
  private_ip_google_access = true
}

# ---------------------------------------------------------------------------
# Firewall: the ONLY ingress is tcp:22 from Google's IAP range. No 0.0.0.0/0.
# Egress is left at the implied default (allow all) so the VM can reach the
# Gemini API (via Private Google Access when it has no external IP, or via the
# temporary external IP during bootstrap).
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.vm_name}-allow-iap-ssh"
  network       = google_compute_network.hermes.id
  direction     = "INGRESS"
  source_ranges = [var.iap_source_range]
  target_tags   = ["hermes-agent"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# ---------------------------------------------------------------------------
# Dedicated least-privilege service account attached to the VM. It is given
# only logging/monitoring write scope; it holds no project-wide roles.
# ---------------------------------------------------------------------------
resource "google_service_account" "vm" {
  account_id   = "${var.vm_name}-vm"
  display_name = "Hermes Agent VM service account"
}

# ---------------------------------------------------------------------------
# The e2-micro VM.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "hermes" {
  name         = var.vm_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["hermes-agent"]
  labels       = local.common_labels

  # Free Tier requires a non-preemptible, automatically-restarting VM.
  scheduling {
    preemptible        = false
    automatic_restart  = true
    provisioning_model = "STANDARD"
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = var.disk_size_gb
      type  = var.disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.hermes.id

    # An external IP is attached ONLY when allow_temporary_external_ip = true
    # (bootstrap). In steady state this block is absent -> no external IPv4.
    dynamic "access_config" {
      for_each = var.allow_temporary_external_ip ? [1] : []
      content {
        # Ephemeral (no reserved/static address).
        network_tier = "STANDARD"
      }
    }
  }

  # OS Login lets CI inject short-lived, per-run SSH keys instead of storing a
  # long-lived VM private key as a GitHub secret.
  metadata = {
    enable-oslogin = "TRUE"
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["logging-write", "monitoring-write"]
  }

  # The boot disk size can grow (never shrink) without recreating the VM; do
  # not let a re-apply that only toggles the external IP fight the image.
  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}

# ---------------------------------------------------------------------------
# IAM: allow the CI service account (and any extra cicd_members) to open IAP
# tunnels to the VM and log in via OS Login as a normal (non-admin) user.
# ---------------------------------------------------------------------------
locals {
  # The CI principal is passed in explicitly (var.deploy_sa_email, resolved by
  # the calling workflow from the same GCP_SA_KEY JSON used to authenticate).
  # NOT derived from data.google_client_openid_userinfo: that data source is
  # known to silently return an empty email with service-account-key auth on
  # several terraform-provider-google versions (hashicorp/terraform-provider-google#16431),
  # which would produce an invalid "serviceAccount:" IAM member and fail apply.
  iap_members = toset(concat(
    ["serviceAccount:${var.deploy_sa_email}"],
    var.cicd_members,
  ))
}

resource "google_iap_tunnel_instance_iam_member" "ssh" {
  for_each = local.iap_members
  project  = var.project_id
  zone     = var.zone
  instance = google_compute_instance.hermes.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}

# OS Admin Login (passwordless sudo on the VM) is required so CI can install
# packages / write /etc during bootstrap and read the hermes-owned files during
# sync (via `sudo -u hermes rsync`). Scoped to this single instance only.
resource "google_compute_instance_iam_member" "oslogin" {
  for_each      = local.iap_members
  project       = var.project_id
  zone          = var.zone
  instance_name = google_compute_instance.hermes.name
  role          = "roles/compute.osAdminLogin"
  member        = each.value
}
