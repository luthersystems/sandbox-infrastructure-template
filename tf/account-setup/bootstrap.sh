#!/usr/bin/env bash
set -euo pipefail

_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$_BOOTSTRAP_DIR/.." && pwd)}"

# Source helpers
. "$MARS_PROJECT_ROOT/shell_utils.sh"

# Source shared terraform helpers
source "${_BOOTSTRAP_DIR}/../../shell_utils.sh"

JUMP_ROLE_ARN="$(mustGetTfVar "org_creator_role_arn")"
export JUMP_ROLE_ARN
