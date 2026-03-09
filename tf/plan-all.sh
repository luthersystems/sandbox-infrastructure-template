#!/usr/bin/env bash
# shellcheck shell=bash
# plan-all.sh — Run terraform plan across multiple stages and aggregate results.
#
# Usage: bash plan-all.sh
#
# Configurable via environment:
#   PLAN_STAGES  Space-separated list of stages to plan (default: "cloud-provision custom-stack-provision")
#
# Outputs:
#   outputs/tfplan-<stage>.json  Per-stage plan JSON (produced by plan.sh)
#   outputs/plan-summary.json    Aggregated change counts across all stages
#
# Exit codes:
#   0 — All stages planned successfully, no changes in any stage
#   2 — All stages planned successfully, changes exist in at least one stage
#   1 — At least one stage failed to plan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
logTemplateVersion

STAGES="${PLAN_STAGES:-cloud-provision custom-stack-provision}"
OUTPUTS_DIR="$MARS_PROJECT_ROOT/outputs"
mkdir -p "$OUTPUTS_DIR"

had_error=false
had_changes=false

# Per-stage results stored as temp files for aggregation
results_dir="$(mktemp -d)"
cleanup_plan_all() {
  rm -rf "$results_dir"
}
trap cleanup_plan_all EXIT

for stage in $STAGES; do
  echo ""
  echo "=== Planning stage: $stage ==="
  echo ""

  set +e
  (cd "$SCRIPT_DIR" && bash plan.sh "$stage")
  rc=$?
  set -e

  plan_file="$OUTPUTS_DIR/tfplan-${stage}.json"

  if [[ $rc -ne 0 ]]; then
    echo "ERROR: plan.sh failed for stage $stage (exit $rc)"
    had_error=true
    echo '{"error": true}' > "$results_dir/$stage.json"
    continue
  fi

  # Auto-detect new project: if cloud-provision has no managed resources in
  # state, apply it so downstream stages can read its remote state.
  # Uses `terraform state list` rather than parsing plan JSON — data sources
  # appear in the plan's prior_state even for brand-new projects, but
  # `state list` only reports managed resources.
  if [[ "$stage" == "cloud-provision" ]]; then
    set +e
    state_count="$(
      cd "$SCRIPT_DIR"
      set -- "$stage"
      . ./utils.sh
      $MARS ${tf_workspace} state list 2>/dev/null | grep -c '^'
    )" || state_count=0
    set -e

    if [[ "$state_count" -eq 0 ]]; then
      echo ""
      echo "INFO: New project detected (no managed resources in cloud-provision state)."
      echo "INFO: Applying cloud-provision to create remote state for downstream stages..."
      echo ""
      set +e
      (
        cd "$SCRIPT_DIR"
        set -- "$stage"
        . ./utils.sh
        tfInit
        tfApply
      )
      apply_rc=$?
      set -e
      if [[ $apply_rc -ne 0 ]]; then
        echo "ERROR: Failed to apply cloud-provision (exit $apply_rc)"
        had_error=true
      else
        echo "INFO: cloud-provision applied successfully."
      fi
    fi
  fi

  if [[ ! -f "$plan_file" ]]; then
    echo "WARNING: no plan JSON produced for stage $stage"
    echo '{"add": 0, "change": 0, "destroy": 0, "has_changes": false}' > "$results_dir/$stage.json"
    continue
  fi

  # Extract resource change counts from plan JSON.
  # Filter out no-op actions (where actions == ["no-op"] or actions == ["read"]).
  counts="$(jq '{
    add: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["create"]))] | length,
    change: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["update"]))] | length,
    destroy: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["delete"]))] | length
  } | . + {has_changes: ((.add + .change + .destroy) > 0)}' "$plan_file")"

  echo "$counts" > "$results_dir/$stage.json"

  stage_has_changes="$(echo "$counts" | jq -r '.has_changes')"
  if [[ "$stage_has_changes" == "true" ]]; then
    had_changes=true
  fi

  echo "Stage $stage: $(echo "$counts" | jq -c '.')"
done

# Aggregate into plan-summary.json
echo ""
echo "=== Aggregating plan summary ==="

# Build the stages object and totals
summary="$(
  stages_json="{}"
  total_add=0
  total_change=0
  total_destroy=0

  for stage in $STAGES; do
    stage_file="$results_dir/$stage.json"
    if [[ -f "$stage_file" ]]; then
      stage_data="$(cat "$stage_file")"
      # Skip errored stages in totals
      is_error="$(echo "$stage_data" | jq -r '.error // false')"
      if [[ "$is_error" != "true" ]]; then
        total_add=$((total_add + $(echo "$stage_data" | jq '.add')))
        total_change=$((total_change + $(echo "$stage_data" | jq '.change')))
        total_destroy=$((total_destroy + $(echo "$stage_data" | jq '.destroy')))
      fi
      stages_json="$(echo "$stages_json" | jq --arg s "$stage" --argjson d "$stage_data" '.[$s] = $d')"
    fi
  done

  jq -n \
    --argjson stages "$stages_json" \
    --argjson total_add "$total_add" \
    --argjson total_change "$total_change" \
    --argjson total_destroy "$total_destroy" \
    --argjson has_changes "$( [[ "$had_changes" == "true" ]] && echo "true" || echo "false" )" \
    '{
      stages: $stages,
      total: { add: $total_add, change: $total_change, destroy: $total_destroy },
      has_changes: $has_changes
    }'
)"

echo "$summary" > "$OUTPUTS_DIR/plan-summary.json"
echo "Plan summary written to $OUTPUTS_DIR/plan-summary.json"
echo "$summary" | jq '.'

# Exit codes
if [[ "$had_error" == "true" ]]; then
  exit 1
elif [[ "$had_changes" == "true" ]]; then
  exit 2
else
  exit 0
fi
