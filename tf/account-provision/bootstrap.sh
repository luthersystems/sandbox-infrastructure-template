#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source helpers
. "$MARS_PROJECT_ROOT/shell_utils.sh"

# Source shared terraform helpers
source "${SCRIPT_DIR}/../../shell_utils.sh"

tfBootstrap() {
  # if we’ve already-generated a backend file, skip
  if [ -f "backend.tf.json" ]; then
    return
  fi

  local bucket key kms_key_id region workspace_key_prefix

  bucket=$(mustGetTfVar "bootstrap_state_bucket")
  key="$(mustGetTfVar "bootstrap_state_env")/account/terraform_$(mustGetTfVar "short_project_id").tfstate"
  kms_key_id=$(mustGetTfVar "bootstrap_state_kms_key_id")
  region=$(mustGetTfVar "bootstrap_state_region")
  workspace_key_prefix=$(mustGetTfVar "short_project_id")

  jq -n -f backend.jq \
    --arg bucket "$bucket" \
    --arg key "$key" \
    --arg kms_key_id "$kms_key_id" \
    --arg region "$region" \
    --arg workspace_key_prefix "$workspace_key_prefix" \
    >backend.tf.json
}

tfBootstrap
