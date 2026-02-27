#!/usr/bin/env bash
set -euo pipefail

# Tests for tf/plan-all.sh.
# Uses mock terraform to verify multi-stage planning and summary aggregation.

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
mkdir -p "$PROJECT/tf/cloud-provision"
mkdir -p "$PROJECT/tf/custom-stack-provision"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"
mkdir -p "$PROJECT/outputs"

cat > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

echo '{"cloud_provider": "aws"}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

# Copy real scripts
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"
cp "$REPO_ROOT/tf/utils.sh" "$PROJECT/tf/utils.sh"
cp "$REPO_ROOT/tf/plan.sh" "$PROJECT/tf/plan.sh"
cp "$REPO_ROOT/tf/plan-all.sh" "$PROJECT/tf/plan-all.sh"

# Create mock run-with-creds.sh (utils.sh sets MARS to this unconditionally)
# MARS is called as: $MARS <workspace> <command> [args...]
# The mock strips the workspace arg and runs terraform.
# For 'plan', it also creates a .tfplan file (like real Mars does).
cat > "$PROJECT/tf/run-with-creds.sh" <<'RUNCREDS'
#!/usr/bin/env bash
shift  # skip workspace arg
cmd="$1"
shift
if [[ "$cmd" == "plan" ]]; then
  touch default.tfplan
  terraform plan "$@"
else
  terraform "$cmd" "$@"
fi
RUNCREDS
chmod +x "$PROJECT/tf/run-with-creds.sh"

# --- Mock binaries ---
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"

CMD_LOG="$WORKDIR/cmd-log.txt"
MOCK_MARS="$WORKDIR/mock-mars.sh"

# Per-stage plan JSON — keyed by stage name
STAGE_PLANS_DIR="$WORKDIR/stage-plans"
mkdir -p "$STAGE_PLANS_DIR"

# Default: no changes for any stage
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/cloud-provision.json"
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/custom-stack-provision.json"

# Mock terraform — returns per-stage plan JSON based on CWD
cat > "$MOCK_BIN/terraform" <<OUTER
#!/usr/bin/env bash
echo "terraform \$*" >> "$CMD_LOG"
# Determine stage from CWD (last component of grandparent when in workspace subdir)
cwd="\$(pwd)"
if [[ "\$1" == "show" && "\$2" == "-json" ]]; then
  # Figure out stage from CWD (append / for matching at end of path)
  stage=""
  for s in cloud-provision custom-stack-provision stage-a stage-b failing-stage; do
    if echo "\$cwd/" | grep -q "/\$s/"; then
      stage="\$s"
      break
    fi
  done
  plan_file="$STAGE_PLANS_DIR/\${stage}.json"
  if [[ -n "\$stage" && -f "\$plan_file" ]]; then
    cat "\$plan_file"
  else
    echo '{"resource_changes": []}'
  fi
elif [[ "\$1" == "init" ]]; then
  : # success
elif [[ "\$1" == "plan" ]]; then
  # Create a fake plan file if -out is specified
  for arg in "\$@"; do
    if [[ "\$arg" == -out=* ]]; then
      touch "\${arg#-out=}"
    fi
  done
  # Check for forced failure
  stage=""
  for s in cloud-provision custom-stack-provision stage-a stage-b failing-stage; do
    if echo "\$cwd/" | grep -q "/\$s/"; then
      stage="\$s"
      break
    fi
  done
  fail_file="$STAGE_PLANS_DIR/\${stage}.fail"
  if [[ -n "\$stage" && -f "\$fail_file" ]]; then
    exit 1
  fi
fi
OUTER
chmod +x "$MOCK_BIN/terraform"

# Mock MARS
cat > "$MOCK_MARS" <<OUTER
#!/usr/bin/env bash
echo "mars \$*" >> "$CMD_LOG"
OUTER
chmod +x "$MOCK_MARS"

# Mock chmod
cat > "$MOCK_BIN/chmod" <<'OUTER'
#!/usr/bin/env bash
exit 0
OUTER
chmod +x "$MOCK_BIN/chmod"

export PATH="$MOCK_BIN:$PATH"

