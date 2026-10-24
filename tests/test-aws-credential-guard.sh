#!/usr/bin/env bash
set -euo pipefail

# Tests for the AWS customer-credential guard in setupCloudEnv (shell_utils.sh)
# and the access-key wiring of tf/cloud-provision (luthersystems/reliable#2461).
#
# Triggering case: a staging deploy whose customer connected with access keys.
# ui-core wrote aws_access_key_id/aws_secret_access_key into the tfvars, but
# cloud-provision declared neither and its provider only assumes bootstrap_role.
# With bootstrap_role empty, terraform ran as the runner's own IRSA role
# (plt-or-test-argo-role-terraform0) in the platform account.

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
mkdir -p "$PROJECT/tf/auto-vars" "$PROJECT/tf/cloud-provision" "$PROJECT/tf/vm-provision"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"
echo "environment: test" > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml"
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"
echo "aws-tmpl" > "$PROJECT/tf/cloud-provision/providers-aws.tf.tmpl"
echo "aws-tmpl" > "$PROJECT/tf/vm-provision/providers-aws.tf.tmpl"

# Stub preflight: records that it ran and with which role.
PREFLIGHT_LOG="$WORKDIR/preflight.log"
cat > "$PROJECT/tf/aws-preflight.sh" <<EOF
#!/usr/bin/env bash
echo "preflight role=\${1:-}" >> "$PREFLIGHT_LOG"
exit 0
EOF

# run_setup <stage> <tfvars-json>: runs setupCloudEnv in a subshell and
# prints its output followed by "rc=<code>".
run_setup() {
  local stage="$1" vars="$2"
  echo "$vars" > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"
  : > "$PREFLIGHT_LOG"
  (
    cd "$PROJECT/tf/$stage"
    export MARS_PROJECT_ROOT="$PROJECT"
    unset JUMP_ROLE_ARN
    # shellcheck disable=SC1091
    source "$PROJECT/shell_utils.sh"
    rc=0
    setupCloudEnv 2>&1 || rc=$?
    echo "rc=$rc"
  )
}

echo "=== AWS customer-credential guard tests ==="

echo ""
echo "Test 1: cloud-provision with no role and no keys is refused"
out=$(run_setup cloud-provision '{"cloud_provider":"aws","aws_region":"us-east-1"}')
if grep -q "rc=1" <<<"$out"; then pass "setupCloudEnv returns 1"; else fail "setupCloudEnv did not fail: $out"; fi
if grep -q "reliable#2461" <<<"$out"; then pass "error names reliable#2461"; else fail "missing guard message: $out"; fi
if [[ ! -s "$PREFLIGHT_LOG" ]]; then pass "preflight not run"; else fail "preflight ran against the runner identity"; fi

echo ""
echo "Test 2: cloud-provision with access keys only proceeds without the ambient preflight"
out=$(run_setup cloud-provision '{"cloud_provider":"aws","aws_region":"us-east-1","aws_access_key_id":"AKIAEXAMPLE","aws_secret_access_key":"example"}')
if grep -q "rc=0" <<<"$out"; then pass "setupCloudEnv returns 0"; else fail "setupCloudEnv failed: $out"; fi
if grep -q "customer access keys" <<<"$out"; then pass "logs access-key mode"; else fail "missing access-key log: $out"; fi
if [[ ! -s "$PREFLIGHT_LOG" ]]; then pass "ambient preflight skipped"; else fail "preflight ran in access-key mode"; fi
if grep -q "AKIAEXAMPLE\|example\"" <<<"$out"; then fail "credentials echoed"; else pass "credentials not echoed"; fi

echo ""
echo "Test 3: cloud-provision with a bootstrap role runs the preflight against it"
out=$(run_setup cloud-provision '{"cloud_provider":"aws","aws_region":"us-east-1","bootstrap_role":"arn:aws:iam::123456789012:role/bootstrap"}')
if grep -q "rc=0" <<<"$out"; then pass "setupCloudEnv returns 0"; else fail "setupCloudEnv failed: $out"; fi
if grep -q "role=arn:aws:iam::123456789012:role/bootstrap" "$PREFLIGHT_LOG"; then pass "preflight checked the bootstrap role"; else fail "preflight not run with the role"; fi

echo ""
echo "Test 4: other stages are not gated"
out=$(run_setup vm-provision '{"cloud_provider":"aws","aws_region":"us-east-1"}')
if grep -q "rc=0" <<<"$out"; then pass "vm-provision unaffected"; else fail "vm-provision refused: $out"; fi

echo ""
echo "Test 5: cloud-provision declares the access keys and wires them into the provider"
VARS="$REPO_ROOT/tf/cloud-provision/vars.tf"
PROV="$REPO_ROOT/tf/cloud-provision/providers-aws.tf.tmpl"
for v in aws_access_key_id aws_secret_access_key; do
  if grep -q "variable \"$v\"" "$VARS"; then pass "vars.tf declares $v"; else fail "vars.tf missing $v"; fi
done
if grep -q "access_key *= .*var.aws_access_key_id" "$PROV"; then pass "provider sets access_key"; else fail "provider missing access_key"; fi
if grep -q "secret_key *= .*var.aws_secret_access_key" "$PROV"; then pass "provider sets secret_key"; else fail "provider missing secret_key"; fi
if grep -q 'use_access_keys *= .*var.bootstrap_role == ""' "$PROV"; then pass "keys only used without a bootstrap_role"; else fail "keys not gated on an empty bootstrap_role"; fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
