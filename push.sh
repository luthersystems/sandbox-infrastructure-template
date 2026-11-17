#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

# mars infra-push: git push infra HEAD. A failure warns; it never fails.
marsInfra infra-push
