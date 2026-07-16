#!/usr/bin/env bash
set -uo pipefail

# Unit tests for tf/gcp-preflight.sh — the fail-fast GCP bootstrap-permission
# preflight (luthersystems/reliable#2243).
#
# Exercises the comparison / exit-code logic via the GCP_PREFLIGHT_TEST_*
# seams (no real GCP access, no credentials). Follows the pass/fail counter
# pattern of tests/test-external-id.sh.

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="$SCRIPT_DIR/tf/gcp-preflight.sh"

WORKDIR="$(mktemp -d /tmp/test-gcp-preflight-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# Full required set — must stay in sync with REQUIRED_PERMISSIONS in the script.
ALL_PERMS='["iam.roles.create","iam.roles.update","iam.serviceAccounts.create","iam.serviceAccounts.get","iam.serviceAccounts.getIamPolicy","iam.serviceAccounts.setIamPolicy","resourcemanager.projects.get","resourcemanager.projects.getIamPolicy","resourcemanager.projects.setIamPolicy","storage.buckets.create","storage.buckets.get","storage.buckets.update"]'

# run_preflight <expected_exit> <label> [extra env assignments...] -- writes the
# combined output to $OUT and asserts the exit code.
# NOTE: this test runs under `set -uo pipefail` (no -e), so a non-zero exit
# from the preflight does not abort the harness — we capture $? explicitly.
OUT=""
run_preflight() {
  local expected="$1" label="$2"
  shift 2
  OUT="$(env "$@" bash "$PREFLIGHT" test-project-123 2>&1)"
  local rc=$?
  if [[ "$rc" -eq "$expected" ]]; then
    pass "$label (exit $rc)"
  else
    fail "$label (expected exit $expected, got $rc)"
    echo "----- output -----"; echo "$OUT"; echo "------------------"
  fi
}

echo "Test 1: all permissions present -> PASS (exit 0)"
resp_all="$WORKDIR/resp_all.json"
echo "{\"permissions\": $ALL_PERMS}" > "$resp_all"
run_preflight 0 "all perms granted" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_all" "GCP_PREFLIGHT_TEST_HTTP_CODE=200"

echo ""
echo "Test 2: missing the two #2243 create perms -> FAIL CLOSED (exit 1)"
resp_partial="$WORKDIR/resp_partial.json"
# Everything EXCEPT storage.buckets.create and iam.serviceAccounts.create.
echo '{"permissions": ["iam.roles.create","iam.roles.update","iam.serviceAccounts.get","iam.serviceAccounts.getIamPolicy","iam.serviceAccounts.setIamPolicy","resourcemanager.projects.get","resourcemanager.projects.getIamPolicy","resourcemanager.projects.setIamPolicy","storage.buckets.get","storage.buckets.update"]}' > "$resp_partial"
run_preflight 1 "missing create perms fails closed" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_partial" "GCP_PREFLIGHT_TEST_HTTP_CODE=200"
if grep -q "storage.buckets.create" <<<"$OUT" && grep -q "iam.serviceAccounts.create" <<<"$OUT"; then
  pass "error names both missing #2243 permissions"
else
  fail "error should name storage.buckets.create and iam.serviceAccounts.create"
fi
if grep -q "roles/owner" <<<"$OUT" && grep -q "reliable#2243" <<<"$OUT"; then
  pass "error includes remediation (roles/owner) + issue ref"
else
  fail "error should mention roles/owner and reliable#2243"
fi

echo ""
echo "Test 3: empty granted list -> FAIL CLOSED, all 12 missing (exit 1)"
resp_empty="$WORKDIR/resp_empty.json"
echo '{"permissions": []}' > "$resp_empty"
run_preflight 1 "zero perms fails closed" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_empty" "GCP_PREFLIGHT_TEST_HTTP_CODE=200"
if [[ "$(grep -c '^\[gcp-preflight\]   - ' <<<"$OUT")" -eq 12 ]]; then
  pass "lists all 12 missing permissions"
else
  fail "expected 12 missing permission lines, got $(grep -c '^\[gcp-preflight\]   - ' <<<"$OUT")"
fi

echo ""
echo "Test 4: HTTP 500 -> FAIL OPEN (exit 0)"
run_preflight 0 "HTTP 500 fails open" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_empty" "GCP_PREFLIGHT_TEST_HTTP_CODE=500"
if grep -qi "WARNING" <<<"$OUT" && grep -q "HTTP 500" <<<"$OUT"; then
  pass "fail-open logs a warning naming the HTTP status"
else
  fail "fail-open should warn and name HTTP 500"
fi

echo ""
echo "Test 5: HTTP 403 -> FAIL OPEN (not a definitive verdict) (exit 0)"
run_preflight 0 "HTTP 403 fails open" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_all" "GCP_PREFLIGHT_TEST_HTTP_CODE=403"

echo ""
echo "Test 6: unparseable 200 body -> FAIL OPEN (exit 0)"
resp_garbage="$WORKDIR/resp_garbage.json"
echo 'not-json-at-all' > "$resp_garbage"
run_preflight 0 "unparseable 200 fails open" \
  "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_garbage" "GCP_PREFLIGHT_TEST_HTTP_CODE=200"

echo ""
echo "Test 7: SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 -> SKIP (exit 0)"
run_preflight 0 "skip switch honored" \
  "SKIP_GCP_BOOTSTRAP_PREFLIGHT=1" "GCP_PREFLIGHT_TEST_RESPONSE_FILE=$resp_empty" "GCP_PREFLIGHT_TEST_HTTP_CODE=200"
if grep -q "skipping GCP bootstrap permission preflight" <<<"$OUT"; then
  pass "skip switch logs a notice"
else
  fail "skip switch should log a notice"
fi

echo ""
echo "Test 8: no project id + no test seam -> FAIL OPEN (exit 0)"
set +e
OUT="$(env -u GOOGLE_PROJECT -u GCP_PROJECT_ID -u GOOGLE_APPLICATION_CREDENTIALS bash "$PREFLIGHT" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "missing project id fails open (exit 0)"
else
  fail "missing project id should fail open (got exit $rc)"
fi

echo ""
echo "Test 9: required list in script matches the golden set (drift guard)"
# Cheap cross-check that the script's REQUIRED_PERMISSIONS array has not
# drifted from the mirrored reliable bootstrapGCPIAMPermissions() set. Extract
# only whole-line array entries (indented token on its own line) so comment
# fragments like "storage.buckets.{create,get,update}" cannot pollute the set.
script_perms="$(grep -E '^[[:space:]]+(iam\.roles|iam\.serviceAccounts|resourcemanager\.projects|storage\.buckets)\.[a-zA-Z]+$' "$PREFLIGHT" \
  | sed 's/^[[:space:]]*//' \
  | sort -u)"
golden_perms="$(jq -r '.[]' <<<"$ALL_PERMS" | sort -u)"
if [[ "$script_perms" == "$golden_perms" ]]; then
  pass "REQUIRED_PERMISSIONS matches the 12-permission golden set"
else
  fail "REQUIRED_PERMISSIONS drifted from golden set"
  echo "--- script ---"; echo "$script_perms"
  echo "--- golden ---"; echo "$golden_perms"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
