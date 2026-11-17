#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. ./utils.sh
logTemplateVersion
logPresetsVersion

tfInit
tfApply
# After the apply, not before: the snapshot is the deployed tree, and a git
# problem must not stop a deploy. This used to merge infra/main under set -e
# before Terraform ran; on ui-core's squashed history that merge always fails
# ("refusing to merge unrelated histories"), so the apply never ran (#160).
gitSnapshotCommit "auto-commit: infrastructure changes [ci skip]" ||
  echo "⚠️  [git-infra] WARNING: gitSnapshotCommit returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
gitPushInfra
