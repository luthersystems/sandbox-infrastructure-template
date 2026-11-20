#!/bin/bash
# plan.sh — Plan one stage.
#
# Usage: bash plan.sh <stage>
#
# A thin entrypoint over `mars default plan-stage` (mars-stages.yaml,
# tf/stages.sh, #114). It writes outputs/tfplan-<stage>.json and the
# canonical outputs/tfplan.json alias, for single-stage Argo runs and the
# consumers that key on the unsuffixed name (Oracle GetJobPlan, reliable's
# fetchOraclePlanJSON; #127). A -out=<name> in TF_CLI_ARGS_plan names the
# saved plan.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: plan.sh <stage>" >&2
  exit 1
fi
stage="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. "$SCRIPT_DIR/stages.sh"
logTemplateVersion
logPresetsVersion

args=()
plan_file="$(stagePlanFile)"
if [[ -n "$plan_file" ]]; then
  args+=(--plan-file "$plan_file")
fi
exportStageParallelism

prepareStage "$stage"
marsStages plan-stage "$stage" "${args[@]+"${args[@]}"}"
