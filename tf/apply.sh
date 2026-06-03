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
# persistInfra = gitMergeInfraMain + gitCommit + (required) gitPushInfra.
# Hardened over a bare gitCommit/gitPushInfra so a missing infra remote is a
# LOUD failure instead of a silent no-op that leaves <project>-infra empty
# (issue #143).
persistInfra
