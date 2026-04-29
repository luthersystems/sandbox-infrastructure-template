#!/usr/bin/env bash
set -euo pipefail

# Validates that cloud-provision exposes a consistent set of state-backend
# outputs across both cloud templates so consumers (ui-core, drift checks,
# debug tooling) can read one canonical key regardless of cloud.
#
# The contract:
#   - Both `aws-resources.tf.tmpl` and `gcp-resources.tf.tmpl` must declare
#     `output "state_workspace_custom"` and `output "state_backend_custom"`.
#   - Only one of the two templates is activated per stack via
#     _selectCloudFiles(), so the duplicated output names do not collide at
#     terraform validate time.
#
# This is a static grep test — it does not exercise terraform itself.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOUD_DIR="$REPO_ROOT/tf/cloud-provision"

EXPECTED_OUTPUTS=(
  state_workspace_custom
  state_backend_custom
)

CLOUD_TEMPLATES=(
  "aws-resources.tf.tmpl"
  "gcp-resources.tf.tmpl"
)

for tmpl in "${CLOUD_TEMPLATES[@]}"; do
  path="$CLOUD_DIR/$tmpl"
  if [[ ! -f "$path" ]]; then
    fail "$tmpl: not found at $path"
    continue
  fi

  for name in "${EXPECTED_OUTPUTS[@]}"; do
    if grep -Eq "^output \"$name\" \{" "$path"; then
      pass "$tmpl: declares output \"$name\""
    else
      fail "$tmpl: missing output \"$name\""
    fi
  done
done

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
