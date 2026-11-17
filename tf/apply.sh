#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. ./utils.sh
logTemplateVersion
logPresetsVersion

# Merge infra/main before Terraform runs, so a developer's stale checkout
# applies with teammates' edits. A real merge failure (conflicts) stops the
# apply, as it always did. Unrelated histories (rc 2) do not: that is
# ui-core's squashed project tree, which never shares a commit with
# infra/main and is the deploy's source of truth; the snapshot after the
# apply pushes it on top of infra/main (#160).
merge_rc=0
gitMergeInfraMain || merge_rc=$?
if [[ "$merge_rc" -ne 0 && "$merge_rc" -ne 2 ]]; then
  exit "$merge_rc"
fi

tfInit
tfApply
# After the apply: the snapshot is the deployed tree, and a git problem must
# not fail a deploy that already applied.
gitSnapshotCommit "auto-commit: infrastructure changes [ci skip]" ||
  echo "⚠️  [git-infra] WARNING: gitSnapshotCommit returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
gitPushInfra
