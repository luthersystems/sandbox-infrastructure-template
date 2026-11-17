#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. ./utils.sh
logTemplateVersion
logPresetsVersion

# Merge infra/main before Terraform runs, so a developer's stale checkout
# applies with teammates' edits. A failed merge stops the apply, as it always
# did; --abort-on-conflict cleans it up first, so the snapshot of a later run
# cannot push conflict markers. rc 2 (nothing to merge into: an unborn HEAD,
# or ui-core's squashed tree, which shares no commit with infra/main) does
# not: the snapshot after the apply lands on top of infra/main (#160).
merge_rc=0
gitMergeInfraMain --abort-on-conflict || merge_rc=$?
if [[ "$merge_rc" -ne 0 && "$merge_rc" -ne 2 ]]; then
  exit "$merge_rc"
fi

tfInit
tfApply
# After the apply: the snapshot is the deployed tree, and a git problem must
# not fail a deploy that already applied. It fetches infra/main again: a
# teammate may have pushed during the apply, and the push must fast-forward.
gitSnapshotCommit "auto-commit: infrastructure changes [ci skip]" ||
  echo "⚠️  [git-infra] WARNING: gitSnapshotCommit returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
gitPushInfra
