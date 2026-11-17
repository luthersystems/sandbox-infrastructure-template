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
#
# Capability probes (--help) are answered but NOT logged — tfDestroy probes
# `apply --help` for --forbid-resource-changes support (#2048), and the probe
# is not an action. This default mock emulates an OLD mars image: its help
# output does NOT mention the flag.
cat > "$MOCK_MARS" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"--help"* ]]; then
  echo "Usage: mars <env> apply [flags]"
  exit 0
fi
echo "\$*" >> "$MOCK_LOG"
echo "TF_CLI_ARGS_plan=\${TF_CLI_ARGS_plan:-}" >> "$MOCK_LOG.env"
echo "TF_CLI_ARGS_apply=\${TF_CLI_ARGS_apply:-}" >> "$MOCK_LOG.env"
EOF
chmod +x "$MOCK_MARS"

# A NEW-mars mock: identical, but its `--help` advertises
# --forbid-resource-changes so tfDestroy's capability probe succeeds (#2048).
NEW_MARS="$WORKDIR/new-mars.sh"
cat > "$NEW_MARS" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"--help"* ]]; then
  echo "Flags:"
  echo "      --forbid-resource-changes    Fail if the plan would create, update, or delete any resource."
  exit 0
fi
echo "\$*" >> "$MOCK_LOG"
echo "TF_CLI_ARGS_plan=\${TF_CLI_ARGS_plan:-}" >> "$MOCK_LOG.env"
echo "TF_CLI_ARGS_apply=\${TF_CLI_ARGS_apply:-}" >> "$MOCK_LOG.env"
EOF
chmod +x "$NEW_MARS"

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
  local funcarg="${3:-}"
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
    if [[ -n "$funcarg" ]]; then
      "$func" "$funcarg"
    else
      "$func"
    fi
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

# --- Test 6: tfDestroy gate executes forgets when removed{} present (new mars, #2048) ---
echo ""
echo "Testing tfDestroy(new mars) forgets adopted imports via guarded apply before destroy..."
cat > "$STAGE_DIR/default/imported.tf" <<'TF'
removed {
  from = aws_s3_bucket.adopted
  lifecycle {
    destroy = false
  }
}
TF
run_tf_func tfDestroy "$NEW_MARS"
removed_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
c1="$(sed -n '1p' "$MOCK_LOG")"
c2="$(sed -n '2p' "$MOCK_LOG")"
c3="$(sed -n '3p' "$MOCK_LOG")"
if [[ "$removed_calls" -eq 3 ]]; then
  pass "tfDestroy(new mars, removed{}): exactly 3 MARS calls"
else
  fail "tfDestroy(new mars, removed{}): expected 3 MARS calls, got $removed_calls"$'\n'"$(cat "$MOCK_LOG")"
fi
if [[ "$c1" == "default init --reconfigure" ]]; then
  pass "tfDestroy(new mars, removed{}): first call is init"
else
  fail "tfDestroy(new mars, removed{}): first call expected init, got: $c1"
fi
if [[ "$c2" == "default apply --forbid-resource-changes" ]]; then
  pass "tfDestroy(new mars, removed{}): second call is guarded apply (forget)"
else
  fail "tfDestroy(new mars, removed{}): second call expected 'default apply --forbid-resource-changes', got: $c2"
fi
if [[ "$c3" == "default destroy --approve" ]]; then
  pass "tfDestroy(new mars, removed{}): third call is destroy"
else
  fail "tfDestroy(new mars, removed{}): third call expected destroy, got: $c3"
fi
rm -f "$STAGE_DIR/default/imported.tf"

# --- Test 7: always-on convergence gate for a non-import stack (new mars, #2048) ---
echo ""
echo "Testing tfDestroy(new mars) runs the convergence gate even without removed{}..."
cat > "$STAGE_DIR/default/main.tf" <<'TF'
resource "aws_s3_bucket" "managed" {
  bucket = "example"
}
TF
run_tf_func tfDestroy "$NEW_MARS"
gate_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
g1="$(sed -n '1p' "$MOCK_LOG")"
g2="$(sed -n '2p' "$MOCK_LOG")"
g3="$(sed -n '3p' "$MOCK_LOG")"
if [[ "$gate_calls" -eq 3 ]]; then
  pass "tfDestroy(new mars, no removed{}): exactly 3 MARS calls (always-on gate)"
else
  fail "tfDestroy(new mars, no removed{}): expected 3 MARS calls, got $gate_calls"$'\n'"$(cat "$MOCK_LOG")"
