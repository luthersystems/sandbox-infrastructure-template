#!/usr/bin/env bash
# shellcheck shell=bash
# drift-check.sh — Check a terraform plan file for resource drift.
#
# Usage: bash drift-check.sh <plan-file> [--ignore-drift] [--stage <name>] [--strict]
#
# Exit codes:
#   0 — Default. No drift, OR drift detected (the pod no longer gates apply
#       at exit-2 — see issue #108). The decision to skip apply on
#       actionable drift is conveyed via `apply_skipped: true` in drift.json
#       and is enforced by the apply wrappers (apply-plan.sh,
#       apply-with-outputs.sh), which read drift.json and skip
#       `terraform apply` when set. `reliable` + ui-core render the
#       per-resource verdict from the same artifact.
#   1 — Error (missing plan file, jq failure, etc.).
#   2 — `--strict` and drift exists. Reserved for the standalone refresh
#       alarm path (drift-refresh.sh as a manual-edit detector). Apply paths
#       never see exit 2 unless they explicitly opt in to --strict.
#
# `--ignore-drift` is the force-apply override — used end-to-end by reliable
# (UI → /api/tf/start?ignore_drift=true → Oracle workflow argv → here).
# When set: log WARNING, write `apply_skipped: false`, exit 0 — apply runs.
#
# Refresh-only plans (from `terraform plan -refresh-only`) have no
# resource_changes at all, so actionable_drift_count is always 0 and
# apply_skipped is always false in their drift.json. The strict alarm
# signal for those is exit 2, not the apply_skipped field.
#
# Always writes a JSON report to $MARS_PROJECT_ROOT/outputs/drift.json when
# drift is detected. Does NOT source utils.sh — operates on a plan file
# already in the CWD.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: drift-check.sh <plan-file> [--ignore-drift] [--stage <name>] [--strict]" >&2
  exit 1
fi

plan_file="$1"
shift

ignore_drift=false
stage_name=""
strict=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore-drift) ignore_drift=true; shift ;;
    --strict) strict=true; shift ;;
    --stage)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --stage requires a value" >&2
        exit 1
      fi
      stage_name="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$plan_file" ]]; then
  echo "ERROR: plan file not found: $plan_file" >&2
  exit 1
fi

# Resolve project root for output path
: "${MARS_PROJECT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export MARS_PROJECT_ROOT
echo "template_version=${TEMPLATE_VERSION:-unknown}"
echo "presets_version=${PRESETS_VERSION:-unknown}"

OUTPUTS_DIR="$MARS_PROJECT_ROOT/outputs"

# Convert binary plan to JSON and check for drift
plan_json="$(terraform show -json "$plan_file")"

# jq function to normalize null-equivalent values so that null vs [] / {} / false / 0 / ""
# comparisons don't produce false-positive drift.
# shellcheck disable=SC2016
_normalize='
def normalize_empty:
  if . == null then null
  elif . == [] then null
  elif . == {} then null
  elif . == false then null
  elif . == 0 then null
  elif . == "" then null
  elif type == "array" then map(normalize_empty)
  elif type == "object" then with_entries(.value |= normalize_empty)
  else .
  end;
'

