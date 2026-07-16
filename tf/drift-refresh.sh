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

# Suppress the cloud-provision bootstrap-permission preflight on the
# refresh-only drift path (luthersystems/reliable#2243 review finding). The
# preflight (setupCloudEnv → {aws,gcp}-preflight.sh) fires whenever the stage
# dir basename is "cloud-provision", and it checks the CREATE permissions the
# bootstrap APPLY needs (s3:CreateBucket, iam:CreateRole, storage.buckets.create,
# …). But drift-refresh is a READ-ONLY operation — `terraform plan -refresh-only`
# never creates, updates, or deletes anything — so gating its drift VISIBILITY on
# a create-permission check is pure harm: a credential that was scoped down
# post-bootstrap (exactly the #2243 lockdown scenario) would keep working for
# deploys yet have its drift detection blocked by a permission it does not need.
# Same class as the destroy-path bug fixed in bc942b1 (see tf/destroy.sh). These
# exports live only in this process — apply.sh / plan.sh / apply-with-outputs.sh
# run as separate processes and keep the guard on their (mutating) paths.
export SKIP_AWS_BOOTSTRAP_PREFLIGHT=1
export SKIP_GCP_BOOTSTRAP_PREFLIGHT=1

setupCloudEnv
trap 'cleanupCloudEnv' EXIT

# Run terraform init and refresh-only plan
terraform init -input=false
terraform plan -refresh-only -out=refresh.tfplan -input=false

# Export JSON plan for structured analysis
mkdir -p "$MARS_PROJECT_ROOT/outputs"
terraform show -json refresh.tfplan > "$MARS_PROJECT_ROOT/outputs/tfplan-${lifecycle}.json"
echo "Plan JSON written to $MARS_PROJECT_ROOT/outputs/tfplan-${lifecycle}.json"
# Also write the canonical outputs/tfplan.json alias for consumers that
# key on the unsuffixed name (Argo artifact spec, Oracle GetJobPlan,
# reliable's fetchOraclePlanJSON). See issue #127.
cp "$MARS_PROJECT_ROOT/outputs/tfplan-${lifecycle}.json" "$MARS_PROJECT_ROOT/outputs/tfplan.json"
echo "Canonical tfplan.json written to $MARS_PROJECT_ROOT/outputs/tfplan.json"

# Standalone drift alarm: --strict bypasses the plan-actionability gate in
# drift-check.sh, since -refresh-only plans by definition have no actionable
# changes but we still want to alarm on any real drift here.
bash "$SCRIPT_DIR/drift-check.sh" refresh.tfplan --stage "$lifecycle" --strict
