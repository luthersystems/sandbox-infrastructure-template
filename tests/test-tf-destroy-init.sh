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
cat > "$MOCK_MARS" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOCK_LOG"
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

  if [[ "$first_call" == "default plan" ]]; then
    pass "tfPlan: call is 'default plan'"
  else
    fail "tfPlan: expected 'default plan', got: $first_call"
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

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