# --- Helper: run plan-all in the project context ---
run_plan_all() {
  : > "$CMD_LOG"
  rm -rf "$PROJECT/outputs"
  mkdir -p "$PROJECT/outputs"
  (
    cd "$PROJECT/tf"
    export MARS_PROJECT_ROOT="$PROJECT"
    export MARS="$MOCK_MARS"
    export HOME="$WORKDIR"
    bash "$PROJECT/tf/plan-all.sh" "$@"
  ) 2>&1
}

# ============================================================
# Test 1: Two stages, no changes → exit 0, plan-summary shows zeros
# ============================================================
echo "Test 1: No changes in any stage..."

echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/cloud-provision.json"
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/custom-stack-provision.json"

set +e
output="$(run_plan_all 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "no changes: exit code 0"
else
  fail "no changes: expected exit 0, got $exit_code. Output: $output"
fi

if [[ -f "$PROJECT/outputs/plan-summary.json" ]]; then
  pass "no changes: plan-summary.json created"
else
  fail "no changes: plan-summary.json not created"
fi

if jq -e '.has_changes == false' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "no changes: has_changes is false"
else
  fail "no changes: has_changes should be false"
fi

if jq -e '.total.add == 0 and .total.change == 0 and .total.destroy == 0' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "no changes: totals are all zero"
else
  fail "no changes: totals should be zero"
fi

# ============================================================
# Test 2: One stage with changes → exit 2, correct counts
# ============================================================
echo ""
echo "Test 2: One stage with changes..."

# cloud-provision: no changes
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/cloud-provision.json"

# custom-stack-provision: 2 creates, 1 update
cat > "$STAGE_PLANS_DIR/custom-stack-provision.json" <<'EOF'
{
  "resource_changes": [
    {"address": "aws_instance.web", "change": {"actions": ["create"]}},
    {"address": "aws_ebs_volume.data", "change": {"actions": ["create"]}},
    {"address": "aws_security_group.web", "change": {"actions": ["update"]}},
    {"address": "aws_vpc.main", "change": {"actions": ["no-op"]}}
  ]
}
EOF

set +e
output="$(run_plan_all 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 2 ]]; then
  pass "changes: exit code 2"
else
  fail "changes: expected exit 2, got $exit_code. Output: $output"
fi

if jq -e '.has_changes == true' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: has_changes is true"
else
  fail "changes: has_changes should be true"
fi

if jq -e '.total.add == 2' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: total add is 2"
else
  fail "changes: total add should be 2, got $(jq '.total.add' "$PROJECT/outputs/plan-summary.json")"
fi

if jq -e '.total.change == 1' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: total change is 1"
else
  fail "changes: total change should be 1, got $(jq '.total.change' "$PROJECT/outputs/plan-summary.json")"
fi

if jq -e '.total.destroy == 0' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: total destroy is 0"
else
  fail "changes: total destroy should be 0"
fi

# Verify per-stage data
if jq -e '.stages["cloud-provision"].has_changes == false' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: cloud-provision has no changes"
else
  fail "changes: cloud-provision should have no changes"
fi

if jq -e '.stages["custom-stack-provision"].add == 2' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "changes: custom-stack-provision add is 2"
else
  fail "changes: custom-stack-provision add should be 2"
fi

# ============================================================
# Test 3: Per-stage tfplan files created
# ============================================================
echo ""
echo "Test 3: Per-stage tfplan files..."

if [[ -f "$PROJECT/outputs/tfplan-cloud-provision.json" ]]; then
  pass "per-stage: tfplan-cloud-provision.json exists"
else
  fail "per-stage: tfplan-cloud-provision.json not created"
fi

if [[ -f "$PROJECT/outputs/tfplan-custom-stack-provision.json" ]]; then
  pass "per-stage: tfplan-custom-stack-provision.json exists"
else
  fail "per-stage: tfplan-custom-stack-provision.json not created"
fi

# Verify old filename is NOT created
if [[ ! -f "$PROJECT/outputs/tfplan.json" ]]; then
  pass "per-stage: tfplan.json NOT created (correct)"
else
  fail "per-stage: tfplan.json should not exist"
