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
# drift_plan includes an actionable resource_changes entry so the plan-change
# gate in drift-check.sh treats drift as apply-blocking (exit 2). Tests that
# want to exercise the "drift but plan is no-op" gate use other fixtures below.
drift_plan='{
  "resource_drift": [{"address": "aws_s3_bucket.example", "type": "aws_s3_bucket"}],
  "resource_changes": [{"address": "aws_s3_bucket.example", "change": {"actions": ["update"]}}]
}'
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

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "stage flag: drift.json ALSO created (Argo compat)"
else
  fail "stage flag: drift.json should also exist when --stage is used"
fi

if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift-cloud-provision.json" >/dev/null 2>&1; then
  pass "stage flag: drift_detected is true"
else
  fail "stage flag: drift_detected field missing or wrong"
fi

# Verify both files have identical content
if diff -q "$WORKDIR/outputs/drift.json" "$WORKDIR/outputs/drift-cloud-provision.json" >/dev/null 2>&1; then
  pass "stage flag: drift.json and drift-cloud-provision.json are identical"
else
  fail "stage flag: drift.json and drift-cloud-provision.json differ"
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

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "stage+ignore: drift.json ALSO created (Argo compat)"
else
  fail "stage+ignore: drift.json should also exist when --stage is used"
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

# ============================================================
# Test 11: All-false-positive drift (null vs empty) — exit 0, no drift.json
# ============================================================
echo ""
echo "Test 11: All-false-positive drift (null vs empty equivalences)..."

rm -rf "$WORKDIR/outputs"
false_positive_plan='{"resource_drift": [
  {
    "address": "aws_s3_bucket.example",
    "type": "aws_s3_bucket",
    "change": {
      "before": {"cors_rule": null, "grant": null, "lifecycle_rule": null, "logging": null, "replication_configuration": null, "server_side_encryption_configuration": [], "versioning": [{"enabled": false, "mfa_delete": false}], "website": null, "policy": null},
      "after":  {"cors_rule": [],   "grant": [],   "lifecycle_rule": [],   "logging": {},   "replication_configuration": "",  "server_side_encryption_configuration": [], "versioning": [{"enabled": false, "mfa_delete": false}], "website": [],   "policy": ""}
    }
  }
]}'
result="$(run_drift_check "$false_positive_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "false-positive: exit code 0 (no real drift)"
else
  fail "false-positive: expected exit 0, got $exit_code"
fi

if [[ ! -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "false-positive: drift.json not created"
else
  fail "false-positive: drift.json should not exist for false-positive only drift"
fi

# ============================================================
# Test 12: Mixed real + false-positive drift — exit 2, only real drift in report
# ============================================================
echo ""
echo "Test 12: Mixed real and false-positive drift..."

rm -rf "$WORKDIR/outputs"
mixed_plan='{
  "resource_drift": [
    {
      "address": "aws_s3_bucket.false_positive",
      "type": "aws_s3_bucket",
      "change": {
        "before": {"cors_rule": null, "tags": {"env": "prod"}},
        "after":  {"cors_rule": [],   "tags": {"env": "prod"}}
      }
    },
    {
      "address": "aws_instance.real_drift",
      "type": "aws_instance",
      "change": {
        "before": {"instance_type": "t3.micro", "tags": {"Name": "old"}},
        "after":  {"instance_type": "t3.small", "tags": {"Name": "new"}}
      }
    }
  ],
  "resource_changes": [
    {"address": "aws_instance.real_drift", "change": {"actions": ["update"]}}
  ]
}'
result="$(run_drift_check "$mixed_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "mixed: exit code 2 (real drift present)"
else
  fail "mixed: expected exit 2, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "mixed: drift.json created"
else
  fail "mixed: drift.json not created"
fi

if jq -e '.drift_count == 1' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "mixed: drift_count is 1 (false positive filtered out)"
else
  fail "mixed: drift_count should be 1"
fi

if jq -e '.resources[0].address == "aws_instance.real_drift"' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "mixed: only real drift resource in report"
else
  fail "mixed: expected aws_instance.real_drift in report"
fi

# ============================================================
# Test 13: Nested null-vs-empty inside objects/arrays — exit 0
# ============================================================
echo ""
echo "Test 13: Nested null-vs-empty inside objects and arrays..."

rm -rf "$WORKDIR/outputs"
nested_plan='{"resource_drift": [
  {
    "address": "aws_lb.example",
    "type": "aws_lb",
    "change": {
      "before": {"access_logs": [{"bucket": "", "enabled": false, "prefix": null}], "subnet_mapping": [{"outpost_arn": null}], "tags": {}},
      "after":  {"access_logs": [{"bucket": "", "enabled": false, "prefix": ""}],  "subnet_mapping": [{"outpost_arn": ""}],  "tags": null}
    }
  }
]}'
result="$(run_drift_check "$nested_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "nested: exit code 0 (no real drift)"
else
  fail "nested: expected exit 0, got $exit_code"
fi

