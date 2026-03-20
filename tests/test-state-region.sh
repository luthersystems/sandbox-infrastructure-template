#!/usr/bin/env bash
set -euo pipefail

# Validates that downstream remote-state data sources read their region from
# cloud-provision outputs (not bare var.aws_region), so Terraform connects to
# the correct S3 state bucket regardless of the project's resource region.
#
# Note: the AWS *provider* region in cloud-provision/providers.tf must use
# var.aws_region — that is the project's resource region, NOT the state bucket
# region. Only backend/remote-state configs need bootstrap_state_region.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$SCRIPT_DIR/tf"

# --- Check 1: cloud-provision provider must use var.aws_region ---
echo "Checking cloud-provision/providers.tf provider regions..."

PROVIDERS_FILE="$TF_DIR/cloud-provision/providers.tf"

if [[ ! -f "$PROVIDERS_FILE" ]]; then
  fail "cloud-provision/providers.tf not found"
else
  # The provider region must use var.aws_region (the project resource region).
  # Using bootstrap_state_region here is incorrect — that is the state bucket
  # region, not where resources should be created.
  bad_lines="$(grep -n 'region\s*=' "$PROVIDERS_FILE" \
    | grep 'bootstrap_state_region' || true)"

  if [[ -z "$bad_lines" ]]; then
    pass "cloud-provision/providers.tf: provider region uses var.aws_region (not bootstrap_state_region)"
  else
    fail "cloud-provision/providers.tf: provider region should use var.aws_region, not bootstrap_state_region:"
    echo "$bad_lines" | sed 's/^/         /'
  fi
fi

# --- Check 2: Downstream remote-state data sources ---
echo ""
echo "Checking downstream remote-state region references..."

# These files contain terraform_remote_state blocks that access S3 state
# created by cloud-provision. Their region should come from the
# cloud-provision output, not var.aws_region.
STATE_FILES=(
  "k8s-provision/vm-provision-state.tf"
)

for rel_path in "${STATE_FILES[@]}"; do
  state_file="$TF_DIR/$rel_path"

  if [[ ! -f "$state_file" ]]; then
    fail "$rel_path: file not found"
    continue
  fi

  bad_lines="$(grep -n 'region\s*=' "$state_file" \
    | grep 'var\.aws_region' || true)"

  if [[ -z "$bad_lines" ]]; then
    pass "$rel_path: region references cloud-provision output (not bare var.aws_region)"
  else
    fail "$rel_path: uses var.aws_region for state region (should use cloud-provision output):"
    echo "$bad_lines" | sed 's/^/         /'
  fi
done

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
