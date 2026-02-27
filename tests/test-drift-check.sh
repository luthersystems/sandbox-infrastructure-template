#!/usr/bin/env bash
set -euo pipefail

# Tests for tf/drift-check.sh
# Uses a mock terraform binary that returns configurable JSON.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Mock terraform: returns JSON based on plan filename ---
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"

# Mock terraform that logs calls and returns configurable show output
TERRAFORM_LOG="$WORKDIR/terraform-calls.log"
TERRAFORM_SHOW_OUTPUT="$WORKDIR/show-output.json"

cat > "$MOCK_BIN/terraform" <<'OUTER'
#!/usr/bin/env bash
LOG_FILE="__LOG_FILE__"
SHOW_OUTPUT="__SHOW_OUTPUT__"
echo "$*" >> "$LOG_FILE"
if [[ "$1" == "show" && "$2" == "-json" ]]; then
  cat "$SHOW_OUTPUT"
fi
OUTER
# Patch in actual paths
sed -i.bak "s|__LOG_FILE__|$TERRAFORM_LOG|g" "$MOCK_BIN/terraform"
sed -i.bak "s|__SHOW_OUTPUT__|$TERRAFORM_SHOW_OUTPUT|g" "$MOCK_BIN/terraform"
rm -f "$MOCK_BIN/terraform.bak"
chmod +x "$MOCK_BIN/terraform"

# Mock jq — use real jq (required)
if ! command -v jq &>/dev/null; then
  echo "SKIP: jq is required for these tests" >&2
  exit 0
fi

export PATH="$MOCK_BIN:$PATH"

# --- Helper: run drift-check with given plan JSON and flags ---
run_drift_check() {
  local plan_json="$1"
  shift
  : > "$TERRAFORM_LOG"
  echo "$plan_json" > "$TERRAFORM_SHOW_OUTPUT"

  # Create a fake plan file
  echo "fake-plan-binary" > "$WORKDIR/test.tfplan"

  local exit_code=0
  (
    cd "$WORKDIR"
    export MARS_PROJECT_ROOT="$WORKDIR"
    bash "$REPO_ROOT/tf/drift-check.sh" test.tfplan "$@"
  ) 2>&1 || exit_code=$?
  echo "$exit_code"
}

# ============================================================
# Test 1: No drift — exit 0, no drift.json
# ============================================================
echo "Test 1: No drift detected..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check '{"resource_drift": []}')"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "no drift: exit code 0"
else
  fail "no drift: expected exit 0, got $exit_code"
fi

if [[ ! -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "no drift: drift.json not created"
else
  fail "no drift: drift.json should not exist"
fi

# ============================================================
# Test 2: Drift detected — exit 2, drift.json created
# ============================================================
echo ""
echo "Test 2: Drift detected..."

rm -rf "$WORKDIR/outputs"
drift_plan='{"resource_drift": [{"address": "aws_s3_bucket.example", "type": "aws_s3_bucket"}]}'
result="$(run_drift_check "$drift_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "drift: exit code 2"
else
  fail "drift: expected exit 2, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "drift: drift.json created"
else
  fail "drift: drift.json not created"
fi

# Validate JSON structure
if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "drift: drift_detected is true"
else
  fail "drift: drift_detected field missing or wrong"
fi

if jq -e '.drift_count == 1' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "drift: drift_count is 1"
else
  fail "drift: drift_count wrong"
fi

if jq -e '.resources | length == 1' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "drift: resources array has 1 entry"
else
  fail "drift: resources array wrong"
fi

if jq -e '.resources[0].address == "aws_s3_bucket.example"' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "drift: resource address propagated"
else
  fail "drift: resource address not in drift.json"
fi

# ============================================================
# Test 3: Drift + --ignore-drift — exit 0, drift.json created
# ============================================================
echo ""
echo "Test 3: Drift with --ignore-drift..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan" --ignore-drift)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "ignore-drift: exit code 0"
else
  fail "ignore-drift: expected exit 0, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "ignore-drift: drift.json still created"
else
  fail "ignore-drift: drift.json not created"
fi

if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "ignore-drift: drift_detected is true in drift.json"
else
  fail "ignore-drift: drift.json content wrong"
fi

# ============================================================
# Test 4: Missing plan file — exit 1
# ============================================================
echo ""
echo "Test 4: Missing plan file..."

rm -f "$WORKDIR/test.tfplan"
set +e
err_output="$(
  cd "$WORKDIR"
  export MARS_PROJECT_ROOT="$WORKDIR"
  bash "$REPO_ROOT/tf/drift-check.sh" nonexistent.tfplan 2>&1
)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 1 ]]; then
  pass "missing file: exit code 1"
