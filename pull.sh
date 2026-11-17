#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

# mars infra-pull (luthersystems/mars docs/infra-repo.md): merge the
# template's origin/main when there is an origin remote (an -infra clone has
# none), then infra/main. "Nothing to merge into" (an unborn HEAD, or a
# history that shares no commit with infra/main) is not an error for a pull.
marsInfra infra-pull
