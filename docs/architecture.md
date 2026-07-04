# Architecture

## Overview

```
                 GitHub Actions runner (ephemeral, does the heavy lifting)
                 ┌──────────────────────────────────────────────────────┐
                 │ terraform init/plan/apply   render env+unit           │
                 │ parse GCP_SA_KEY -> project  ephemeral SSH keygen      │
                 │ rsync pull   git diff/commit/push (GITHUB_TOKEN)       │
                 └───────────────┬───────────────────────┬──────────────┘
       auth: GCP_SA_KEY          │ IAP TCP (tcp:22)       │ commits
                                 ▼                        ▼
                    ┌─────────────────────────┐    ┌───────────────┐
                    │  GCP e2-micro VM         │    │ kingyx3/hermes│
                    │  - no external IP        │    │ .hermes/      │
                    │  - Private Google Access │    │ workspace/    │
                    │  - hermes-agent.service  │    └───────────────┘
                    │  - /etc/hermes-agent/    │
                    │      hermes.env (0600)   │──── Gemini API (via
                    └─────────────────────────┘     Private Google Access,
                       Nous Research Hermes Agent    generativelanguage.googleapis.com)
```

## Thin VM, fat runner

The VM is a **thin persistent runtime host**. It only:

- runs the official Nous Research Hermes Agent as `hermes-agent.service`
  (`hermes gateway run`, unattended, localhost-only, no public listener);
- stores runtime state under `/home/hermes/.hermes`;
- stores workspace files under `/home/hermes/workspace`;
- holds `/etc/hermes-agent/hermes.env` (root:root, 0600);
- runs minimal OS packages and writes size-capped journald logs;
- answers lightweight ops commands via `hermes-ops` (start/stop/restart/
  status/logs/doctor/update).

**Everything else runs on GitHub Actions runners**: Terraform, config
rendering, ephemeral SSH, rsync, diffing, commits/pushes, verification. The VM
never runs Terraform/Ansible, never holds GitHub credentials, and never pushes
to git.

## Egress without Cloud NAT (the key design choice)

The steady-state VM has **no external IPv4**. It still reaches the Gemini API
because the subnet enables **Private Google Access**, which routes traffic to
Google APIs (`*.googleapis.com`, including
`generativelanguage.googleapis.com`) at no charge and **without Cloud NAT**.

General internet (apt, github.com, Node, uv) is only needed during **bootstrap**.
For that phase the deploy workflow attaches a **temporary ephemeral external
IP**, then strips it and verifies none remains.

## Access model

- CI authenticates to GCP with the `GCP_SA_KEY` service-account key.
- SSH uses **IAP TCP forwarding** + **ephemeral, per-run OS Login keys** (short
  TTL). No long-lived VM SSH key is stored as a secret.
- Repo commits use the built-in `GITHUB_TOKEN`. No PAT/deploy key.

## Why no Ansible

Provisioning is a short, linear sequence of idempotent shell steps
(`scripts/*.sh`) driven over SSH from the runner. Terraform + these scripts are
lighter and simpler than adding an Ansible control layer, so the `ansible/`
directory is intentionally unused. The "if Ansible is used" requirements are
therefore satisfied by not using it.
