#!/usr/bin/env bash
set -euo pipefail

# Tests for tf/apply-with-outputs.sh, tf/apply-plan.sh, and tf/drift-refresh.sh.
# Uses mock terraform and apply.sh binaries to verify behavior.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v jq &>/dev/null; then
  echo "SKIP: jq is required for these tests" >&2
  exit 0
fi

# --- Build a fake project tree ---
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT/tf/auto-vars"
mkdir -p "$PROJECT/tf/default"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"
mkdir -p "$PROJECT/outputs"

cat > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

echo '{"cloud_provider": "aws"}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

# Copy real scripts
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"
cp "$REPO_ROOT/tf/utils.sh" "$PROJECT/tf/utils.sh"
cp "$REPO_ROOT/tf/drift-check.sh" "$PROJECT/tf/drift-check.sh"
cp "$REPO_ROOT/tf/drift-refresh.sh" "$PROJECT/tf/drift-refresh.sh"
cp "$REPO_ROOT/tf/apply-with-outputs.sh" "$PROJECT/tf/apply-with-outputs.sh"
cp "$REPO_ROOT/tf/apply-plan.sh" "$PROJECT/tf/apply-plan.sh"

# --- Mock binaries ---
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"

CMD_LOG="$WORKDIR/cmd-log.txt"
TF_SHOW_OUTPUT="$WORKDIR/show-output.json"
TF_OUTPUT_JSON="$WORKDIR/output-json.json"
MOCK_APPLY_SH="$WORKDIR/mock-apply.sh"
MOCK_MARS="$WORKDIR/mock-mars.sh"

# Default: no drift, empty outputs
echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"
echo '{"vpc_id": {"value": "vpc-123"}}' > "$TF_OUTPUT_JSON"

# Mock terraform
cat > "$MOCK_BIN/terraform" <<OUTER
#!/usr/bin/env bash
echo "terraform \$*" >> "$CMD_LOG"
if [[ "\$1" == "show" && "\$2" == "-json" ]]; then
  cat "$TF_SHOW_OUTPUT"
elif [[ "\$1" == "output" && "\$2" == "-json" ]]; then
  cat "$TF_OUTPUT_JSON"
elif [[ "\$1" == "init" ]]; then
  : # success
elif [[ "\$1" == "plan" ]]; then
  # Create a fake plan file if -out is specified
  for arg in "\$@"; do
    if [[ "\$arg" == -out=* ]]; then
      touch "\${arg#-out=}"
    fi
  done
elif [[ "\$1" == "apply" ]]; then
  : # success
fi
OUTER
chmod +x "$MOCK_BIN/terraform"

# Mock MARS (for utils.sh — it overrides MARS)
cat > "$MOCK_MARS" <<OUTER
#!/usr/bin/env bash
echo "mars \$*" >> "$CMD_LOG"
OUTER
chmod +x "$MOCK_MARS"

# Mock apply.sh (for simple mode of apply-with-outputs.sh)
cat > "$MOCK_APPLY_SH" <<OUTER
#!/usr/bin/env bash
echo "apply.sh \$*" >> "$CMD_LOG"
OUTER
chmod +x "$MOCK_APPLY_SH"

# Place mock apply.sh where the real script expects it
cp "$MOCK_APPLY_SH" "$PROJECT/tf/apply.sh"

# Mock chmod (the utils.sh tries chmod on MARS)
cat > "$MOCK_BIN/chmod" <<'OUTER'
#!/usr/bin/env bash
# silently succeed
exit 0
OUTER
chmod +x "$MOCK_BIN/chmod"

export PATH="$MOCK_BIN:$PATH"

# --- Helper: run a script in the project context ---
run_script() {
  local script="$1"
  shift
  : > "$CMD_LOG"
  rm -rf "$PROJECT/outputs"
  mkdir -p "$PROJECT/outputs"
  (
    cd "$PROJECT/tf"
    export MARS_PROJECT_ROOT="$PROJECT"
    export MARS="$MOCK_MARS"
    export HOME="$WORKDIR"
    bash "$PROJECT/tf/$script" "$@"
  ) 2>&1
}

# ============================================================
# apply-with-outputs.sh tests
# ============================================================
echo "=== apply-with-outputs.sh ==="

# --- Test 1: Simple mode calls apply.sh and captures outputs ---
echo ""
echo "Test 1: Simple mode delegates to apply.sh..."

# In simple mode, it calls apply.sh then sources utils.sh for terraform output.
# We need the mock apply.sh in place and terraform output to work.
set +e
output="$(run_script apply-with-outputs.sh default 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "simple mode: exit code 0"
else
  fail "simple mode: expected exit 0, got $exit_code. Output: $output"
fi

