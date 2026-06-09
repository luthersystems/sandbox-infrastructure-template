#!/bin/bash
# destroy.sh — Destroy a lifecycle stage's terraform-managed resources.
#
# Usage: bash destroy.sh <lifecycle> [--ignore-drift]
#
# Default behavior is a pre-destroy convergence gate (#2048): tfDestroy runs
# `mars apply --forbid-resource-changes` before `destroy`, which
#   - executes any `removed { lifecycle { destroy = false } }` forgets the
#     composed archive carries (adopted / reverse-imported resources are
#     released from state WITHOUT being deleted), and
#   - fails the job if the archive would create/update/delete any real
#     resource — unexpected changes at destroy time mean drift or a
#     half-applied stack, and tearing infrastructure down on top of that
#     deserves a human decision, not an automatic destroy.
#
# --ignore-drift is that human decision (same end-to-end override channel as
# the apply path: reliable API ?ignore_drift=true → workflow args → argv).
# See tfDestroy in utils.sh for the exact semantics matrix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: destroy.sh <lifecycle> [--ignore-drift]" >&2
  exit 1
fi
lifecycle="$1"
shift

ignore_drift=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore-drift) ignore_drift=true; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Source utils.sh (expects $1 = workspace/lifecycle) — mirrors apply-plan.sh.
set -- "$lifecycle"
. ./utils.sh
logTemplateVersion
logPresetsVersion

tfInit
if [[ "$ignore_drift" == "true" ]]; then
  tfDestroy --ignore-drift
else
  tfDestroy
fi
gitCommit
