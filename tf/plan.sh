#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"
. ./utils.sh

tfInit
tfPlan

# Export JSON plan for structured analysis (best-effort)
planfile=$(find . -maxdepth 1 -name '*.tfplan' -print -quit 2>/dev/null)
if [[ -n "$planfile" ]]; then
  mkdir -p "$MARS_PROJECT_ROOT/outputs"
  terraform show -json "$planfile" > "$MARS_PROJECT_ROOT/outputs/tfplan-${workspace}.json"
  echo "Plan JSON written to $MARS_PROJECT_ROOT/outputs/tfplan-${workspace}.json"
fi
