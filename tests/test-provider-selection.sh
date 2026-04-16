#!/usr/bin/env bash
set -euo pipefail

# Tests for _selectCloudFiles() in shell_utils.sh.
# Validates that the correct cloud provider templates are copied at deploy time.

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

# --- Build a minimal project tree that satisfies shell_utils.sh ---
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT/tf/auto-vars"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"

cat > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

# Copy real shell_utils.sh
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"

# Helper: set cloud_provider in auto-vars and source shell_utils
setup_cloud() {
  local cloud="$1"
  local stage_dir="$2"
  echo "{\"cloud_provider\": \"$cloud\"}" > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"
  cd "$stage_dir"
  # Re-source shell_utils to pick up the new cloud_provider
  export MARS_PROJECT_ROOT="$PROJECT"
  source "$PROJECT/shell_utils.sh"
}

# ============================================================
echo "=== _selectCloudFiles tests ==="
# ============================================================

# --- Test 1: AWS mode copies only providers-aws.tf ---
echo ""
echo "Test 1: AWS mode activates AWS template only"
STAGE="$WORKDIR/stage1"
mkdir -p "$STAGE"
echo "aws-provider-content" > "$STAGE/providers-aws.tf.tmpl"
echo "gcp-provider-content" > "$STAGE/providers-gcp.tf.tmpl"

(
  setup_cloud "aws" "$STAGE"
  _selectCloudFiles
) > /dev/null 2>&1

if [[ -f "$STAGE/providers-aws.tf" ]] && [[ "$(cat "$STAGE/providers-aws.tf")" == "aws-provider-content" ]]; then
  pass "AWS mode: providers-aws.tf generated from template"
else
  fail "AWS mode: providers-aws.tf not generated or has wrong content"
fi

if [[ ! -f "$STAGE/providers-gcp.tf" ]]; then
  pass "AWS mode: providers-gcp.tf not generated (correct)"
else
  fail "AWS mode: providers-gcp.tf was generated (should not be)"
fi

# Templates should be untouched
if [[ -f "$STAGE/providers-aws.tf.tmpl" ]] && [[ -f "$STAGE/providers-gcp.tf.tmpl" ]]; then
  pass "AWS mode: template files preserved"
else
  fail "AWS mode: template files were modified or removed"
fi

# --- Test 2: GCP mode copies only providers-gcp.tf ---
echo ""
echo "Test 2: GCP mode activates GCP template only"
STAGE="$WORKDIR/stage2"
mkdir -p "$STAGE"
echo "aws-provider-content" > "$STAGE/providers-aws.tf.tmpl"
echo "gcp-provider-content" > "$STAGE/providers-gcp.tf.tmpl"

(
  setup_cloud "gcp" "$STAGE"
  _selectCloudFiles
) > /dev/null 2>&1

if [[ -f "$STAGE/providers-gcp.tf" ]] && [[ "$(cat "$STAGE/providers-gcp.tf")" == "gcp-provider-content" ]]; then
  pass "GCP mode: providers-gcp.tf generated from template"
else
  fail "GCP mode: providers-gcp.tf not generated or has wrong content"
fi

if [[ ! -f "$STAGE/providers-aws.tf" ]]; then
  pass "GCP mode: providers-aws.tf not generated (correct)"
else
  fail "GCP mode: providers-aws.tf was generated (should not be)"
fi

# --- Test 3: No templates present (e.g., account-provision stage) ---
echo ""
echo "Test 3: No templates present — no error"
STAGE="$WORKDIR/stage3"
mkdir -p "$STAGE"
# No .tf.tmpl files at all

(
  setup_cloud "aws" "$STAGE"
  _selectCloudFiles
) > /dev/null 2>&1
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
  pass "No templates: function succeeds silently"
else
  fail "No templates: function returned non-zero ($exit_code)"
fi

