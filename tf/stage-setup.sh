#!/usr/bin/env bash
# shellcheck shell=bash
# stage-setup.sh — the setup hook of mars-stages.yaml: mars runs it in the
# project root before each stage of plan-all, plan-stage and apply-stage,
# with MARS_STAGE set to the stage's name (luthersystems/mars docs/stages.md).
#
# It does the stage's own part of what plan.sh did per stage before #114:
# tfSetup and bootstrap.sh (utils.sh), the cloud's .tf files and the
# cloud-provision bootstrap preflight (prepareCloudStage). The credentials are
# set up by the script that called mars (setupCloudCredentials), because a
# hook runs as a child of mars and its exports never reach mars or terraform.
#
# A script that runs one stage prepares it itself, in its own shell, and sets
# MARS_STAGE_PREPARED to that stage; the hook then has nothing to do.

set -euo pipefail

stage="${MARS_STAGE:?MARS_STAGE must be set: stage-setup.sh is the setup hook of mars-stages.yaml}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export MARS_PROJECT_ROOT

if [[ "${MARS_STAGE_PREPARED:-}" == "$stage" ]]; then
  exit 0
fi

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. "$SCRIPT_DIR/stages.sh"

# A bootstrap.sh that exports a variable (account-setup's JUMP_ROLE_ARN)
# cannot work from here: the export dies with this process. Fail the stage
# instead of planning it with the wrong identity; such a stage runs through
# a one-stage script (plan.sh, apply-plan.sh, apply-with-outputs.sh), which
# sources bootstrap.sh in its own shell.
jump_before="${JUMP_ROLE_ARN:-}"
enterStage "$stage"
if [[ "${JUMP_ROLE_ARN:-}" != "$jump_before" ]]; then
  echo "ERROR: stage $stage: bootstrap.sh sets JUMP_ROLE_ARN, which mars's setup hook cannot pass on; run this stage with plan.sh, not plan-all.sh. [#114]" >&2
  exit 1
fi

prepareCloudStage
