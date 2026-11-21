#!/usr/bin/env bash
# shellcheck shell=bash
# plan-all.sh — Plan several stages and aggregate the results.
#
# Usage: bash plan-all.sh
#
# A thin entrypoint over `mars default plan-all` (mars-stages.yaml,
# tf/stages.sh, #114). ui-core runs it by this name; mars does the work: per
# stage the setup hook (tf/stage-setup.sh), init, plan, plan JSON and change
# counts, the apply of cloud-provision on a new project (no managed resource
# in its state, so the later stages can read its remote state), the summary,
# the canonical plan alias and the provider strip.
#
# Configurable via environment:
#   PLAN_STAGES        Space-separated stages to plan, in order
#                      (default: "cloud-provision custom-stack-provision").
#                      Each must be a stage of mars-stages.yaml. A stage
#                      whose bootstrap.sh exports JUMP_ROLE_ARN
#                      (account-setup) fails here: mars runs the stage setup
#                      in a child process, so the export cannot reach
#                      terraform. Plan it with plan.sh. ui-core plans only
#                      cloud-provision and custom-stack-provision here.
#   PLAN_ALL_CONTINUE  true: this run continues a plan-all that an earlier
#                      step of the same workflow started, and keeps that
#                      step's plan JSON and summary rows. ui-core plans the
#                      custom stack in its own step, so the step that runs
#                      customer Terraform does not get the GitHub token that
#                      cloud-provision needs (ui-infrastructure#442).
#   TF_CLI_ARGS_plan   A -out=<name> in it (ui-core's -out={planID}.tfplan)
#                      names every stage's saved plan, for apply-plan.sh.
#
# Outputs (in outputs/):
#   tfplan-<stage>.json  Per-stage plan JSON.
#   tfplan.json          Canonical "full plan" alias for Argo / Oracle /
#                        reliable consumers that expect one tfplan.json
#                        (#127): custom-stack-provision's plan when present,
#                        so the post-import tag-only classifier has its
#                        resource_changes; else the last stage with a plan.
#   plan-summary.json    Change counts per stage and in total.
#
# Exit codes:
#   0 — Every stage planned (changes are in plan-summary.json, not the exit
#       code: Argo fails a step on any non-zero exit, #67).
#   1 — A stage failed to plan, the new-project apply failed, or the config
#       is bad.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. "$SCRIPT_DIR/stages.sh"
logTemplateVersion
logPresetsVersion

read -ra stages <<<"${PLAN_STAGES:-cloud-provision custom-stack-provision}"
if [[ ${#stages[@]} -eq 0 ]]; then
  echo "ERROR: PLAN_STAGES names no stage" >&2
  exit 1
fi
args=(--stages "$(IFS=,; echo "${stages[*]}")")
if [[ "${PLAN_ALL_CONTINUE:-false}" == "true" ]]; then
  args+=(--continue)
fi
plan_file="$(stagePlanFile)"
if [[ -n "$plan_file" ]]; then
  args+=(--plan-file "$plan_file")
fi
exportStageParallelism

# The credentials once, in this shell, so mars and every stage's terraform
# inherit them; the hook sets up each stage's files and preflight.
cd "$MARS_PROJECT_ROOT"
setupCloudCredentials
trap 'cleanupCloudEnv' EXIT

marsStages plan-all "${args[@]}"
