#!/usr/bin/env bash
# shellcheck shell=bash
# apply-with-outputs.sh — Run terraform apply then capture outputs.
#
# Usage: bash apply-with-outputs.sh <lifecycle> [--check-drift] [--ignore-drift]
#
# Two modes:
#   Simple (no flags):
#     Delegates to apply.sh (which includes git merge/commit/push),
#     then captures terraform output -json.
#
#   Drift-check (--check-drift):
#     Runs terraform directly: init -> plan -> drift-check -> apply.
#     No git operations. Optionally pass --ignore-drift to continue
#     despite detected drift.
#
# Outputs are written to $MARS_PROJECT_ROOT/outputs/outputs.json.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: apply-with-outputs.sh <lifecycle> [--check-drift] [--ignore-drift]" >&2
  exit 1
fi

lifecycle="$1"
shift

check_drift=false
ignore_drift=false
for arg in "$@"; do
  case "$arg" in
    --check-drift)  check_drift=true ;;
    --ignore-drift) ignore_drift=true ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
logTemplateVersion

captureOutputs() {
  mkdir -p "$MARS_PROJECT_ROOT/outputs"
  terraform output -json > "$MARS_PROJECT_ROOT/outputs/outputs.json"
  echo "Outputs written to $MARS_PROJECT_ROOT/outputs/outputs.json"
}

if [[ "$check_drift" == "true" ]]; then
  # Drift-check mode: run terraform directly, no git operations
  . "$MARS_PROJECT_ROOT/shell_utils.sh"

  # Source utils.sh (expects $1 = workspace/lifecycle)
  set -- "$lifecycle"
  . "$SCRIPT_DIR/utils.sh"

  setupCloudEnv
  trap 'cleanupCloudEnv' EXIT

  terraform init -input=false
  terraform plan -out=apply.tfplan -input=false

  # Check drift (may exit 2 if drift found and not ignored)
  drift_args=()
  if [[ "$ignore_drift" == "true" ]]; then
    drift_args+=("--ignore-drift")
  fi
  bash "$SCRIPT_DIR/drift-check.sh" apply.tfplan --stage "$lifecycle" "${drift_args[@]+"${drift_args[@]}"}"

  terraform apply -input=false apply.tfplan
  captureOutputs
else
  # Simple mode: delegate to apply.sh (includes git merge/commit/push)
  bash "$SCRIPT_DIR/apply.sh" "$lifecycle"

  # After apply.sh completes, we're in the lifecycle workspace dir.
  # We need to set up workspace context to run terraform output.
  . "$MARS_PROJECT_ROOT/shell_utils.sh"
  set -- "$lifecycle"
  . "$SCRIPT_DIR/utils.sh"

  setupCloudEnv
  trap 'cleanupCloudEnv' EXIT

  captureOutputs
fi
