#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source helpers
. "$MARS_PROJECT_ROOT/shell_utils.sh"

# Source shared terraform helpers
source "${SCRIPT_DIR}/../../shell_utils.sh"

JUMP_ROLE_ARN="$(mustGetTfVar "org_creator_role_arn")"
export JUMP_ROLE_ARN
