#!/usr/bin/env bash
# shellcheck shell=bash
# apply-with-outputs.sh — Apply a stage, then capture its outputs.
#
# Usage: bash apply-with-outputs.sh <lifecycle> [--check-drift] [--ignore-drift]
#
# A thin entrypoint over `mars default apply-stage <lifecycle> --outputs`
# (mars-stages.yaml, tf/stages.sh, #114). mars plans, applies that plan and
# writes outputs/outputs.json and outputs/<lifecycle>.json. Two modes:
#
#   Simple (no flags): as apply.sh, with the -infra git steps around the
#     apply: merge infra/main first, snapshot and push the deployed tree
#     after (#160).
#
#   Drift-check (--check-drift): mars checks the plan for drift first and
#     writes outputs/drift.json. On actionable drift the report has
#     apply_skipped=true and nothing is applied (exit 0, #108);
#     --ignore-drift applies anyway. No merge: ui-core runs this mode for
#     every custom-stack apply, on a tree it prepared. After an apply of
#     custom-stack-provision, the tree is persisted to the -infra repo
#     (#143).
#
# Without --check-drift, mars writes an empty drift.json when there is none,
# so consumers always get one.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: apply-with-outputs.sh <lifecycle> [--check-drift] [--ignore-drift]" >&2
  exit 1
fi

lifecycle="$1"
shift

check_drift=false
stage_args=()
for arg in "$@"; do
  case "$arg" in
    --check-drift)
      check_drift=true
      stage_args+=("$arg")
      ;;
    --ignore-drift) stage_args+=("$arg") ;;
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
. "$SCRIPT_DIR/stages.sh"
exportTemplateVersion
exportPresetsVersion
exportStageParallelism

if [[ "$check_drift" != "true" ]]; then
  enterStage "$lifecycle"
  applyStageWithInfraSync "$lifecycle" --outputs "${stage_args[@]+"${stage_args[@]}"}"
  exit 0
fi

prepareStage "$lifecycle"
marsStages apply-stage "$lifecycle" --outputs "${stage_args[@]}"

# mars wrote this run's drift.json before it decided to apply, so its
# apply_skipped says whether the stack was applied.
if [[ "$(driftApplySkipped)" == "true" ]]; then
  exit 0
fi

# This drift-check branch, not apply.sh, is what ui-core runs for a
# custom-stack apply (it always sets checkDrift=true), so without this the
# -infra repo stays empty despite a SUCCESS (#143).
persistCustomStack "$lifecycle"
