#!/usr/bin/env bash
set -uo pipefail

# Regression test for the destroy-path bootstrap-permission preflight skip
# (luthersystems/reliable#2243 review finding).
#
# The fail-fast cloud-provision preflight (setupCloudEnv → {aws,gcp}-preflight.sh)
# fires on EVERY mars invocation, because run-with-creds.sh ($MARS) calls
# setupCloudEnv before exec'ing mars and the gate is scoped by stage-dir
# basename ("cloud-provision"), not by mars subcommand. tfDestroy runs
# `mars init` (+ the convergence-gate probes) BEFORE `mars destroy`, so without
# a scoped skip an under-privileged / later-locked-down credential could no
# longer TEAR DOWN its own orphaned cloud-provision stack — the preflight would
# fail closed and abort the teardown. destroy.sh exports
# SKIP_{AWS,GCP}_BOOTSTRAP_PREFLIGHT=1 to suppress the create-permission check
# on the (delete-only) destroy path.
#
# This exercises the REAL path end-to-end — destroy.sh → utils.sh → the real
# $MARS=run-with-creds.sh → setupCloudEnv → the real aws-preflight.sh — mocking
# ONLY the mars container binary (via MARS_CONTAINER_ROOT). It drives the
# preflight into a definitive FAIL-CLOSED verdict via the AWS test seam
# (AWS_PREFLIGHT_TEST_SIMULATE_FILE), so if the skip regressed the destroy
# would be blocked and the test would fail. No aws/gcloud binary is invoked
# (the seam short-circuits the CLI), so it runs on a bare CI runner. Unlike
# tests/test-tf-destroy-init.sh — which overrides $MARS with a mock AFTER
# sourcing utils.sh and therefore never reaches run-with-creds.sh/setupCloudEnv
# — this test keeps the real credential wrapper in the loop.

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d /tmp/test-destroy-preflight-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Build a minimal project tree that shell_utils.sh / utils.sh expect. ---
PROOT="$WORKDIR/proj"
mkdir -p "$PROOT/tf/auto-vars" "$PROOT/ansible/inventories/default/group_vars/all"
echo "environment: test" > "$PROOT/ansible/inventories/default/group_vars/all/env.yaml"

cp "$SRC_ROOT/shell_utils.sh" "$PROOT/shell_utils.sh"
for f in utils.sh run-with-creds.sh destroy.sh aws-preflight.sh gcp-preflight.sh; do
  cp "$SRC_ROOT/tf/$f" "$PROOT/tf/$f"
done
chmod +x "$PROOT/tf/"*.sh

# AWS mode with a bootstrap role configured (drives the aws-preflight role path).
cat > "$PROOT/tf/auto-vars/common.auto.tfvars.json" <<'JSON'
{"cloud_provider":"aws","bootstrap_role":"arn:aws:iam::123456789012:role/insideout-bootstrap","aws_external_id":"ext-abc","aws_region":"us-east-1"}
JSON

# Mock the mars container binary. Answers `apply --help` (legacy: no
# --forbid-resource-changes advertised) and logs every real invocation.
MARSROOT="$WORKDIR/marsroot"
mkdir -p "$MARSROOT"
MARS_LOG="$WORKDIR/mars-calls.log"
: > "$MARS_LOG"
cat > "$MARSROOT/mars" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"--help"* ]]; then
  echo "Usage: mars <env> apply [flags]"
  exit 0
fi
echo "\$*" >> "$MARS_LOG"
exit 0
EOF
chmod +x "$MARSROOT/mars"

# A denied simulate verdict — if the preflight is NOT skipped it fails closed.
DENIED="$WORKDIR/denied.json"
echo '{"EvaluationResults":[{"EvalActionName":"s3:CreateBucket","EvalDecision":"implicitDeny"}]}' > "$DENIED"

# ============================================================================
echo "Test 1: destroy.sh cloud-provision is NOT blocked by the preflight"
# ============================================================================
# Run the real destroy.sh from tf/ (so `. ./utils.sh` resolves). The denied
# seam would fail the preflight closed if it ran — the skip must prevent that.
out="$(cd "$PROOT/tf" && MARS_PROJECT_ROOT="$PROOT" \
  MARS_CONTAINER_ROOT="$MARSROOT" \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$DENIED" \
  bash "$PROOT/tf/destroy.sh" cloud-provision 2>&1)"
rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "destroy.sh exits 0 despite the denied bootstrap-permission verdict"
else
  fail "destroy.sh should exit 0 (preflight skipped on destroy), got $rc"
  echo "----- output -----"; echo "$out"; echo "------------------"
fi

if grep -q "skipping AWS bootstrap permission preflight" <<<"$out"; then
  pass "the AWS preflight ran and honored SKIP_AWS_BOOTSTRAP_PREFLIGHT=1"
else
  fail "expected the preflight-skip notice (skip may not be wired into destroy.sh)"
  echo "----- output -----"; echo "$out"; echo "------------------"
fi

if grep -qi "AWS BOOTSTRAP PREFLIGHT FAILED" <<<"$out"; then
  fail "destroy was blocked by a fail-closed preflight verdict"
else
  pass "no fail-closed verdict surfaced on the destroy path"
fi

if grep -q "destroy --approve" "$MARS_LOG"; then
  pass "mars reached 'destroy --approve' (teardown proceeded)"
else
  fail "mars never reached destroy — teardown was aborted"
  echo "----- mars calls -----"; cat "$MARS_LOG"; echo "----------------------"
fi

# ============================================================================
echo ""
echo "Test 2: scope control — the guard STILL fails closed off the destroy path"
# ============================================================================
# Invoke the real $MARS wrapper (run-with-creds.sh) directly from a
# cloud-provision-named workspace dir with the SAME denied seam and NO skip
# var. This is exactly what tfInit/tfApply do on the apply path — it must
# still fail closed, proving the skip is scoped to destroy and did not neuter
# the preflight for real applies.
WS="$PROOT/tf/cloud-provision"
mkdir -p "$WS"
: > "$MARS_LOG"
out2="$(cd "$WS" && MARS_PROJECT_ROOT="$PROOT" \
  MARS_CONTAINER_ROOT="$MARSROOT" \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$DENIED" \
  bash "$PROOT/tf/run-with-creds.sh" default init 2>&1)"
rc2=$?

if [[ "$rc2" -ne 0 ]]; then
  pass "run-with-creds.sh (apply-path proxy) fails closed on the denied verdict (exit $rc2)"
else
  fail "guard did NOT fire off the destroy path — preflight may be globally disabled"
  echo "----- output -----"; echo "$out2"; echo "------------------"
fi

if grep -qi "AWS BOOTSTRAP PREFLIGHT FAILED" <<<"$out2"; then
  pass "fail-closed verdict surfaced for the non-destroy invocation"
else
  fail "expected the fail-closed verdict for the non-destroy invocation"
  echo "----- output -----"; echo "$out2"; echo "------------------"
fi

if [[ ! -s "$MARS_LOG" ]]; then
  pass "mars was NOT invoked (blocked before exec, as intended)"
else
  fail "mars was invoked despite the denied verdict off the destroy path"
  echo "----- mars calls -----"; cat "$MARS_LOG"; echo "----------------------"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