# Extract resource_drift, filtering out entries where all attribute diffs are
# null-vs-empty (false positives from AWS API response normalization).
drift="$(echo "$plan_json" | jq "$_normalize"'
[
  (.resource_drift // [])[] |
  . as $entry |
  if ($entry.change == null) then $entry
  else
    (($entry.change.before // {}) | normalize_empty) as $nb |
    (($entry.change.after  // {}) | normalize_empty) as $na |
    select($nb != $na)
  end
]
')"
drift_count="$(echo "$drift" | jq 'length')"

if [[ "$drift_count" -eq 0 ]]; then
  echo "No resource drift detected."
  exit 0
fi

# Address-join: a drift entry counts as actionable iff the same resource has
# a non-no-op/read action in resource_changes[]. Computed attributes show up
# in resource_drift but their resource_changes entry is no-op (Terraform
# isn't going to do anything), so the join correctly drops them. Common
# offenders: google_firestore_database.{etag,earliest_version_time},
# google_storage_bucket.updated, aws_iam_role.{inline_policy,managed_policy_arns},
# aws_db_instance.latest_restorable_time. No per-attribute allowlist needed —
# Terraform's own plan tells us which drift matters (issue #102).
#
# Missing/null change.actions on a matched address falls through the select
# and counts as actionable (fail-safe toward blocking apply).
actionable_drift_count="$(echo "$plan_json" | jq --argjson drift "$drift" '
  ([
    (.resource_changes // [])[] |
    select(.change.actions != ["no-op"] and .change.actions != ["read"]) |
    .address
  ] | unique) as $actionable_addrs |
  [$drift[] | select(.address as $a | $actionable_addrs | index($a))] | length
')"

# Enrich each drift entry with the joined action[] from resource_changes
# (issue #105). The downstream classifier in luthersystems/insideout-terraform-presets
# uses this — plus type, name, change.before, and change.after (all passed
# through unmodified from terraform show -json) — to apply per-attribute
# rules (phantom-computed, provider-noise, reconverge, actionable). action
# is null when the address isn't in resource_changes[] (refresh-only plans
# and addresses Terraform isn't touching). Independent of the actionable
# rollup above so this enrichment can never regress the fail-safe gate
# semantics — a future spec change to the action field need not move the
# gate, and vice versa.
addr_to_actions="$(echo "$plan_json" | jq '
  reduce ((.resource_changes // [])[]) as $rc ({};
    .[$rc.address] = ($rc.change.actions // null)
  )
')"
drift="$(echo "$drift" | jq --argjson actions_map "$addr_to_actions" '
  map(. + {action: ($actions_map[.address] // null)})
')"

echo "Drift detected: $drift_count resource(s) have drifted."
echo ""

# Print human-readable drift summary showing changed attributes per resource.
# The jq filter uses single quotes intentionally — jq handles \() interpolation.
# Uses normalize_empty to skip null-vs-empty attribute diffs in display.
# shellcheck disable=SC2016
_drift_filter="$_normalize"'
  .[] |
  "  \(.address)",
  (
    (.change.before // {} | to_entries) as $before |
    (.change.after // {} | to_entries) as $after |
    [
      $before[] |
      . as $b |
      ($after | map(select(.key == $b.key)) | .[0]) as $a |
      select(($b.value | normalize_empty) != ($a.value | normalize_empty)) |
      "    \(.key): \($b.value | tojson) -> \($a.value | tojson)"
    ] | .[]
  ),
  ""
'
echo "$drift" | jq -r "$_drift_filter"

# Write drift report. Two top-level booleans:
#   actionable     — at least one drifted resource has a non-no-op/read entry
#                    in resource_changes[]. Reflects plan content only; matches
#                    ui-core's documented DriftStatus semantics ("Computed-
#                    attribute false positives surface in resource_drift but
#                    not in resource_changes" → Detected=true, Actionable=false).
#   apply_skipped  — true iff `actionable && !ignore_drift`. The apply
#                    wrappers (apply-plan.sh, apply-with-outputs.sh) read
#                    this and skip `terraform apply` when set. This moves
#                    the apply gate out of the pod's exit code (issue #108)
#                    while still letting reliable's force-apply round-trip
#                    (UI → ignore_drift=true → Oracle → --ignore-drift)
#                    flip it back to false on demand.
mkdir -p "$OUTPUTS_DIR"

if [[ "$ignore_drift" != "true" && "$actionable_drift_count" -gt 0 ]]; then
  apply_skipped_json=true
else
  apply_skipped_json=false
fi

_drift_report="$(jq -n \
  --argjson drift "$drift" \
  --argjson count "$drift_count" \
  --argjson actionable "$actionable_drift_count" \
  --argjson skipped "$apply_skipped_json" \
  --arg tmpl "${TEMPLATE_VERSION:-}" \
  --arg pres "${PRESETS_VERSION:-}" \
  '{
    drift_detected: true,
    drift_count: $count,
    actionable: ($actionable > 0),
    apply_skipped: $skipped,
    template_version: (if $tmpl == "" then null else $tmpl end),
    presets_version: (if $pres == "" then null else $pres end),
    resources: $drift
  }')"

# Always write drift.json (Argo artifact path expects this)
echo "$_drift_report" > "$OUTPUTS_DIR/drift.json"

if [[ -n "$stage_name" ]]; then
  echo "$_drift_report" > "$OUTPUTS_DIR/drift-${stage_name}.json"
  echo "Drift report written to $OUTPUTS_DIR/drift-${stage_name}.json (and drift.json)"
else
  echo "Drift report written to $OUTPUTS_DIR/drift.json"
fi

if [[ "$ignore_drift" == "true" ]]; then
  echo "WARNING: Drift ignored (--ignore-drift flag set); force-applying despite drift (apply_skipped=false)."
  exit 0
fi

if [[ "$strict" == "true" ]]; then
  # Standalone refresh-only alarm path (drift-refresh.sh). Any drift exits 2
  # so the caller's workflow step fails visibly. Apply paths do not pass
  # --strict, so this never fires for them.
  exit 2
fi

if [[ "$actionable_drift_count" -gt 0 ]]; then
  echo "INFO: actionable drift detected; apply_skipped=true. Apply wrappers will skip terraform apply. See reliable + UI for verdict."
else
  echo "INFO: drift detected but no drifted resource is being applied; not blocking apply."
fi
exit 0
