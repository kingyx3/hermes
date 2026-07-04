output "vm_name" {
  description = "Name of the Compute Engine VM."
  value       = google_compute_instance.hermes.name
}

output "zone" {
  description = "Zone the VM runs in."
  value       = google_compute_instance.hermes.zone
}

output "region" {
  description = "Region the VM runs in."
  value       = var.region
}

output "internal_ip" {
  description = "Internal (RFC1918) IP of the VM."
  value       = google_compute_instance.hermes.network_interface[0].network_ip
}

output "external_ip" {
  description = "External IPv4 of the VM. Empty in the default steady state (no external IP); populated only while allow_temporary_external_ip = true during bootstrap."
  value = try(
    google_compute_instance.hermes.network_interface[0].access_config[0].nat_ip,
    "",
  )
}

output "has_external_ip" {
  description = "Whether an external IPv4 is currently attached. Must be false in steady state."
  value       = length(google_compute_instance.hermes.network_interface[0].access_config) > 0
}

output "ssh_user" {
  description = "Login user for the VM. With OS Login, CI uses the OS-Login-derived username; the Hermes runtime user is hermes_user."
  value       = var.hermes_user
}

output "iap_ssh_command" {
  description = "Command to SSH to the VM through IAP (no external IP required)."
  value       = "gcloud compute ssh ${google_compute_instance.hermes.name} --zone ${var.zone} --tunnel-through-iap --project ${var.project_id}"
}

output "iap_tunnel_command" {
  description = "Command to open a local IAP TCP tunnel to the VM's SSH port (used for rsync during sync)."
  value       = "gcloud compute start-iap-tunnel ${google_compute_instance.hermes.name} 22 --local-host-port=localhost:2222 --zone ${var.zone} --project ${var.project_id}"
}

output "hermes_user" {
  description = "Dedicated Linux user that runs Hermes Agent."
  value       = var.hermes_user
}

output "hermes_home" {
  description = "Home directory of the Hermes user."
  value       = var.hermes_home
}

output "hermes_config_dir" {
  description = "Hermes config/home directory (HERMES_HOME)."
  value       = var.hermes_config_dir
}

output "workspace_dir" {
  description = "Hermes workspace directory."
  value       = var.workspace_dir
}
