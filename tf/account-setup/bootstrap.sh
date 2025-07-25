#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=../

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared terraform helpers
source "${SCRIPT_DIR}/../tf_helpers.sh"

export JUMP_ROLE_ARN="$(mustGetTfVar "org_creator_role_arn")"
