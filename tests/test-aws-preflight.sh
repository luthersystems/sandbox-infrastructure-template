#!/usr/bin/env bash
set -uo pipefail

# Unit tests for tf/aws-preflight.sh — the fail-fast AWS bootstrap-permission
# preflight (luthersystems/reliable#2243). Twin of tests/test-gcp-preflight.sh.
#
# Exercises the assume-role classification + simulate comparison / exit-code
# logic via the AWS_PREFLIGHT_TEST_* seams (no real AWS access, no
# credentials). Follows the pass/fail counter pattern of the GCP test.

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$SCRIPT_DIR/tf/aws-preflight.sh"

WORKDIR="$(mktemp -d /tmp/test-aws-preflight-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# A representative customer bootstrap role ARN to simulate against (role mode).
ROLE="arn:aws:iam::123456789012:role/insideout-bootstrap"

# Full required set — must stay in sync with REQUIRED_ACTIONS in the script AND
# with reliable bootstrap_permissions.go::bootstrapAWSIAMActions() (drift guard
# below cross-checks the script against this literal).
ALL_ACTIONS='["iam:AttachRolePolicy","iam:CreatePolicy","iam:CreatePolicyVersion","iam:CreateRole","iam:GetRole","iam:PassRole","iam:PutRolePolicy","iam:TagPolicy","iam:TagRole","kms:CreateAlias","kms:CreateKey","kms:DescribeKey","kms:PutKeyPolicy","kms:TagResource","s3:CreateBucket","s3:GetBucketVersioning","s3:PutBucketPolicy","s3:PutBucketPublicAccessBlock","s3:PutBucketVersioning","s3:PutEncryptionConfiguration","sts:AssumeRole","sts:GetCallerIdentity"]'

# simulate_response <jq-decision-expr> — emit an `aws iam simulate-principal-policy`
# shaped JSON where each required action's EvalDecision is computed by the jq
# expression (with `.` bound to the action name).
simulate_response() {
  jq -c "{EvaluationResults: [ .[] | {EvalActionName: ., EvalDecision: ($1)} ]}" <<<"$ALL_ACTIONS"
}

# run_preflight <expected_exit> <label> <role-arg> -- [extra env assignments...]
# writes combined output to $OUT and asserts the exit code. Runs under
# `set -uo pipefail` (no -e), so a non-zero preflight exit does not abort the
# harness — we capture $? explicitly.
OUT=""
run_preflight() {
  local expected="$1" label="$2" role_arg="$3"
  shift 3
  OUT="$(env "$@" bash "$PREFLIGHT" "$role_arg" 2>&1)"
  local rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass "$label (exit $rc)"
  else
    fail "$label (expected exit $expected, got $rc)"
    echo "----- output -----"; echo "$OUT"; echo "------------------"
  fi
}

echo "Test 1: all actions allowed (role mode) -> PASS (exit 0)"
resp_all="$WORKDIR/resp_all.json"
simulate_response '"allowed"' > "$resp_all"
run_preflight 0 "all actions allowed" "$ROLE" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_all"

echo ""
echo "Test 2: create actions denied -> FAIL CLOSED (exit 1)"
resp_denied="$WORKDIR/resp_denied.json"
# Everything allowed EXCEPT the two representative create actions.
simulate_response 'if (. == "s3:CreateBucket" or . == "iam:CreateRole") then "implicitDeny" else "allowed" end' > "$resp_denied"
run_preflight 1 "denied create actions fail closed" "$ROLE" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_denied"
if grep -q "s3:CreateBucket" <<<"$OUT" && grep -q "iam:CreateRole" <<<"$OUT"; then
  pass "error names both denied create actions"
else
  fail "error should name s3:CreateBucket and iam:CreateRole"
fi
if grep -q "AdministratorAccess" <<<"$OUT" && grep -q "reliable#2243" <<<"$OUT"; then
  pass "error includes remediation (AdministratorAccess) + issue ref"
else
  fail "error should mention AdministratorAccess and reliable#2243"
fi

echo ""
echo "Test 3: empty allowed list -> FAIL CLOSED, all 22 missing (exit 1)"
resp_empty="$WORKDIR/resp_empty.json"
echo '{"EvaluationResults": []}' > "$resp_empty"
run_preflight 1 "zero allowed fails closed" "$ROLE" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_empty"
missing_lines="$(grep -c '^\[aws-preflight\]   - ' <<<"$OUT")"
if [[ "$missing_lines" -eq 22 ]]; then
  pass "lists all 22 missing actions"
