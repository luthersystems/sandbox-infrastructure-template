#!/bin/bash
# apply.sh — Apply a stage, with the -infra git steps around the apply.
#
# Usage: bash apply.sh <stage>
#
# Merges infra/main, plans and applies the stage with `mars default
# apply-stage` (mars-stages.yaml, tf/stages.sh, #114), then snapshots and
# pushes the deployed tree (#160). applyStageWithInfraSync in tf/stages.sh
# has the rules of each step.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: apply.sh <stage>" >&2
  exit 1
fi
stage="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. "$SCRIPT_DIR/stages.sh"
exportTemplateVersion
exportPresetsVersion
exportStageParallelism

enterStage "$stage"
applyStageWithInfraSync "$stage"
