#!/usr/bin/env bash
set -uo pipefail

# Wrapper-level tests for the mars#215 Go-binary swap in tf/gcp-preflight.sh and
# tf/aws-preflight.sh (luthersystems/reliable#2243, final step of the chain).
#
# The scripts are now THIN three-tier wrappers:
#   1. SKIP_*_BOOTSTRAP_PREFLIGHT=1  → skip.
#   2. insideout-preflight on PATH   → delegate to the Go binary.
#   3. binary absent / test seam set → legacy inline shell implementation.
#
# The pre-existing tests/test-{gcp,aws}-preflight.sh suites all set a
# *_PREFLIGHT_TEST_* seam, so they exercise ONLY tier 3 (the legacy classifier) —
# and, running on a CI runner where insideout-preflight is NOT installed, they
# ALSO stand in for the "binary absent → legacy still enforces" fallback. This
# file covers the parts those cannot reach:
#   - tier 2 delegation: a fake `insideout-preflight` stub on PATH receives the
#     right subcommand/args, and its exit code is mapped correctly (0→0, 1→1,
#     and the exit-2 usage-error → fail-open(0) mapping);
#   - tier-precedence: a set test seam beats a present binary (stub NOT called);
#   - the SKIP var beats BOTH a present binary and a denied seam (stub NOT
#     called, legacy classifier NOT run).
#
# Runs under `set -uo pipefail` (no -e) so a non-zero wrapper exit does not abort
# the harness — every case captures $? explicitly. No aws/gcloud/live binary is
# invoked (the stub or the seam short-circuits everything), so it runs on a bare
# runner.

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GCP_PREFLIGHT="$SCRIPT_DIR/tf/gcp-preflight.sh"
AWS_PREFLIGHT="$SCRIPT_DIR/tf/aws-preflight.sh"

WORKDIR="$(mktemp -d /tmp/test-preflight-swap-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- A fake insideout-preflight binary on PATH ----------------------------------
# It records its FULL argv (one line) to $STUB_ARGS_LOG and exits with $STUB_EXIT
# (default 0). Placed in $STUBDIR, which callers prepend to PATH.
STUBDIR="$WORKDIR/bin"
mkdir -p "$STUBDIR"
STUB_ARGS_LOG="$WORKDIR/stub-args.log"
cat > "$STUBDIR/insideout-preflight" <<'EOF'
#!/usr/bin/env bash
: > "${STUB_ARGS_LOG:?}"
echo "$*" >> "$STUB_ARGS_LOG"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUBDIR/insideout-preflight"

# A dummy GCP creds file so --credentials-file is a non-empty, assertable value.
DUMMY_CREDS="$WORKDIR/sa.json"
echo '{"type":"service_account","client_email":"stub@example.iam.gserviceaccount.com"}' > "$DUMMY_CREDS"

ROLE="arn:aws:iam::123456789012:role/insideout-bootstrap"

# reset_stub — truncate the args log before each delegation case.
reset_stub() { : > "$STUB_ARGS_LOG"; }
stub_called() { [[ -s "$STUB_ARGS_LOG" ]]; }
stub_argv()   { cat "$STUB_ARGS_LOG" 2>/dev/null || true; }

# ============================================================================
echo "=== GCP tier-2 delegation ==="
# ============================================================================

echo "Test G1: binary on PATH, no seam -> delegates with the right gcp args (exit 0 passthrough)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" \
  STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=0 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "exit 0 passthrough (binary passed)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
argv="$(stub_argv)"
if stub_called; then pass "the binary was invoked"; else fail "binary was NOT invoked (delegation did not happen)"; fi
[[ "$argv" == gcp\ * ]] && pass "gcp subcommand first" || fail "argv should start with 'gcp': $argv"
grep -q -- "--project-id test-project-123" <<<"$argv" && pass "--project-id forwarded" || fail "missing --project-id: $argv"
grep -q -- "--credentials-file $DUMMY_CREDS" <<<"$argv" && pass "--credentials-file forwarded (GOOGLE_APPLICATION_CREDENTIALS)" || fail "missing --credentials-file: $argv"
# REQUIRED_PERMISSIONS forwarded as a single comma-joined --permissions value,
# including both #2243 create perms.
if grep -qE -- "--permissions [^ ]*storage\.buckets\.create" <<<"$argv" \
  && grep -q "iam.serviceAccounts.create" <<<"$argv" \
  && grep -qE -- "--permissions [^ ]+,[^ ]+" <<<"$argv"; then
  pass "--permissions is a comma-joined list carrying the #2243 create perms"
