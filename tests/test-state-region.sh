#!/usr/bin/env bash
set -euo pipefail

# Validates that state-access patterns use bootstrap_state_region (not bare
# var.aws_region) so Terraform connects to the correct S3 region even when
# aws_region diverges from the actual state bucket location.
#
# Checks:
#   1. cloud-provision/providers.tf provider region lines use bootstrap_state_region
#   2. Remote-state data sources in downstream stages read region from the
#      cloud-provision output, not var.aws_region

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$SCRIPT_DIR/tf"

# --- Check 1: cloud-provision provider region lines ---
echo "Checking cloud-provision/providers.tf provider regions..."

PROVIDERS_FILE="$TF_DIR/cloud-provision/providers.tf"

if [[ ! -f "$PROVIDERS_FILE" ]]; then
  fail "cloud-provision/providers.tf not found"
else
  # Extract lines that set region inside provider blocks (ignore comments)
  # A bare 'var.aws_region' without bootstrap_state_region is the bug pattern.
  bad_lines="$(grep -n 'region\s*=' "$PROVIDERS_FILE" \
    | grep 'var\.aws_region' \
    | grep -v 'bootstrap_state_region' || true)"

  if [[ -z "$bad_lines" ]]; then
    pass "cloud-provision/providers.tf: all provider region lines use bootstrap_state_region"
  else
    fail "cloud-provision/providers.tf: bare var.aws_region in provider region (should use bootstrap_state_region):"
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
