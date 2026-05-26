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
#   outputs/tfplan.json          Canonical "full plan" alias for Argo / Oracle /
#                                reliable consumers that expect a single
#                                tfplan.json artifact (see issue #127). Sourced
#                                from the import-bearing stage when present
#                                (custom-stack-provision) so the post-import
#                                tag-only classifier in reliable has the
#                                resource_changes array it needs; otherwise
#                                the last successful stage wins.
#   outputs/plan-summary.json    Aggregated change counts across all stages
#
# Exit codes:
#   0 — All stages planned successfully (changes reported in plan-summary.json)
#   1 — At least one stage failed to plan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
logTemplateVersion
logPresetsVersion

STAGES="${PLAN_STAGES:-cloud-provision custom-stack-provision}"
OUTPUTS_DIR="$MARS_PROJECT_ROOT/outputs"
mkdir -p "$OUTPUTS_DIR"

# Clear stale plan artifacts from any prior run. Argo gives each workflow an
# ephemeral marsproject so this is a no-op there, but local-dev re-runs (and
# any reaped/retried Argo path that reuses the dir) would otherwise let a
# previous-run tfplan-<stage>.json or tfplan.json survive a failed stage and
# get picked up as the canonical alias below — feeding stale data to
# reliable's tag-only classifier. Per-stage plan.sh invocations write their
# own per-stage file and aren't affected.
rm -f "$OUTPUTS_DIR"/tfplan-*.json "$OUTPUTS_DIR/tfplan.json"

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
      # shellcheck disable=SC2154  # tf_workspace is set by sourced utils.sh
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
        # Clear plan-specific CLI args that Oracle sets — flags like -out
        # and -compact-warnings are invalid for terraform apply.
        unset TF_CLI_ARGS_plan
        unset TF_CLI_ARGS_apply
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
    echo '{"add": 0, "change": 0, "destroy": 0, "import": 0, "has_changes": false}' > "$results_dir/$stage.json"
    continue
  fi

  # Extract resource change counts from plan JSON.
  # Filter out no-op actions (where actions == ["no-op"] or actions == ["read"]).
  # Imports are counted from `change.actions[]` entries containing "import"
  # (terraform JSON plan format v1+). A stage with imports-only is still a
  # real change, so `has_changes` includes the import count.
  counts="$(jq '{
    add: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["create"]))] | length,
    change: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["update"]))] | length,
    destroy: [.resource_changes // [] | .[] | select(.change.actions | . != ["no-op"] and . != ["read"]) | select(.change.actions | contains(["delete"]))] | length,
    import: [.resource_changes // [] | .[] | select(.change.actions | contains(["import"]))] | length
  } | . + {has_changes: ((.add + .change + .destroy + .import) > 0)}' "$plan_file")"

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
  total_import=0

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
        total_import=$((total_import + $(echo "$stage_data" | jq '.import // 0')))
      fi
      stages_json="$(echo "$stages_json" | jq --arg s "$stage" --argjson d "$stage_data" '.[$s] = $d')"
    fi
  done

  jq -n \
    --argjson stages "$stages_json" \
    --argjson total_add "$total_add" \
    --argjson total_change "$total_change" \
    --argjson total_destroy "$total_destroy" \
    --argjson total_import "$total_import" \
    --argjson has_changes "$( [[ "$had_changes" == "true" ]] && echo "true" || echo "false" )" \
    '{
      stages: $stages,
      total: { add: $total_add, change: $total_change, destroy: $total_destroy, import: $total_import },
      has_changes: $has_changes
    }'
)"

echo "$summary" > "$OUTPUTS_DIR/plan-summary.json"
echo "Plan summary written to $OUTPUTS_DIR/plan-summary.json"
echo "$summary" | jq '.'

# Write canonical outputs/tfplan.json alias for consumers that expect a
# single full-plan artifact (Argo `tf-plan-all` artifact spec, Oracle
# GetJobPlan → reliable's fetchOraclePlanJSON / post-import tag-only
# classifier). See issue #127.
#
# Preference order:
#   1. custom-stack-provision  (the stage that carries imports, so its
#      resource_changes array is what the tag-only classifier reads)
#   2. last successful stage in $STAGES with a per-stage plan JSON on disk
canonical_src=""
if [[ -f "$OUTPUTS_DIR/tfplan-custom-stack-provision.json" ]]; then
  canonical_src="$OUTPUTS_DIR/tfplan-custom-stack-provision.json"
else
  for stage in $STAGES; do
    if [[ -f "$OUTPUTS_DIR/tfplan-${stage}.json" ]]; then
      canonical_src="$OUTPUTS_DIR/tfplan-${stage}.json"
    fi
  done
fi

if [[ -n "$canonical_src" ]]; then
  cp "$canonical_src" "$OUTPUTS_DIR/tfplan.json"
  echo "Canonical tfplan.json written from $canonical_src"
else
  echo "WARNING: no per-stage tfplan-*.json produced; skipping outputs/tfplan.json"
fi

# Strip provider binaries before Argo tars /marsproject for its output
# artifact. Each `terraform init --reconfigure` symlinks /opt/tf-plugin-cache
# providers into the local .terraform/providers/ via mars's filesystem_mirror
# (luthersystems/mars#168) — but when the baked provider version drifts ahead
# of the mars cache, init falls back to direct registry download which COPIES
# the binary into .terraform/providers/. Either way these are re-creatable
# from the mars filesystem_mirror on the next pod's init, so they don't need
# to round-trip through the workflow's S3 artifact (~750 MiB of provider
# binary per stage per pod, observed at ~45s/upload on 2026-05-25 against
# sess_v2_CnqUJ6NRJnLC).
#
# We strip RECURSIVELY across the whole project root rather than just per-stage
# tf/<stage>/.terraform/providers — reverse-import also leaves provider caches
# under outputs/reverse-import/.terraform/providers/ and
# outputs/reverse-import/genconfig/.terraform/providers/ (issue #134, another
# ~1.5 GiB on top of the per-stage cost).
#
# .terraform/modules/ is intentionally KEPT — those are git clones of
# luthersystems/tf-modules that the next pod would otherwise re-clone (no
# filesystem mirror equivalent for module sources).
#
# .terraform/{providers,plugins}-lock.json and the lockfile (.terraform.lock.hcl)
# are also kept — they pin the resolved versions and are required for
# `init --reconfigure` to find the right mirror entries.
echo "=== Stripping ALL .terraform/providers/ before exit (re-created from filesystem_mirror on next init) ==="
while IFS= read -r providers_dir; do
  [[ -z "$providers_dir" ]] && continue
  rel="${providers_dir#"$MARS_PROJECT_ROOT"/}"
  size_before=$(du -sh "$providers_dir" 2>/dev/null | awk '{print $1}')
  find "$providers_dir" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$providers_dir" 2>/dev/null || true
  echo "  stripped $rel (${size_before:-?} before)"
done < <(find "$MARS_PROJECT_ROOT" -type d -name providers -path '*/.terraform/providers' 2>/dev/null)

# Exit codes
if [[ "$had_error" == "true" ]]; then
  exit 1
else
  exit 0
fi
