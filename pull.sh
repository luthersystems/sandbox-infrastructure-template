#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

gitMergeOriginMain
# rc 2: nothing to merge into (an unborn HEAD, or a history that shares no
# commit with infra/main). Not an error for a pull; say so and stop.
rc=0
gitMergeInfraMain || rc=$?
if [[ "$rc" -eq 2 ]]; then
  echo "ℹ️  Nothing pulled from infra/main."
  exit 0
fi
exit "$rc"
