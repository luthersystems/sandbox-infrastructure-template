#!/usr/bin/env bash
# shellcheck shell=bash
# drift-check.sh — Check a terraform plan file for resource drift.
#
# Usage: bash drift-check.sh <plan-file> [--ignore-drift] [--stage <name>] [--strict]
#
# Exit codes:
#   0 — No drift detected, drift ignored via --ignore-drift, or drift found but
#       no drifted resource is in the plan's actionable set (resource_changes[]
#       entry for that address is no-op/read/absent) and --strict was not
#       passed. Drift is still reported and drift.json is still written in all
#       these cases.
#   1 — Error (missing plan file, jq failure, etc.)
#   2 — Drift detected on a resource the plan will modify (resource_changes[]
#       entry has a non-no-op/read action), OR --strict and any drift exists.
#
# Refresh-only plans (from `terraform plan -refresh-only`) have no
# resource_changes at all, so by definition no drift can be address-joined to
# an actionable change — drift-check is informational on them by default. Pass
# --strict to alarm on any drift regardless — used by drift-refresh.sh as a
# standalone manual-edit detector.
#
# If drift is found, writes a JSON report to $MARS_PROJECT_ROOT/outputs/drift.json.
# Does NOT source utils.sh — operates on a plan file already in the CWD.

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

# Write drift report. `actionable` is true when at least one drifted resource
# also has an actionable (non-no-op/read) entry in resource_changes[] — i.e.
# Terraform plans to overwrite a resource that has out-of-band changes. This
# matches ui-core's documented DriftStatus semantics: "Computed-attribute
# false positives surface in resource_drift but not in resource_changes" →
# Detected=true, Actionable=false → informational notice, not blocking.
# In --strict mode, actionable still reflects plan content only (Option 1
# from #95); strict-mode alarm is conveyed via exit code, not this field.
mkdir -p "$OUTPUTS_DIR"
_drift_report="$(jq -n \
  --argjson drift "$drift" \
  --argjson count "$drift_count" \
  --argjson actionable "$actionable_drift_count" \
  --arg tmpl "${TEMPLATE_VERSION:-}" \
  --arg pres "${PRESETS_VERSION:-}" \
  '{
    drift_detected: true,
    drift_count: $count,
    actionable: ($actionable > 0),
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
  echo "WARNING: Drift ignored (--ignore-drift flag set)."
  exit 0
fi

if [[ "$strict" != "true" && "$actionable_drift_count" -eq 0 ]]; then
  echo "INFO: drift detected but no drifted resource is being applied; not blocking apply."
  exit 0
fi

exit 2
