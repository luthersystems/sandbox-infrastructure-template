#!/usr/bin/env bash
set -euo pipefail

# Test that tfDestroy calls tfInit before mars destroy.
# Uses a mock MARS script to log invocations and verify ordering.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
MOCK_LOG="$WORKDIR/mars-calls.log"
MOCK_MARS="$WORKDIR/mock-mars.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create a mock MARS that logs all invocations (log path baked in at creation)
# Also log TF_CLI_ARGS_plan / TF_CLI_ARGS_apply env vars on a second line so
# tests can assert that flags routed through env (instead of direct CLI args
# that the real $MARS wrapper would reject as unknown) were actually set.
cat > "$MOCK_MARS" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOCK_LOG"
echo "TF_CLI_ARGS_plan=\${TF_CLI_ARGS_plan:-}" >> "$MOCK_LOG.env"
echo "TF_CLI_ARGS_apply=\${TF_CLI_ARGS_apply:-}" >> "$MOCK_LOG.env"
EOF
chmod +x "$MOCK_MARS"

# Create a minimal workspace directory that tfSetup expects
STAGE_DIR="$WORKDIR/stage"
mkdir -p "$STAGE_DIR/auto-vars"
mkdir -p "$STAGE_DIR/default"

# Helper: source utils.sh in a subshell, override MARS, run a tf function.
# Note: MARS is overridden *after* sourcing because utils.sh unconditionally
# sets it on line 8. This is the only viable approach given the current design.
run_tf_func() {
  local func="$1"
  local mock="${2:-$MOCK_MARS}"
  : > "$MOCK_LOG"
  : > "$MOCK_LOG.env"
  (
    cd "$STAGE_DIR"
    # Source utils.sh with workspace arg (positional $1 = "default")
    set -- "default"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/tf/utils.sh"
    # Override MARS after sourcing (utils.sh sets MARS to run-with-creds.sh)
    export MARS="$mock"
    "$func"
  )
}

echo "Testing tfDestroy calls init before destroy..."

# --- Test 1: tfDestroy produces init then destroy with correct args ---
run_tf_func tfDestroy

if [[ ! -f "$MOCK_LOG" ]]; then
  fail "tfDestroy: no MARS calls logged"
else
  call_count="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  first_call="$(sed -n '1p' "$MOCK_LOG")"
  second_call="$(sed -n '2p' "$MOCK_LOG")"

  if [[ "$call_count" -eq 2 ]]; then
    pass "tfDestroy: exactly 2 MARS calls"
  else
    fail "tfDestroy: expected 2 MARS calls, got $call_count"
  fi

  if [[ "$first_call" == "default init --reconfigure" ]]; then
    pass "tfDestroy: first call is 'default init --reconfigure'"
  else
    fail "tfDestroy: first call expected 'default init --reconfigure', got: $first_call"
  fi

  if [[ "$second_call" == "default destroy --approve" ]]; then
    pass "tfDestroy: second call is 'default destroy --approve'"
  else
    fail "tfDestroy: second call expected 'default destroy --approve', got: $second_call"
  fi
fi

# --- Test 2: tfInit produces a single init call ---
echo ""
echo "Testing tfInit baseline..."
run_tf_func tfInit

if [[ ! -f "$MOCK_LOG" ]]; then
  fail "tfInit: no MARS calls logged"
else
  call_count="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  first_call="$(sed -n '1p' "$MOCK_LOG")"

  if [[ "$call_count" -eq 1 ]]; then
    pass "tfInit: exactly 1 MARS call"
  else
    fail "tfInit: expected 1 MARS call, got $call_count"
  fi

  if [[ "$first_call" == "default init --reconfigure" ]]; then
    pass "tfInit: call is 'default init --reconfigure'"
  else
    fail "tfInit: expected 'default init --reconfigure', got: $first_call"
  fi
fi

# --- Test 3: tfPlan produces a single plan call (no implicit init) ---
echo ""
echo "Testing tfPlan does not auto-initialize..."
run_tf_func tfPlan

if [[ ! -f "$MOCK_LOG" ]]; then
  fail "tfPlan: no MARS calls logged"
else
  call_count="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  first_call="$(sed -n '1p' "$MOCK_LOG")"

  if [[ "$call_count" -eq 1 ]]; then
    pass "tfPlan: exactly 1 MARS call (no implicit init)"
  else
    fail "tfPlan: expected 1 MARS call, got $call_count"
  fi

  # tfPlan threads `-parallelism=…` through TF_CLI_ARGS_plan (NOT as a
  # direct CLI arg) because the real $MARS wrapper would reject `-p…`
  # as an unknown flag — the mock in this test logs args but doesn't
  # parse, which masked the issue originally. So the MARS call should
  # be the bare `default plan`.
  if [[ "$first_call" == "default plan" ]]; then
    pass "tfPlan: call is 'default plan' (parallelism routed via TF_CLI_ARGS_plan)"
  else
    fail "tfPlan: expected 'default plan', got: $first_call"
  fi

  # Assert TF_CLI_ARGS_plan was set on the env passed to the mock. Without
  # this assertion the test would happily pass even if the env-routing
  # regressed back to a no-op (or back to the direct CLI form).
  expected_env="TF_CLI_ARGS_plan=-parallelism=${TF_PARALLELISM:-20}"
  if grep -q "^${expected_env}$" "$MOCK_LOG.env"; then
    pass "tfPlan: TF_CLI_ARGS_plan='${expected_env#*=}' propagated to MARS env"
  else
    fail "tfPlan: expected env '$expected_env', got:"$'\n'"$(cat "$MOCK_LOG.env")"
  fi
