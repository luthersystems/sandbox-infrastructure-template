#!/usr/bin/env bash
# shellcheck shell=bash
# apply-plan.sh — Apply a pre-generated .tfplan file.
#
# Usage: bash apply-plan.sh <lifecycle> --plan-file <id> [--check-drift] [--ignore-drift]
#
# Applies a saved terraform plan, optionally checking for drift first.
# Captures terraform outputs after apply.
#
# The plan file is expected at: <lifecycle>/<id>.tfplan
#
# Outputs are written to $MARS_PROJECT_ROOT/outputs/outputs.json.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: apply-plan.sh <lifecycle> --plan-file <id> [--check-drift] [--ignore-drift]" >&2
  exit 1
fi

lifecycle="$1"
shift

plan_id=""
check_drift=false
ignore_drift=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-file)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --plan-file requires a value" >&2
        exit 1
      fi
      plan_id="$2"
      shift 2
      ;;
    --check-drift)  check_drift=true; shift ;;
    --ignore-drift) ignore_drift=true; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$plan_id" ]]; then
  echo "ERROR: --plan-file is required" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
exportTemplateVersion
exportPresetsVersion

# Source utils.sh (expects $1 = workspace/lifecycle)
set -- "$lifecycle"
. "$SCRIPT_DIR/utils.sh"

setupCloudEnv
trap 'cleanupCloudEnv' EXIT

plan_file="${plan_id}.tfplan"

if [[ ! -f "$plan_file" ]]; then
  echo "ERROR: plan file not found: $plan_file" >&2
  exit 1
fi

# Remove cached providers to avoid conflicts across containers
rm -rf .terraform/providers

terraform init -input=false

# Optional drift check before apply
if [[ "$check_drift" == "true" ]]; then
  drift_args=()
  if [[ "$ignore_drift" == "true" ]]; then
    drift_args+=("--ignore-drift")
  fi
  bash "$SCRIPT_DIR/drift-check.sh" "$plan_file" --stage "$lifecycle" "${drift_args[@]+"${drift_args[@]}"}"
fi

terraform apply -input=false "$plan_file"

captureOutputs() {
  mkdir -p "$MARS_PROJECT_ROOT/outputs"
  terraform output -json > "$MARS_PROJECT_ROOT/outputs/outputs.json"
  echo "Outputs written to $MARS_PROJECT_ROOT/outputs/outputs.json"
  cp "$MARS_PROJECT_ROOT/outputs/outputs.json" "$MARS_PROJECT_ROOT/outputs/${lifecycle}.json"
  echo "Outputs also saved to $MARS_PROJECT_ROOT/outputs/${lifecycle}.json"
}

captureOutputs

# Write drift.json stub if drift-check didn't produce one (not invoked, or
# invoked but no drift). Mirrors the full drift-check.sh schema so consumers
# get the same shape regardless of whether drift occurred, including the
# template_version / presets_version provenance fields.
if [ ! -f "$MARS_PROJECT_ROOT/outputs/drift.json" ]; then
  mkdir -p "$MARS_PROJECT_ROOT/outputs"
  jq -n \
    --arg tmpl "${TEMPLATE_VERSION:-}" \
    --arg pres "${PRESETS_VERSION:-}" \
    '{
      drift_detected: false,
      drift_count: 0,
      actionable: false,
      template_version: (if $tmpl == "" then null else $tmpl end),
      presets_version: (if $pres == "" then null else $pres end),
      resources: []
    }' > "$MARS_PROJECT_ROOT/outputs/drift.json"
fi
