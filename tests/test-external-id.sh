#!/usr/bin/env bash
set -euo pipefail

# Validates that every assume_role block in providers.tf includes external_id.
# This prevents regressions where new providers are added without
# confused-deputy protection.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$SCRIPT_DIR/tf"

# Find all providers.tf files across stages
while IFS= read -r providers_file; do
  stage="$(basename "$(dirname "$providers_file")")"

  # Count assume_role blocks and external_id lines within them
  assume_role_count="$(grep -c 'assume_role {' "$providers_file" || true)"
  external_id_count="$(grep -c 'external_id' "$providers_file" || true)"

  if [[ "$assume_role_count" -eq 0 ]]; then
    pass "$stage/providers.tf: no assume_role blocks (nothing to check)"
    continue
  fi

  if [[ "$external_id_count" -eq "$assume_role_count" ]]; then
    pass "$stage/providers.tf: all $assume_role_count assume_role block(s) have external_id"
  else
    fail "$stage/providers.tf: found $assume_role_count assume_role block(s) but only $external_id_count external_id line(s)"
  fi
done < <(find "$TF_DIR" -name providers.tf -type f | sort)

# Verify aws_external_id variable is declared in each stage that uses assume_role
echo ""
echo "Checking aws_external_id variable declarations..."

while IFS= read -r providers_file; do
  stage_dir="$(dirname "$providers_file")"
  stage="$(basename "$stage_dir")"

  assume_role_count="$(grep -c 'assume_role {' "$providers_file" || true)"
  [[ "$assume_role_count" -eq 0 ]] && continue

  # Search all .tf files in the stage for the variable declaration
  if grep -rq 'variable "aws_external_id"' "$stage_dir"/*.tf 2>/dev/null; then
    pass "$stage: aws_external_id variable declared"
  else
    fail "$stage: aws_external_id variable NOT declared (but assume_role blocks exist)"
  fi
done < <(find "$TF_DIR" -name providers.tf -type f | sort)

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