fi

# --- Test 4: tfApply produces a single apply call (no implicit init) ---
echo ""
echo "Testing tfApply does not auto-initialize..."
run_tf_func tfApply

if [[ ! -f "$MOCK_LOG" ]]; then
  fail "tfApply: no MARS calls logged"
else
  call_count="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
  first_call="$(sed -n '1p' "$MOCK_LOG")"

  if [[ "$call_count" -eq 1 ]]; then
    pass "tfApply: exactly 1 MARS call (no implicit init)"
  else
    fail "tfApply: expected 1 MARS call, got $call_count"
  fi

  if [[ "$first_call" == "default apply --approve" ]]; then
    pass "tfApply: call is 'default apply --approve'"
  else
    fail "tfApply: expected 'default apply --approve', got: $first_call"
  fi
fi

# --- Test 5: tfDestroy aborts if tfInit fails (no destroy after init failure) ---
echo ""
echo "Testing tfDestroy aborts when init fails..."

FAIL_MARS="$WORKDIR/fail-mars.sh"
cat > "$FAIL_MARS" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOCK_LOG"
if [[ "\$*" == *"init"* ]]; then exit 1; fi
EOF
chmod +x "$FAIL_MARS"

# Avoid running inside if/||/&& — bash silently disables set -e in those
# contexts, even inside subshells that explicitly re-enable it.
set +e
run_tf_func tfDestroy "$FAIL_MARS" 2>/dev/null
exit_code=$?
set -e

if [[ "$exit_code" -eq 0 ]]; then
  fail "tfDestroy should exit non-zero when init fails"
else
  pass "tfDestroy exits non-zero when init fails"
fi

if grep -q "destroy" "$MOCK_LOG"; then
  fail "destroy was called despite init failure"
else
  pass "destroy was NOT called after init failure"
fi

# --- Test 6: tfDestroy two-step when a removed{} block is present (#2048) ---
echo ""
echo "Testing tfDestroy forgets adopted imports before destroy when removed{} present..."
cat > "$STAGE_DIR/default/imported.tf" <<'TF'
removed {
  from = aws_s3_bucket.adopted
  lifecycle {
    destroy = false
  }
}
TF
run_tf_func tfDestroy
removed_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
c1="$(sed -n '1p' "$MOCK_LOG")"
c2="$(sed -n '2p' "$MOCK_LOG")"
c3="$(sed -n '3p' "$MOCK_LOG")"
if [[ "$removed_calls" -eq 3 ]]; then
  pass "tfDestroy(removed{}): exactly 3 MARS calls"
else
  fail "tfDestroy(removed{}): expected 3 MARS calls, got $removed_calls"$'\n'"$(cat "$MOCK_LOG")"
fi
if [[ "$c1" == "default init --reconfigure" ]]; then
  pass "tfDestroy(removed{}): first call is init"
else
  fail "tfDestroy(removed{}): first call expected init, got: $c1"
fi
if [[ "$c2" == "default apply --forbid-resource-changes" ]]; then
  pass "tfDestroy(removed{}): second call is guarded apply (forget)"
else
  fail "tfDestroy(removed{}): second call expected 'default apply --forbid-resource-changes', got: $c2"
fi
if [[ "$c3" == "default destroy --approve" ]]; then
  pass "tfDestroy(removed{}): third call is destroy"
else
  fail "tfDestroy(removed{}): third call expected destroy, got: $c3"
fi
rm -f "$STAGE_DIR/default/imported.tf"

# --- Test 7: tfDestroy stays single-step for a non-import stack (.tf without removed{}) ---
echo ""
echo "Testing tfDestroy stays single-step when no removed{} block present..."
cat > "$STAGE_DIR/default/main.tf" <<'TF'
resource "aws_s3_bucket" "managed" {
  bucket = "example"
}
TF
run_tf_func tfDestroy
noremoved_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
n1="$(sed -n '1p' "$MOCK_LOG")"
n2="$(sed -n '2p' "$MOCK_LOG")"
if [[ "$noremoved_calls" -eq 2 ]]; then
  pass "tfDestroy(no removed{}): exactly 2 MARS calls (no extra apply)"
else
  fail "tfDestroy(no removed{}): expected 2 MARS calls, got $noremoved_calls"$'\n'"$(cat "$MOCK_LOG")"
fi
if [[ "$n1" == "default init --reconfigure" && "$n2" == "default destroy --approve" ]]; then
  pass "tfDestroy(no removed{}): init then destroy, no apply"
else
  fail "tfDestroy(no removed{}): expected init then destroy, got: $n1 / $n2"
fi
rm -f "$STAGE_DIR/default/main.tf"

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
