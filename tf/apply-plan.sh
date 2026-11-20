#!/usr/bin/env bash
# shellcheck shell=bash
# apply-plan.sh — Apply a saved .tfplan file.
#
# Usage: bash apply-plan.sh <lifecycle> --plan-file <id> [--check-drift] [--ignore-drift]
#
# A thin entrypoint over `mars default apply-stage <lifecycle> --plan
# <id>.tfplan --outputs --clean-providers` (mars-stages.yaml, tf/stages.sh,
# #114). The plan file is <lifecycle>/<id>.tfplan, saved by an earlier
# plan-all.sh or plan.sh run. mars deletes the stage's cached providers
# before init (they conflict across containers), applies, and writes
# outputs/outputs.json and outputs/<lifecycle>.json.
#
# --check-drift checks the plan for drift first and writes outputs/drift.json.
# On actionable drift the report has apply_skipped=true and nothing is
# applied (exit 0, the pod-level gate of #108); --ignore-drift is reliable's
# force-apply, which applies anyway. Without --check-drift, mars writes an
# empty drift.json when there is none, so consumers always get one.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: apply-plan.sh <lifecycle> --plan-file <id> [--check-drift] [--ignore-drift]" >&2
  exit 1
fi

lifecycle="$1"
shift

plan_id=""
check_drift=false
stage_args=()
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
    --check-drift)
      check_drift=true
      stage_args+=("$1")
      shift
      ;;
    --ignore-drift)
      stage_args+=("$1")
      shift
      ;;
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
. "$SCRIPT_DIR/stages.sh"
exportTemplateVersion
exportPresetsVersion
exportStageParallelism

prepareStage "$lifecycle"
marsStages apply-stage "$lifecycle" --plan "${plan_id}.tfplan" --outputs --clean-providers \
  "${stage_args[@]+"${stage_args[@]}"}"

# With --check-drift, mars wrote this run's drift.json before it decided to
# apply, so its apply_skipped says whether the stack was applied.
if [[ "$check_drift" == "true" && "$(driftApplySkipped)" == "true" ]]; then
  exit 0
fi

# The saved-plan apply path (ui-core makeApplyAllFromPlanWorkflow) never
# reaches apply.sh's push (#143).
persistCustomStack "$lifecycle"