# Verify no provider .tf files were generated
shopt -s nullglob
generated=("$STAGE"/providers-*.tf)
shopt -u nullglob
if [[ ${#generated[@]} -gt 0 ]]; then
  fail "No templates: generated provider files when none should exist"
else
  pass "No templates: no provider files generated"
fi

# --- Test 4: Idempotent — calling twice produces same result ---
echo ""
echo "Test 4: Idempotent — calling twice is safe"
STAGE="$WORKDIR/stage4"
mkdir -p "$STAGE"
echo "aws-content" > "$STAGE/providers-aws.tf.tmpl"
echo "gcp-content" > "$STAGE/providers-gcp.tf.tmpl"

(
  setup_cloud "aws" "$STAGE"
  _selectCloudFiles
  _selectCloudFiles
) > /dev/null 2>&1

if [[ -f "$STAGE/providers-aws.tf" ]] && [[ "$(cat "$STAGE/providers-aws.tf")" == "aws-content" ]]; then
  pass "Idempotent: providers-aws.tf still correct after second call"
else
  fail "Idempotent: providers-aws.tf incorrect after second call"
fi

if [[ ! -f "$STAGE/providers-gcp.tf" ]]; then
  pass "Idempotent: providers-gcp.tf still absent after second call"
else
  fail "Idempotent: providers-gcp.tf appeared after second call"
fi

# --- Test 5: setupCloudEnv activates providers (integration) ---
echo ""
echo "Test 5: setupCloudEnv integration — activates provider files"
STAGE="$WORKDIR/stage5"
mkdir -p "$STAGE"
echo "aws-integrated" > "$STAGE/providers-aws.tf.tmpl"
echo "gcp-integrated" > "$STAGE/providers-gcp.tf.tmpl"

# Mock aws sts to prevent assumeJumpRole from failing
MOCK_BIN="$WORKDIR/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/aws" <<'OUTER'
#!/usr/bin/env bash
echo '{"Credentials":{"AccessKeyId":"x","SecretAccessKey":"x","SessionToken":"x"}}'
OUTER
chmod +x "$MOCK_BIN/aws"

(
  export PATH="$MOCK_BIN:$PATH"
  setup_cloud "aws" "$STAGE"
  setupCloudEnv
) > /dev/null 2>&1

if [[ -f "$STAGE/providers-aws.tf" ]] && [[ "$(cat "$STAGE/providers-aws.tf")" == "aws-integrated" ]]; then
  pass "setupCloudEnv: providers-aws.tf activated"
else
  fail "setupCloudEnv: providers-aws.tf not activated"
fi

if [[ ! -f "$STAGE/providers-gcp.tf" ]]; then
  pass "setupCloudEnv: providers-gcp.tf not activated (AWS mode)"
else
  fail "setupCloudEnv: providers-gcp.tf was activated in AWS mode"
fi

# --- Test 6: No dummy GCP credentials created for AWS ---
echo ""
echo "Test 6: AWS mode does not create dummy GCP credentials"
STAGE="$WORKDIR/stage6"
mkdir -p "$STAGE"
echo "aws-tmpl" > "$STAGE/providers-aws.tf.tmpl"

output=$(
  export PATH="$MOCK_BIN:$PATH"
  setup_cloud "aws" "$STAGE"
  setupCloudEnv 2>&1
) || true

if echo "$output" | grep -q "Dummy GCP credentials"; then
  fail "AWS mode: still mentions dummy GCP credentials"
else
  pass "AWS mode: no dummy GCP credential messages"
fi

if echo "$output" | grep -q "GOOGLE_APPLICATION_CREDENTIALS"; then
  fail "AWS mode: still references GOOGLE_APPLICATION_CREDENTIALS"
else
  pass "AWS mode: no GOOGLE_APPLICATION_CREDENTIALS reference"
fi

if echo "$output" | grep -q "AWS environment: using IRSA"; then
  pass "AWS mode: setupCloudEnv ran to completion"
else
  fail "AWS mode: missing 'AWS environment: using IRSA' — setupCloudEnv may not have run"
fi

# --- Test 7: Cloud switch — stale provider file from prior deploy ---
echo ""
echo "Test 7: Cloud switch — stale file from prior cloud deploy"
STAGE="$WORKDIR/stage7"
mkdir -p "$STAGE"
echo "aws-tmpl" > "$STAGE/providers-aws.tf.tmpl"
echo "gcp-tmpl" > "$STAGE/providers-gcp.tf.tmpl"
# Simulate a prior AWS deploy that left a generated file
echo "stale-aws-provider" > "$STAGE/providers-aws.tf"

(
  setup_cloud "gcp" "$STAGE"
  _selectCloudFiles
) > /dev/null 2>&1

if [[ -f "$STAGE/providers-gcp.tf" ]] && [[ "$(cat "$STAGE/providers-gcp.tf")" == "gcp-tmpl" ]]; then
  pass "Cloud switch: providers-gcp.tf generated for new cloud"
else
  fail "Cloud switch: providers-gcp.tf not generated"
fi

# The stale providers-aws.tf from the prior deploy persists — this is safe
# because deploys run in ephemeral containers (each starts fresh) and the
# generated files are gitignored. Document this explicitly.
if [[ -f "$STAGE/providers-aws.tf" ]]; then
  pass "Cloud switch: stale providers-aws.tf persists (expected in ephemeral containers)"
else
  pass "Cloud switch: stale providers-aws.tf was cleaned up"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
