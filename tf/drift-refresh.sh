#!/usr/bin/env bash
# shellcheck shell=bash
# drift-refresh.sh — Standalone drift detection via a refresh-only plan.
#
# Usage: bash drift-refresh.sh <lifecycle>
#
# A thin entrypoint over `mars default plan-stage <lifecycle> --refresh-only
# --check-drift --strict --plan-file refresh.tfplan` (mars-stages.yaml,
# tf/stages.sh, #114). It writes outputs/tfplan-<lifecycle>.json, the
# outputs/tfplan.json alias (#127), and outputs/drift.json and
# outputs/drift-<lifecycle>.json.
#
# --strict: a refresh-only plan has no resource changes, so no drift in it is
# ever "actionable"; this standalone alarm exits 2 on any drift instead.
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
. "$SCRIPT_DIR/stages.sh"
exportTemplateVersion
exportPresetsVersion
exportStageParallelism

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
# exports live only in this process and its children — apply.sh / plan.sh /
# apply-with-outputs.sh run as separate processes and keep the guard on their
# (mutating) paths.
export SKIP_AWS_BOOTSTRAP_PREFLIGHT=1
export SKIP_GCP_BOOTSTRAP_PREFLIGHT=1

prepareStage "$lifecycle"
marsStages plan-stage "$lifecycle" --refresh-only --check-drift --strict --plan-file refresh.tfplan