if grep -q "apply.sh default" "$CMD_LOG"; then
  pass "simple mode: apply.sh called with lifecycle"
else
  fail "simple mode: apply.sh not called"
fi

if grep -q "terraform output -json" "$CMD_LOG"; then
  pass "simple mode: terraform output captured"
else
  fail "simple mode: terraform output not captured"
fi

if [[ -f "$PROJECT/outputs/outputs.json" ]]; then
  pass "simple mode: outputs.json created"
else
  fail "simple mode: outputs.json not created"
fi

if jq -e '.vpc_id.value == "vpc-123"' "$PROJECT/outputs/outputs.json" >/dev/null 2>&1; then
  pass "simple mode: outputs.json has correct content"
else
  fail "simple mode: outputs.json content wrong"
fi

# --- Test 2: Drift-check mode runs terraform directly ---
echo ""
echo "Test 2: Drift-check mode (no drift)..."

echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

set +e
output="$(run_script apply-with-outputs.sh default --check-drift 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "drift-check mode: exit code 0"
else
  fail "drift-check mode: expected exit 0, got $exit_code. Output: $output"
fi

if grep -q "terraform init" "$CMD_LOG"; then
  pass "drift-check mode: terraform init called"
else
  fail "drift-check mode: terraform init not called"
fi

if grep -q "terraform plan" "$CMD_LOG"; then
  pass "drift-check mode: terraform plan called"
else
  fail "drift-check mode: terraform plan not called"
fi

if grep -q "terraform apply" "$CMD_LOG"; then
  pass "drift-check mode: terraform apply called"
else
  fail "drift-check mode: terraform apply not called"
fi

# Verify apply.sh was NOT called in drift-check mode
if grep -q "apply.sh" "$CMD_LOG"; then
  fail "drift-check mode: apply.sh should NOT be called"
else
  pass "drift-check mode: apply.sh not called (correct)"
fi

if jq -e '.vpc_id.value == "vpc-123"' "$PROJECT/outputs/outputs.json" >/dev/null 2>&1; then
  pass "drift-check mode: outputs.json has correct content"
else
  fail "drift-check mode: outputs.json content wrong"
fi

# --- Test 3: Drift-check mode + drift detected → exit 2, apply not called ---
echo ""
echo "Test 3: Drift-check mode with drift..."

echo '{"resource_drift": [{"address": "aws_s3_bucket.test"}]}' > "$TF_SHOW_OUTPUT"

set +e
output="$(run_script apply-with-outputs.sh default --check-drift 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 2 ]]; then
  pass "drift detected: exit code 2"
else
  fail "drift detected: expected exit 2, got $exit_code. Output: $output"
fi

# terraform apply should NOT appear after drift-check exits 2
# The apply line may exist from the plan step, check specifically for "apply -input=false apply.tfplan"
if grep -q "terraform apply -input=false apply.tfplan" "$CMD_LOG"; then
  fail "drift detected: terraform apply should not run"
else
  pass "drift detected: terraform apply not called (correct)"
fi

if [[ -f "$PROJECT/outputs/drift.json" ]]; then
  pass "drift detected: drift.json created"
else
  fail "drift detected: drift.json not created"
fi

# Reset show output
echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

# --- Test 3b: Drift-check + ignore-drift → exit 0, apply proceeds ---
echo ""
echo "Test 3b: Drift-check mode with --ignore-drift..."

echo '{"resource_drift": [{"address": "aws_s3_bucket.test"}]}' > "$TF_SHOW_OUTPUT"

set +e
output="$(run_script apply-with-outputs.sh default --check-drift --ignore-drift 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "ignore-drift: exit code 0"
else
  fail "ignore-drift: expected exit 0, got $exit_code. Output: $output"
fi

if grep -q "terraform apply -input=false apply.tfplan" "$CMD_LOG"; then
  pass "ignore-drift: terraform apply called (drift ignored)"
else
  fail "ignore-drift: terraform apply not called"
fi

# Reset show output
echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

# ============================================================
# apply-plan.sh tests
# ============================================================
echo ""
echo "=== apply-plan.sh ==="

# --- Test 4: Basic apply from plan file ---
echo ""
echo "Test 4: Basic apply from plan file..."

# Create a fake plan file in the workspace
mkdir -p "$PROJECT/tf/default"
echo "fake-plan" > "$PROJECT/tf/default/myplan.tfplan"

set +e
output="$(run_script apply-plan.sh default --plan-file myplan 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "apply-plan basic: exit code 0"
else
  fail "apply-plan basic: expected exit 0, got $exit_code. Output: $output"
fi

if grep -q "terraform init -input=false" "$CMD_LOG"; then
  pass "apply-plan basic: terraform init called"
else
  fail "apply-plan basic: terraform init not called"
fi

