#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

# mars infra-commit [message]: commit the project tree. 0 committed or
# nothing to commit; 1 refused (a conflict, rebase, cherry-pick or revert)
# or failed, nothing committed.
# "--" ends the flags, so a message that starts with "-" is still the message.
marsInfra infra-commit ${1+-- "$1"}