fi

# ============================================================
# Test 4: Continue-on-error — first stage fails, second still runs
# ============================================================
echo ""
echo "Test 4: Continue on error..."

# Use custom stages
mkdir -p "$PROJECT/tf/stage-a"
mkdir -p "$PROJECT/tf/stage-b"
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/stage-a.json"
echo '{"resource_changes": [{"address": "aws_s3_bucket.b", "change": {"actions": ["create"]}}]}' > "$STAGE_PLANS_DIR/stage-b.json"

# Make stage-a fail
touch "$STAGE_PLANS_DIR/stage-a.fail"

set +e
output="$(PLAN_STAGES="stage-a stage-b" run_plan_all 2>&1)"
exit_code=$?
set -e

# Should exit 1 (error)
if [[ "$exit_code" -eq 1 ]]; then
  pass "continue-on-error: exit code 1 (error takes precedence)"
else
  fail "continue-on-error: expected exit 1, got $exit_code. Output: $output"
fi

# stage-b should still have its plan file
if [[ -f "$PROJECT/outputs/tfplan-stage-b.json" ]]; then
  pass "continue-on-error: stage-b plan file created"
else
  fail "continue-on-error: stage-b plan file not created"
fi

# Summary should still exist
if [[ -f "$PROJECT/outputs/plan-summary.json" ]]; then
  pass "continue-on-error: plan-summary.json created"
else
  fail "continue-on-error: plan-summary.json not created"
fi

# stage-a should be marked as error in summary
if jq -e '.stages["stage-a"].error == true' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "continue-on-error: stage-a marked as error"
else
  fail "continue-on-error: stage-a should be marked as error"
fi

# stage-b counts should be in totals
if jq -e '.stages["stage-b"].add == 1' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "continue-on-error: stage-b counts present"
else
  fail "continue-on-error: stage-b counts missing"
fi

# Clean up
rm -f "$STAGE_PLANS_DIR/stage-a.fail"

# ============================================================
# Test 5: Custom PLAN_STAGES override
# ============================================================
echo ""
echo "Test 5: Custom PLAN_STAGES..."

echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/stage-a.json"
echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/stage-b.json"

set +e
output="$(PLAN_STAGES="stage-a stage-b" run_plan_all 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  pass "custom stages: exit code 0"
else
  fail "custom stages: expected exit 0, got $exit_code. Output: $output"
fi

if jq -e '.stages | keys | sort == ["stage-a", "stage-b"]' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "custom stages: correct stages in summary"
else
  fail "custom stages: wrong stages in summary. Got: $(jq '.stages | keys' "$PROJECT/outputs/plan-summary.json")"
fi

# ============================================================
# Test 6: Destroy actions counted correctly
# ============================================================
echo ""
echo "Test 6: Destroy actions..."

echo '{"resource_changes": []}' > "$STAGE_PLANS_DIR/cloud-provision.json"
cat > "$STAGE_PLANS_DIR/custom-stack-provision.json" <<'EOF'
{
  "resource_changes": [
    {"address": "aws_instance.old", "change": {"actions": ["delete"]}},
    {"address": "aws_instance.new", "change": {"actions": ["create"]}},
    {"address": "aws_vpc.main", "change": {"actions": ["read"]}}
  ]
}
EOF

set +e
output="$(run_plan_all 2>&1)"
exit_code=$?
set -e

if [[ "$exit_code" -eq 2 ]]; then
  pass "destroy: exit code 2"
else
  fail "destroy: expected exit 2, got $exit_code. Output: $output"
fi

if jq -e '.total.destroy == 1' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "destroy: total destroy is 1"
else
  fail "destroy: total destroy should be 1, got $(jq '.total.destroy' "$PROJECT/outputs/plan-summary.json")"
fi

if jq -e '.total.add == 1' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "destroy: total add is 1"
else
  fail "destroy: total add should be 1"
fi

# read actions should not be counted
if jq -e '.total.change == 0' "$PROJECT/outputs/plan-summary.json" >/dev/null 2>&1; then
  pass "destroy: read actions not counted"
else
  fail "destroy: read actions should not be counted"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