if grep -q "terraform apply -input=false myplan.tfplan" "$CMD_LOG"; then
  pass "apply-plan basic: terraform apply with plan file"
else
  fail "apply-plan basic: terraform apply not called with plan file"
fi

if grep -q "terraform output -json" "$CMD_LOG"; then
  pass "apply-plan basic: outputs captured"
else
  fail "apply-plan basic: outputs not captured"
fi

if jq -e '.vpc_id.value == "vpc-123"' "$PROJECT/outputs/outputs.json" >/dev/null 2>&1; then
  pass "apply-plan basic: outputs.json has correct content"
else
  fail "apply-plan basic: outputs.json content wrong"
fi

# --- Test 5: Provider cache cleaned before init ---
echo ""
echo "Test 5: Provider cache cleaned before init..."

# Create fake .terraform/providers dir
mkdir -p "$PROJECT/tf/default/.terraform/providers"
echo "cached" > "$PROJECT/tf/default/.terraform/providers/cached-plugin"

echo "fake-plan" > "$PROJECT/tf/default/myplan.tfplan"

set +e
output="$(run_script apply-plan.sh default --plan-file myplan 2>&1)"
exit_code=$?
set -e

if [[ ! -d "$PROJECT/tf/default/.terraform/providers" ]]; then
  pass "provider cache: .terraform/providers removed"
else
  fail "provider cache: .terraform/providers still exists"
fi

# --- Test 6: With --check-drift calls drift-check before apply ---
echo ""
echo "Test 6: apply-plan with --check-drift..."

echo "fake-plan" > "$PROJECT/tf/default/myplan.tfplan"

set +e
output="$(run_script apply-plan.sh default --plan-file myplan --check-drift 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "apply-plan drift-check: exit code 0"
else
  fail "apply-plan drift-check: expected exit 0, got $exit_code. Output: $output"
fi

# drift-check calls terraform show -json, verify it ran
if grep -q "terraform show -json" "$CMD_LOG"; then
  pass "apply-plan drift-check: drift-check.sh invoked (terraform show called)"
else
  fail "apply-plan drift-check: drift-check.sh not invoked"
fi

# --- Test 7: apply-plan with --check-drift + drift → exit 2 ---
echo ""
echo "Test 7: apply-plan with drift detected..."

echo '{"resource_drift": [{"address": "aws_vpc.main"}]}' > "$TF_SHOW_OUTPUT"
echo "fake-plan" > "$PROJECT/tf/default/myplan.tfplan"

set +e
output="$(run_script apply-plan.sh default --plan-file myplan --check-drift 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 2 ]]; then
  pass "apply-plan drift: exit code 2"
else
  fail "apply-plan drift: expected exit 2, got $exit_code. Output: $output"
fi

# Reset
echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

# --- Test 8: Missing --plan-file flag → exit 1 ---
echo ""
echo "Test 8: apply-plan missing --plan-file..."

set +e
output="$(run_script apply-plan.sh default 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 1 ]]; then
  pass "apply-plan no flag: exit code 1"
else
  fail "apply-plan no flag: expected exit 1, got $exit_code"
fi

# ============================================================
# drift-refresh.sh tests
# ============================================================
echo ""
echo "=== drift-refresh.sh ==="

# --- Test 9: No drift → exit 0 ---
echo ""
echo "Test 9: drift-refresh no drift..."

echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

set +e
output="$(run_script drift-refresh.sh default 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "drift-refresh no drift: exit code 0"
else
  fail "drift-refresh no drift: expected exit 0, got $exit_code. Output: $output"
fi

# --- Test 10: Drift → exit 2, drift.json created ---
echo ""
echo "Test 10: drift-refresh with drift..."

echo '{"resource_drift": [{"address": "aws_iam_role.test"}]}' > "$TF_SHOW_OUTPUT"

set +e
output="$(run_script drift-refresh.sh default 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 2 ]]; then
  pass "drift-refresh drift: exit code 2"
else
  fail "drift-refresh drift: expected exit 2, got $exit_code. Output: $output"
fi

if [[ -f "$PROJECT/outputs/drift.json" ]]; then
  pass "drift-refresh drift: drift.json created"
else
  fail "drift-refresh drift: drift.json not created"
fi

# Reset
echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"

# --- Test 11: Plan uses -refresh-only flag ---
echo ""
echo "Test 11: drift-refresh uses -refresh-only..."

set +e
output="$(run_script drift-refresh.sh default 2>&1)"
exit_code=$?
set -e

if grep -q "terraform plan -refresh-only -out=refresh.tfplan" "$CMD_LOG"; then
  pass "drift-refresh: full plan command correct (-refresh-only -out=refresh.tfplan)"
else
  fail "drift-refresh: plan command arguments wrong"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
