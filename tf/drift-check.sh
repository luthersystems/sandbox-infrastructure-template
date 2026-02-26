#!/usr/bin/env bash
# shellcheck shell=bash
# drift-check.sh — Check a terraform plan file for resource drift.
#
# Usage: bash drift-check.sh <plan-file> [--ignore-drift]
#
# Exit codes:
#   0 — No drift detected (or drift ignored via --ignore-drift)
#   1 — Error (missing plan file, jq failure, etc.)
#   2 — Drift detected
#
# If drift is found, writes a JSON report to $MARS_PROJECT_ROOT/outputs/drift.json.
# Does NOT source utils.sh — operates on a plan file already in the CWD.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: drift-check.sh <plan-file> [--ignore-drift]" >&2
  exit 1
fi

plan_file="$1"
shift

ignore_drift=false
for arg in "$@"; do
  case "$arg" in
    --ignore-drift) ignore_drift=true ;;
    *)
      echo "Unknown argument: $arg" >&2
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

OUTPUTS_DIR="$MARS_PROJECT_ROOT/outputs"

# Convert binary plan to JSON and check for drift
plan_json="$(terraform show -json "$plan_file")"

drift="$(echo "$plan_json" | jq '.resource_drift // []')"
drift_count="$(echo "$drift" | jq 'length')"

if [[ "$drift_count" -eq 0 ]]; then
  echo "No resource drift detected."
  exit 0
fi

echo "Drift detected: $drift_count resource(s) have drifted."
echo ""

# Print human-readable drift summary showing changed attributes per resource.
# The jq filter uses single quotes intentionally — jq handles \() interpolation.
# shellcheck disable=SC2016
_drift_filter='
  .[] |
  "  \(.address)",
  (
    (.change.before // {} | to_entries) as $before |
    (.change.after // {} | to_entries) as $after |
    [
      $before[] |
      . as $b |
      ($after | map(select(.key == $b.key)) | .[0]) as $a |
      select(($a.value == $b.value) | not) |
      "    \(.key): \($b.value | tojson) -> \($a.value | tojson)"
    ] | .[]
  ),
  ""
'
echo "$drift" | jq -r "$_drift_filter"

# Write drift report
mkdir -p "$OUTPUTS_DIR"
jq -n --argjson drift "$drift" --argjson count "$drift_count" \
  '{ drift_detected: true, drift_count: $count, resources: $drift }' \
  > "$OUTPUTS_DIR/drift.json"

echo "Drift report written to $OUTPUTS_DIR/drift.json"

if [[ "$ignore_drift" == "true" ]]; then
  echo "WARNING: Drift ignored (--ignore-drift flag set)."
  exit 0
fi

exit 2
