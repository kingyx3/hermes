# ansible/ — intentionally unused

This project provisions the VM with Terraform plus a short sequence of
idempotent shell scripts (`scripts/*.sh`) driven over SSH from the GitHub
Actions runner. That is lighter and simpler than adding an Ansible control
layer, so Ansible is **not** used and this directory is a placeholder.

If you later prefer Ansible:

- Generate the inventory on the runner (never commit it) pointing at the VM via
  the IAP tunnel (`ansible_host=localhost ansible_port=2222`), using the
  ephemeral key from `scripts/ssh-iap.sh`.
- Run `ansible-playbook` **from the runner**, never from the VM.
- Keep the same responsibilities the shell scripts have today: install deps,
  create the `hermes` user/dirs, run the official installer, render the env file
  and systemd unit, enable/restart the service.
