#!/usr/bin/env bash
# shellcheck shell=bash
# drift-check.sh — Check a terraform plan file for resource drift.
#
# Usage: bash drift-check.sh <plan-file> [--ignore-drift] [--stage <name>] [--strict]
#
# A thin entrypoint over `mars default drift-check` (luthersystems/mars
# internal/terraform/driftcheck.go, #114), which holds the drift rules that
# were jq here: the null-vs-empty filter of resource_drift, the address join
# with resource_changes that makes a drift entry actionable (#102), the
# per-entry action (#105) and apply_skipped (#108). The template's scripts
# no longer call this one (the mars stage commands check drift themselves,
# tf/stages.sh); it stays for a person who checks a saved plan by hand, with
# its old contract:
#
# Exit codes:
#   0 — Default. No drift, OR drift detected: the apply gate is
#       `apply_skipped: true` in drift.json, not the exit code (#108).
#   1 — Error (missing plan file, bad plan JSON, etc.).
#   2 — `--strict` and drift exists (the refresh-only alarm).
#
# `--ignore-drift` is the force-apply override: drift is reported with
# `apply_skipped: false`, exit 0.
#
# When drift is detected it writes the report to
# $MARS_PROJECT_ROOT/outputs/drift.json (and drift-<stage>.json with
# --stage), stamped with template_version and presets_version from
# TEMPLATE_VERSION and PRESETS_VERSION. With no drift it writes nothing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: drift-check.sh <plan-file> [--ignore-drift] [--stage <name>] [--strict]" >&2
  exit 1
fi

plan_file="$1"
shift

stage_name=""
ignore_drift=false
strict=false
mars_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore-drift) ignore_drift=true; mars_args+=(--ignore-drift); shift ;;
    --strict) strict=true; mars_args+=(--strict); shift ;;
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

TEMPLATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${MARS_PROJECT_ROOT:=$TEMPLATE_ROOT}"
export MARS_PROJECT_ROOT
# For resolveMarsCLI. From this script's own tree: the plan may be checked
# against another project root (MARS_PROJECT_ROOT), which needs no copy of
# the template's helpers.
. "$TEMPLATE_ROOT/shell_utils.sh"
echo "template_version=${TEMPLATE_VERSION:-unknown}"
echo "presets_version=${PRESETS_VERSION:-unknown}"

OUTPUTS_DIR="$MARS_PROJECT_ROOT/outputs"
mars_bin="$(resolveNativeMarsCLI)"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

# mars exits 2 on actionable drift (and, with --strict, on any drift), 0
# otherwise. Here actionable drift exits 0 (#108), so only --strict keeps 2.
rc=0
"$mars_bin" default drift-check "$plan_file" --out "$report" "${mars_args[@]+"${mars_args[@]}"}" || rc=$?
if [[ "$rc" -ne 0 && "$rc" -ne 2 ]]; then
  echo "ERROR: mars drift-check failed (exit $rc)" >&2
  exit 1
fi

# An empty or unreadable report is an error, never "no drift".
drift="$(jq -r '.drift_detected | booleans' "$report" 2>/dev/null || true)"
if [[ "$drift" != "true" && "$drift" != "false" ]]; then
  echo "ERROR: mars drift-check wrote no report to $report" >&2
  exit 1
fi
if [[ "$drift" != "true" ]]; then
  echo "No resource drift detected."
  exit 0
fi

# The provenance fields go before "resources", as drift-check.sh wrote them.
mkdir -p "$OUTPUTS_DIR"
jq --arg tmpl "${TEMPLATE_VERSION:-}" --arg pres "${PRESETS_VERSION:-}" '
  (del(.resources) + {
    template_version: (if $tmpl == "" then null else $tmpl end),
    presets_version: (if $pres == "" then null else $pres end)
  }) + {resources: .resources}
' "$report" > "$OUTPUTS_DIR/drift.json"

if [[ -n "$stage_name" ]]; then
  cp "$OUTPUTS_DIR/drift.json" "$OUTPUTS_DIR/drift-${stage_name}.json"
  echo "Drift report written to $OUTPUTS_DIR/drift-${stage_name}.json (and drift.json)"
else
  echo "Drift report written to $OUTPUTS_DIR/drift.json"
fi

if [[ "$ignore_drift" == "true" ]]; then
  echo "WARNING: Drift ignored (--ignore-drift flag set); force-applying despite drift (apply_skipped=false)."
  exit 0
fi
if [[ "$strict" == "true" ]]; then
  exit 2
fi
if [[ "$(jq -r '.apply_skipped' "$OUTPUTS_DIR/drift.json")" == "true" ]]; then
  echo "INFO: actionable drift detected; apply_skipped=true. Apply wrappers will skip terraform apply. See reliable + UI for verdict."
else
  echo "INFO: drift detected but no drifted resource is being applied; not blocking apply."
fi
exit 0