else
  fail "expected 22 missing action lines, got $missing_lines"
fi

echo ""
echo "Test 4: simulate call errors -> FAIL OPEN (exit 0)"
run_preflight 0 "simulate error fails open" "$ROLE" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_all" "AWS_PREFLIGHT_TEST_SIMULATE_RC=255"
if grep -qi "WARNING" <<<"$OUT" && grep -qi "SimulatePrincipalPolicy call failed" <<<"$OUT"; then
  pass "fail-open logs a warning naming the simulate failure"
else
  fail "fail-open should warn about the simulate failure"
fi

echo ""
echo "Test 5: assume-role AccessDenied -> FAIL CLOSED, distinct message (exit 1)"
run_preflight 1 "assume AccessDenied fails closed" "$ROLE" \
  "AWS_PREFLIGHT_TEST_ASSUME_RC=255" \
  "AWS_PREFLIGHT_TEST_ASSUME_ERR=An error occurred (AccessDenied) when calling the AssumeRole operation: User is not authorized to perform: sts:AssumeRole on resource"
if grep -q "could not assume bootstrap role" <<<"$OUT" && grep -q "TRUST-POLICY" <<<"$OUT"; then
  pass "distinct trust-policy/external-id message (not a missing-permission block)"
else
  fail "assume-denied should print the distinct trust-policy/external-id message"
fi
# It must NOT be misreported as a missing-action verdict.
if grep -q "missing .* required IAM action" <<<"$OUT"; then
  fail "assume-denied must not be reported as a missing-action verdict"
else
  pass "assume-denied not conflated with the missing-action verdict"
fi

echo ""
echo "Test 6: assume-role transient failure -> FAIL OPEN (exit 0)"
run_preflight 0 "assume transient fails open" "$ROLE" \
  "AWS_PREFLIGHT_TEST_ASSUME_RC=255" \
  "AWS_PREFLIGHT_TEST_ASSUME_ERR=Throttling: Rate exceeded"
if grep -qi "WARNING" <<<"$OUT" && grep -qi "transient" <<<"$OUT"; then
  pass "transient assume failure warns and continues"
else
  fail "transient assume failure should fail open with a warning"
fi

echo ""
echo "Test 7: ambient-caller mode (empty bootstrap role) -> PASS (exit 0)"
# Empty role arg drives the ambient-identity branch; the simulate seam still
# supplies the verdict, so all-allowed passes.
run_preflight 0 "ambient mode all allowed" "" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_all"

echo ""
echo "Test 8: SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 -> SKIP (exit 0)"
run_preflight 0 "skip switch honored" "$ROLE" \
  "SKIP_AWS_BOOTSTRAP_PREFLIGHT=1" "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_empty"
if grep -q "skipping AWS bootstrap permission preflight" <<<"$OUT"; then
  pass "skip switch logs a notice"
else
  fail "skip switch should log a notice"
fi

echo ""
echo "Test 9: unparseable simulate body -> FAIL OPEN (exit 0)"
resp_garbage="$WORKDIR/resp_garbage.json"
echo 'not-json-at-all' > "$resp_garbage"
run_preflight 0 "unparseable body fails open" "$ROLE" \
  "AWS_PREFLIGHT_TEST_SIMULATE_FILE=$resp_garbage"

echo ""
echo "Test 10: required list in script matches the golden set (drift guard)"
# Cheap cross-check that the script's REQUIRED_ACTIONS array has not drifted
# from the mirrored reliable bootstrapAWSIAMActions() set. Extract only
# whole-line array entries (indented service:Action token on its own line) so
# comment fragments cannot pollute the set.
script_actions="$(grep -E '^[[:space:]]+(iam|kms|s3|sts):[A-Za-z]+$' "$PREFLIGHT" \
  | sed 's/^[[:space:]]*//' \
  | sort -u)"
golden_actions="$(jq -r '.[]' <<<"$ALL_ACTIONS" | sort -u)"
if [[ "$script_actions" == "$golden_actions" ]]; then
  pass "REQUIRED_ACTIONS matches the 22-action golden set"
else
  fail "REQUIRED_ACTIONS drifted from golden set"
  echo "--- script ---"; echo "$script_actions"
  echo "--- golden ---"; echo "$golden_actions"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
