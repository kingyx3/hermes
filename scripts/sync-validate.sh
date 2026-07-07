#!/usr/bin/env bash
# Validate staged sync snapshot files before they are committed.
# The validator unstages unsafe files instead of failing the whole sync so a
# single generated runtime artifact does not block memory/skill/workspace backup.
set -euo pipefail

MAX_GIT_BLOB_BYTES="${MAX_GIT_BLOB_BYTES:-50000000}"

log() { printf '[sync-validate] %s\n' "$*"; }

blocked=()

block_file() {
  local path="$1" reason="$2"
  blocked+=("${path}")
  log "Skipping ${path}: ${reason}"
}

is_probably_executable_binary() {
  local path="$1"
  if ! command -v file >/dev/null 2>&1; then
    return 1
  fi

  local desc
  desc="$(file -b "${path}" 2>/dev/null || true)"
  case "${desc}" in
    *ELF*|*Mach-O*|*PE32*|*executable*|*shared\ object*) return 0 ;;
    *) return 1 ;;
  esac
}

while IFS= read -r -d '' path; do
  [ -e "${path}" ] || continue

  # Only police the snapshot paths; regular repo source changes are not staged
  # by sync-commit.sh, but this keeps the validator focused if reused manually.
  case "${path}" in
    .hermes/*|workspace/*) ;;
    *) continue ;;
  esac

  lower="$(printf '%s' "${path}" | tr '[:upper:]' '[:lower:]')"

  case "${lower}" in
    */.env|*/.env.*|.env|.env.*|*/auth.json|auth.json|*credential*|*secret*|*token*|*service-account*.json|*sa-key*.json|*.pem|*.key|*/id_rsa*|id_rsa*|*/id_ed25519*|id_ed25519*|*/google_compute_engine*|google_compute_engine*)
      block_file "${path}" "secret or credential-like path"
      continue
      ;;
  esac

  case "${lower}" in
    .hermes/bin/*|.hermes/node/*|.hermes/hermes-agent/*|.hermes/venvs/*|.hermes/cache/*|.hermes/logs/*|.hermes/sessions/*|*/node_modules/*|*/.venv/*|*/venv/*|*/__pycache__/*|*/.terraform/*|*/.cache/*|*/cache/*|*/logs/*|*/sessions/*|*/dist/*|*/build/*|*/ms-playwright/*|*/chromium-*/*|*/chromium_headless_shell-*/*|*/chrome-linux64/*|*/chrome-headless-shell-linux64/*)
      block_file "${path}" "generated runtime/cache/build path"
      continue
      ;;
  esac

  case "${lower}" in
    *.log|*.tmp|*.pyc|*.gguf|*.safetensors|*.bin|*.pt|*.onnx|*.ckpt|*.zip|*.tar|*.tar.gz|*.tgz|*/terraform.tfstate|*/terraform.tfstate.*)
      block_file "${path}" "generated, archive, model, or state artifact"
      continue
      ;;
  esac

  if [ -f "${path}" ]; then
    size="$(wc -c < "${path}" | tr -d '[:space:]')"
    if [ "${size}" -ge "${MAX_GIT_BLOB_BYTES}" ]; then
      block_file "${path}" "oversized file (${size} bytes >= ${MAX_GIT_BLOB_BYTES})"
      continue
    fi

    if is_probably_executable_binary "${path}"; then
      block_file "${path}" "executable/runtime binary"
      continue
    fi
  fi
done < <(git diff --cached --name-only -z)

if [ "${#blocked[@]}" -gt 0 ]; then
  git reset -q HEAD -- "${blocked[@]}" || true
  log "Unstaged ${#blocked[@]} blocked file(s)."
else
  log "No unsafe staged sync files detected."
fi