else
  fail "--permissions list malformed / missing create perms: $argv"
fi

echo ""
echo "Test G2: binary returns 1 -> wrapper fails closed (exit 1 passthrough)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=1 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "exit 1 passthrough (definitive fail-closed)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }

echo ""
echo "Test G3: binary returns 2 (usage error) -> wrapper fails OPEN (exit 0 + warning)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=2 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "exit 2 mapped to fail-open (exit 0)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
if grep -qi "WARNING" <<<"$OUT" && grep -q "exited 2" <<<"$OUT"; then
  pass "exit-2 mapping logs a loud warning naming the code"
else
  fail "exit-2 fail-open should warn and name the exit code: $OUT"
fi

echo ""
echo "Test G4: test seam set -> legacy path wins even with the binary on PATH (stub NOT called)"
# A denied 200 verdict via the seam: legacy classifier must fail closed, and the
# binary must NOT be consulted (seam beats binary — tier precedence).
resp_denied="$WORKDIR/gcp_denied.json"
echo '{"permissions": ["storage.buckets.get"]}' > "$resp_denied"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=0 \
  GCP_PREFLIGHT_TEST_RESPONSE_FILE="$resp_denied" GCP_PREFLIGHT_TEST_HTTP_CODE=200 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "seam-driven legacy verdict fails closed (exit 1)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }
if stub_called; then fail "binary was invoked despite the seam (seam must beat binary)"; else pass "binary NOT invoked (seam beat the binary)"; fi
grep -q "GCP BOOTSTRAP PREFLIGHT FAILED" <<<"$OUT" && pass "legacy fail-closed marker surfaced" || fail "expected the legacy fail-closed marker: $OUT"

echo ""
echo "Test G5: binary absent + denied seam -> legacy fallback still enforces (exit 1)"
# The binary-absent tier: no stub on PATH; the denied seam drives the legacy
# classifier to a fail-closed verdict. (Mirrors tests/test-gcp-preflight.sh
# Test 2 — the fallback path retains its teeth.)
reset_stub
OUT="$(GCP_PREFLIGHT_TEST_RESPONSE_FILE="$resp_denied" GCP_PREFLIGHT_TEST_HTTP_CODE=200 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "binary-absent legacy fallback fails closed (exit 1)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }

echo ""
echo "Test G6: SKIP var beats BOTH a present binary and a denied seam (stub NOT called)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=1 \
  SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 \
  GCP_PREFLIGHT_TEST_RESPONSE_FILE="$resp_denied" GCP_PREFLIGHT_TEST_HTTP_CODE=200 \
  GOOGLE_APPLICATION_CREDENTIALS="$DUMMY_CREDS" \
  bash "$GCP_PREFLIGHT" test-project-123 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "skip wins (exit 0)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
if stub_called; then fail "binary invoked despite SKIP=1"; else pass "binary NOT invoked (skip short-circuits before delegation)"; fi
grep -q "skipping GCP bootstrap permission preflight" <<<"$OUT" && pass "skip notice logged" || fail "expected the skip notice: $OUT"

# ============================================================================
echo ""
echo "=== AWS tier-2 delegation ==="
# ============================================================================

echo "Test A1: role mode, binary on PATH, no seam -> delegates with the right aws args (exit 0)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=0 \
  AWS_EXTERNAL_ID=ext-abc AWS_PREFLIGHT_REGION=us-west-2 \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "exit 0 passthrough (binary passed)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