if [[ ! -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "nested: drift.json not created"
else
  fail "nested: drift.json should not exist for nested false-positive drift"
fi

# ============================================================
# Test 14: TEMPLATE_VERSION env var is used when set
# ============================================================
echo ""
echo "Test 14: TEMPLATE_VERSION env var..."

rm -rf "$WORKDIR/outputs"
result="$(TEMPLATE_VERSION="v1.2.3" run_drift_check '{"resource_drift": []}')"

if echo "$result" | grep -q "template_version=v1.2.3"; then
  pass "env var: template_version=v1.2.3 printed"
else
  fail "env var: expected template_version=v1.2.3 in output"
fi

# ============================================================
# Test 15: Without TEMPLATE_VERSION, falls back to unknown
# ============================================================
echo ""
echo "Test 15: No TEMPLATE_VERSION falls back to unknown..."

rm -rf "$WORKDIR/outputs"
result="$(unset TEMPLATE_VERSION; run_drift_check '{"resource_drift": []}')"

if echo "$result" | grep -q "template_version=unknown"; then
  pass "fallback: template_version=unknown printed"
else
  fail "fallback: expected template_version=unknown in output"
fi

# ============================================================
# Test 16: Drift + resource_changes all no-op — exit 0 (INFO-only)
# Reproduces the issue #93 production scenario: terraform plan reports
# "No changes" but resource_drift lists provider-populated Computed attrs.
# Drift should be reported but not block apply.
# ============================================================
echo ""
echo "Test 16: Drift + plan is no-op (Computed-attr false-positive gate)..."

rm -rf "$WORKDIR/outputs"
noop_plan='{
  "resource_drift": [
    {
      "address": "module.aws_iam.aws_iam_role.writer",
      "type": "aws_iam_role",
      "change": {
        "before": {"managed_policy_arns": []},
        "after":  {"managed_policy_arns": ["arn:aws:iam::aws:policy/example"]}
      }
    }
  ],
  "resource_changes": [
    {"address": "module.aws_iam.aws_iam_role.writer", "change": {"actions": ["no-op"]}}
  ]
}'
result="$(run_drift_check "$noop_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "noop-plan: exit code 0 (not blocking apply)"
else
  fail "noop-plan: expected exit 0, got $exit_code"
fi

if echo "$result" | grep -q "drift detected but plan has no actionable changes"; then
  pass "noop-plan: INFO line printed"
else
  fail "noop-plan: expected INFO line about no actionable changes"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "noop-plan: drift.json still written (diagnostic artifact)"
else
  fail "noop-plan: drift.json should exist even when not blocking"
fi

if jq -e '.drift_detected == true' "$WORKDIR/outputs/drift.json" >/dev/null 2>&1; then
  pass "noop-plan: drift_detected is true in report"
else
  fail "noop-plan: drift_detected should still be true"
fi

# ============================================================
# Test 17: Drift + resource_changes all "read" — exit 0
# Data-source refreshes are not actionable.
# ============================================================
echo ""
echo "Test 17: Drift + plan has only data-source reads..."

rm -rf "$WORKDIR/outputs"
read_plan='{
  "resource_drift": [{"address": "aws_s3_bucket.example"}],
  "resource_changes": [
    {"address": "data.aws_caller_identity.current", "change": {"actions": ["read"]}}
  ]
}'
result="$(run_drift_check "$read_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "read-only: exit code 0"
else
  fail "read-only: expected exit 0, got $exit_code"
fi

# ============================================================
# Test 18: Drift + resource_changes absent — exit 0
# ============================================================
echo ""
echo "Test 18: Drift + resource_changes key absent (refresh-only shape)..."

rm -rf "$WORKDIR/outputs"
refresh_only_plan='{"resource_drift": [{"address": "aws_s3_bucket.example"}]}'
result="$(run_drift_check "$refresh_only_plan")"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "refresh-only shape: exit code 0"
else
  fail "refresh-only shape: expected exit 0, got $exit_code"
fi

# ============================================================
# Test 19: Drift + --strict + resource_changes absent — exit 2
# drift-refresh.sh invariant: standalone alarm still fires.
# ============================================================
echo ""
echo "Test 19: Drift + --strict + no resource_changes (refresh-only alarm)..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$refresh_only_plan" --strict)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "strict refresh-only: exit code 2"
else
  fail "strict refresh-only: expected exit 2, got $exit_code"
fi

if [[ -f "$WORKDIR/outputs/drift.json" ]]; then
  pass "strict refresh-only: drift.json created"
else
  fail "strict refresh-only: drift.json not created"
fi

# ============================================================
# Test 20: Drift + --strict + resource_changes all no-op — exit 2
# --strict bypasses the plan-change gate entirely.
# ============================================================
echo ""
echo "Test 20: Drift + --strict + plan all no-op..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$noop_plan" --strict)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 2 ]]; then
  pass "strict noop-plan: exit code 2"
else
  fail "strict noop-plan: expected exit 2, got $exit_code"
fi

# ============================================================
# Test 21: Drift + --ignore-drift + plan has changes — exit 0
# --ignore-drift still wins over the gate (existing behavior).
# ============================================================
echo ""
echo "Test 21: Drift + --ignore-drift with actionable plan..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan" --ignore-drift)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "ignore-drift + changes: exit code 0 (ignore-drift wins)"
else
  fail "ignore-drift + changes: expected exit 0, got $exit_code"
fi

# ============================================================
# Test 22: Drift + --strict + --ignore-drift — exit 0
# --ignore-drift takes precedence over --strict.
# ============================================================
echo ""
echo "Test 22: Drift + --strict + --ignore-drift..."

rm -rf "$WORKDIR/outputs"
result="$(run_drift_check "$drift_plan" --strict --ignore-drift)"
exit_code="$(echo "$result" | tail -1)"

if [[ "$exit_code" -eq 0 ]]; then
  pass "strict + ignore-drift: exit code 0"
else
  fail "strict + ignore-drift: expected exit 0, got $exit_code"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
