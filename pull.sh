#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

# An -infra clone has no origin (the template) remote; skip the template
# merge so the infra/main merge still runs.
if git -C "$MARS_PROJECT_ROOT" remote get-url origin >/dev/null 2>&1; then
  gitMergeOriginMain
else
  echo "ℹ️  No origin remote (an -infra clone) - skipping the template merge."
fi
# rc 2: nothing to merge into (an unborn HEAD, or a history that shares no
# commit with infra/main). Not an error for a pull; say so and stop.
rc=0
gitMergeInfraMain || rc=$?
if [[ "$rc" -eq 2 ]]; then
  echo "ℹ️  Nothing pulled from infra/main."
  exit 0
fi
exit "$rc"