argv="$(stub_argv)"
if stub_called; then pass "the binary was invoked"; else fail "binary was NOT invoked (delegation did not happen)"; fi
[[ "$argv" == aws\ * ]] && pass "aws subcommand first" || fail "argv should start with 'aws': $argv"
grep -q -- "--role-arn $ROLE" <<<"$argv" && pass "--role-arn forwarded" || fail "missing --role-arn: $argv"
grep -q -- "--external-id ext-abc" <<<"$argv" && pass "--external-id forwarded" || fail "missing --external-id: $argv"
grep -q -- "--region us-west-2" <<<"$argv" && pass "--region forwarded (AWS_PREFLIGHT_REGION)" || fail "missing --region: $argv"
if grep -qE -- "--actions [^ ]*s3:CreateBucket" <<<"$argv" \
  && grep -q "iam:CreateRole" <<<"$argv" \
  && grep -qE -- "--actions [^ ]+,[^ ]+" <<<"$argv"; then
  pass "--actions is a comma-joined list carrying the #2243 create actions"
else
  fail "--actions list malformed / missing create actions: $argv"
fi

echo ""
echo "Test A2: ambient mode (empty role) -> delegates WITHOUT --role-arn/--external-id"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=0 \
  AWS_EXTERNAL_ID=ext-abc AWS_PREFLIGHT_REGION=us-east-1 \
  bash "$AWS_PREFLIGHT" "" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "exit 0 passthrough (ambient mode)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
argv="$(stub_argv)"
[[ "$argv" == aws\ * ]] && pass "aws subcommand first" || fail "argv should start with 'aws': $argv"
if grep -q -- "--role-arn" <<<"$argv"; then fail "ambient mode must NOT pass --role-arn: $argv"; else pass "no --role-arn in ambient mode"; fi
if grep -q -- "--external-id" <<<"$argv"; then fail "ambient mode must NOT pass --external-id: $argv"; else pass "no --external-id in ambient mode (only meaningful with a role)"; fi
grep -q -- "--region us-east-1" <<<"$argv" && pass "--region forwarded in ambient mode" || fail "missing --region: $argv"

echo ""
echo "Test A3: binary returns 1 -> wrapper fails closed (exit 1 passthrough)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=1 \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "exit 1 passthrough (definitive fail-closed)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }

echo ""
echo "Test A4: binary returns 2 (usage error) -> wrapper fails OPEN (exit 0 + warning)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=2 \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "exit 2 mapped to fail-open (exit 0)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
if grep -qi "WARNING" <<<"$OUT" && grep -q "exited 2" <<<"$OUT"; then
  pass "exit-2 mapping logs a loud warning naming the code"
else
  fail "exit-2 fail-open should warn and name the exit code: $OUT"
fi

echo ""
echo "Test A5: test seam set -> legacy path wins even with the binary on PATH (stub NOT called)"
aws_denied="$WORKDIR/aws_denied.json"
echo '{"EvaluationResults":[{"EvalActionName":"s3:CreateBucket","EvalDecision":"implicitDeny"}]}' > "$aws_denied"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=0 \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$aws_denied" \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "seam-driven legacy verdict fails closed (exit 1)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }
if stub_called; then fail "binary was invoked despite the seam (seam must beat binary)"; else pass "binary NOT invoked (seam beat the binary)"; fi
grep -q "AWS BOOTSTRAP PREFLIGHT FAILED" <<<"$OUT" && pass "legacy fail-closed marker surfaced" || fail "expected the legacy fail-closed marker: $OUT"

echo ""
echo "Test A6: binary absent + denied seam -> legacy fallback still enforces (exit 1)"
reset_stub
OUT="$(AWS_PREFLIGHT_TEST_SIMULATE_FILE="$aws_denied" \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 1 ]] && pass "binary-absent legacy fallback fails closed (exit 1)" || { fail "expected exit 1, got $rc"; echo "$OUT"; }

echo ""
echo "Test A7: SKIP var beats BOTH a present binary and a denied seam (stub NOT called)"
reset_stub
OUT="$(PATH="$STUBDIR:$PATH" STUB_ARGS_LOG="$STUB_ARGS_LOG" STUB_EXIT=1 \
  SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$aws_denied" \
  bash "$AWS_PREFLIGHT" "$ROLE" 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && pass "skip wins (exit 0)" || { fail "expected exit 0, got $rc"; echo "$OUT"; }
if stub_called; then fail "binary invoked despite SKIP=1"; else pass "binary NOT invoked (skip short-circuits before delegation)"; fi
grep -q "skipping AWS bootstrap permission preflight" <<<"$OUT" && pass "skip notice logged" || fail "expected the skip notice: $OUT"

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