else
  fail "missing file: expected exit 1, got $exit_code"
fi

if echo "$err_output" | grep -q "plan file not found"; then
  pass "missing file: error message mentions plan file"
else
  fail "missing file: unexpected error: $err_output"
fi

# ============================================================
# Test 5: No arguments — exit 1 (usage error)
# ============================================================
echo ""
echo "Test 5: No arguments..."

set +e
err_output="$(bash "$REPO_ROOT/tf/drift-check.sh" 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 1 ]]; then
  pass "no args: exit code 1"
else
  fail "no args: expected exit 1, got $exit_code"
fi

if echo "$err_output" | grep -q "Usage"; then
  pass "no args: shows usage"
else
  fail "no args: expected usage message"
fi

# ============================================================
# Test 6: Plan with no resource_drift key — exit 0 (treated as no drift)
# ============================================================
echo ""
echo "Test 6: Plan JSON without resource_drift key..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check '{}')"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "no key: exit code 0"
else
  fail "no key: expected exit 0, got $exit_code"
fi

if [[ ! -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "no key: drift.json not created"
else
  fail "no key: drift.json should not exist when no drift"
fi

# ============================================================
# Test 7: terraform show -json is called with correct plan file
# ============================================================
echo ""
echo "Test 7: Terraform called with correct plan file..."

: > "$TERRAFORM_LOG"
run_drift_check '{"resource_drift": []}' >/dev/null

if grep -q "show -json test.tfplan" "$TERRAFORM_LOG"; then
  pass "terraform show called with plan file"
else
  fail "terraform show not called correctly"
fi

# ============================================================
# Test 8: --stage flag produces drift-<stage>.json
# ============================================================
echo ""
echo "Test 8: --stage flag produces stage-specific file..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan" --stage cloud-provision)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "stage flag: exit code 2"
else
  fail "stage flag: expected exit 2, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift-cloud-provision.json" ]]; then
  pass "stage flag: drift-cloud-provision.json created"
else
  fail "stage flag: drift-cloud-provision.json not created"
fi

if [[ ! -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "stage flag: drift.json NOT created (correct)"
else
  fail "stage flag: drift.json should not exist when --stage is used"
fi

if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift-cloud-provision.json" >/dev/null 2>&1; then
  pass "stage flag: drift_detected is true"
else
  fail "stage flag: drift_detected field missing or wrong"
fi

# ============================================================
# Test 9: --stage + --ignore-drift produces file and exits 0
# ============================================================
echo ""
echo "Test 9: --stage with --ignore-drift..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan" --stage mystack --ignore-drift)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "stage+ignore: exit code 0"
else
  fail "stage+ignore: expected exit 0, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift-mystack.json" ]]; then
  pass "stage+ignore: drift-mystack.json created"
else
  fail "stage+ignore: drift-mystack.json not created"
fi

if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift-mystack.json" >/dev/null 2>&1; then
  pass "stage+ignore: drift_detected is true"
else
  fail "stage+ignore: drift_detected field missing or wrong"
fi

if jq -e '.drift_count == 1' "$WORKDIR/outputs/drift-mystack.json" >/dev/null 2>&1; then
  pass "stage+ignore: drift_count is 1"
else
  fail "stage+ignore: drift_count wrong"
fi

# ============================================================
# Test 10: No --stage still produces drift.json (backwards compat)
# ============================================================
echo ""
echo "Test 10: No --stage still produces drift.json..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "no stage: exit code 2 (drift detected)"
else
  fail "no stage: expected exit 2, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "no stage: drift.json created (backwards compat)"
else
  fail "no stage: drift.json not created"
fi

if [[ ! -f "$WORKDIR/outputs/drift-.json" ]]; then
  pass "no stage: no empty-stage filename"
else
  fail "no stage: drift-.json should not exist"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