fi
if [[ "$g1" == "default init --reconfigure" && "$g2" == "default apply --forbid-resource-changes" && "$g3" == "default destroy --approve" ]]; then
  pass "tfDestroy(new mars, no removed{}): init -> guarded apply -> destroy"
else
  fail "tfDestroy(new mars, no removed{}): expected init/guarded-apply/destroy, got: $g1 / $g2 / $g3"
fi

# --- Test 8: --ignore-drift skips the gate for a non-import stack (#2048) ---
echo ""
echo "Testing tfDestroy --ignore-drift skips the gate when no removed{}..."
run_tf_func tfDestroy "$NEW_MARS" --ignore-drift
skip_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
s1="$(sed -n '1p' "$MOCK_LOG")"
s2="$(sed -n '2p' "$MOCK_LOG")"
if [[ "$skip_calls" -eq 2 && "$s1" == "default init --reconfigure" && "$s2" == "default destroy --approve" ]]; then
  pass "tfDestroy(--ignore-drift, no removed{}): plain init -> destroy (gate skipped)"
else
  fail "tfDestroy(--ignore-drift, no removed{}): expected init -> destroy, got ($skip_calls):"$'\n'"$(cat "$MOCK_LOG")"
fi
rm -f "$STAGE_DIR/default/main.tf"

# --- Test 9: --ignore-drift still executes forgets (unguarded) when removed{} present (#2048) ---
echo ""
echo "Testing tfDestroy --ignore-drift still applies forgets (unguarded) when removed{} present..."
cat > "$STAGE_DIR/default/imported.tf" <<'TF'
removed {
  from = aws_s3_bucket.adopted
  lifecycle {
    destroy = false
  }
}
TF
run_tf_func tfDestroy "$NEW_MARS" --ignore-drift
ov_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
o1="$(sed -n '1p' "$MOCK_LOG")"
o2="$(sed -n '2p' "$MOCK_LOG")"
o3="$(sed -n '3p' "$MOCK_LOG")"
if [[ "$ov_calls" -eq 3 && "$o2" == "default apply --approve" ]]; then
  pass "tfDestroy(--ignore-drift, removed{}): forgets applied UNGUARDED (apply --approve), never skipped"
else
  fail "tfDestroy(--ignore-drift, removed{}): expected init -> 'default apply --approve' -> destroy, got ($ov_calls): $o1 / $o2 / $o3"
fi
if [[ "$o3" == "default destroy --approve" ]]; then
  pass "tfDestroy(--ignore-drift, removed{}): destroy still runs after forget-apply"
else
  fail "tfDestroy(--ignore-drift, removed{}): third call expected destroy, got: $o3"
fi

# --- Test 10: old mars + removed{} fails closed (no destroy) (#2048) ---
echo ""
echo "Testing tfDestroy fails closed on old mars when removed{} present..."
set +e
run_tf_func tfDestroy "$MOCK_MARS" 2>/dev/null
old_mars_exit=$?
set -e
if [[ "$old_mars_exit" -ne 0 ]]; then
  pass "tfDestroy(old mars, removed{}): exits non-zero (fail closed)"
else
  fail "tfDestroy(old mars, removed{}): should fail when guard unsupported and removed{} present"
fi
if grep -q "destroy" "$MOCK_LOG"; then
  fail "tfDestroy(old mars, removed{}): destroy must NOT run without the guard"
else
  pass "tfDestroy(old mars, removed{}): destroy was NOT called"
fi
rm -f "$STAGE_DIR/default/imported.tf"

# --- Test 11: old mars + no removed{} keeps legacy destroy (warn, no gate) (#2048) ---
echo ""
echo "Testing tfDestroy keeps legacy behavior on old mars without removed{}..."
run_tf_func tfDestroy
legacy_calls="$(wc -l < "$MOCK_LOG" | tr -d ' ')"
l1="$(sed -n '1p' "$MOCK_LOG")"
l2="$(sed -n '2p' "$MOCK_LOG")"
if [[ "$legacy_calls" -eq 2 && "$l1" == "default init --reconfigure" && "$l2" == "default destroy --approve" ]]; then
  pass "tfDestroy(old mars, no removed{}): legacy init -> destroy (graceful degradation)"
else
  fail "tfDestroy(old mars, no removed{}): expected init -> destroy, got ($legacy_calls):"$'\n'"$(cat "$MOCK_LOG")"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
