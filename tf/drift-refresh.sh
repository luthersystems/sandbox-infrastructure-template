#!/usr/bin/env bash
# shellcheck shell=bash
# drift-refresh.sh — Standalone drift detection via refresh-only plan.
#
# Usage: bash drift-refresh.sh <lifecycle>
#
# Runs terraform init + plan -refresh-only, then checks for drift
# using drift-check.sh.
#
# Exit codes:
#   0 — No drift detected
#   2 — Drift detected
#   1 — Error

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: drift-refresh.sh <lifecycle>" >&2
  exit 1
fi

lifecycle="$1"

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

# Run terraform init and refresh-only plan
terraform init -input=false
terraform plan -refresh-only -out=refresh.tfplan -input=false

# Export JSON plan for structured analysis
mkdir -p "$MARS_PROJECT_ROOT/outputs"
terraform show -json refresh.tfplan > "$MARS_PROJECT_ROOT/outputs/tfplan-${lifecycle}.json"
echo "Plan JSON written to $MARS_PROJECT_ROOT/outputs/tfplan-${lifecycle}.json"

# Standalone drift alarm: --strict bypasses the plan-actionability gate in
# drift-check.sh, since -refresh-only plans by definition have no actionable
# changes but we still want to alarm on any real drift here.
bash "$SCRIPT_DIR/drift-check.sh" refresh.tfplan --stage "$lifecycle" --strict
