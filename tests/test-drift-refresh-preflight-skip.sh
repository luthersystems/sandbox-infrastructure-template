#!/usr/bin/env bash
set -uo pipefail

# Regression test for the drift-refresh-path bootstrap-permission preflight skip
# (luthersystems/reliable#2243 review finding — sibling of
# tests/test-destroy-preflight-skip.sh).
#
# drift-refresh.sh is a READ-ONLY drift detector: it runs `terraform plan
# -refresh-only` and never creates / updates / deletes anything. But it calls
# setupCloudEnv DIRECTLY (not via the mars $MARS wrapper), and setupCloudEnv
# fires the fail-fast cloud-provision preflight (setupCloudEnv →
# {aws,gcp}-preflight.sh) whenever the stage-dir basename is "cloud-provision".
# That preflight checks the CREATE permissions the bootstrap APPLY needs
# (s3:CreateBucket, iam:CreateRole, …) — permissions a refresh-only plan does
# NOT need. So a credential that was scoped down post-bootstrap (the #2243
# lockdown scenario) would keep deploying fine yet have its drift VISIBILITY
# blocked by a create-permission check. drift-refresh.sh exports
# SKIP_{AWS,GCP}_BOOTSTRAP_PREFLIGHT=1 to suppress the check on this read-only
# path — mirroring the destroy-path fix in tf/destroy.sh (bc942b1).
#
# This exercises the REAL path end-to-end — drift-refresh.sh → utils.sh →
# setupCloudEnv → the real aws-preflight.sh → drift-check.sh — stubbing ONLY the
# terraform binary (drift-refresh runs terraform directly, not through mars). It
# stages a definitive FAIL-CLOSED verdict via the AWS test seam
# (AWS_PREFLIGHT_TEST_SIMULATE_FILE), so if the skip regressed the refresh would
# be blocked and the test would fail. No aws/terraform binary is really invoked
# (the seam short-circuits the preflight; the terraform stub short-circuits the
# plan), so it runs on a bare CI runner. Test 2 is the scope control: the same
# setupCloudEnv preflight, reached off the drift path via the real $MARS wrapper
# (run-with-creds.sh) with NO skip var, must STILL fail closed — proving the
# skip is scoped to drift-refresh's own process and did not neuter the preflight.

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d /tmp/test-drift-refresh-preflight-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Build a minimal project tree that shell_utils.sh / utils.sh expect. ---
PROOT="$WORKDIR/proj"
mkdir -p "$PROOT/tf/auto-vars" "$PROOT/ansible/inventories/default/group_vars/all"
echo "environment: test" > "$PROOT/ansible/inventories/default/group_vars/all/env.yaml"

cp "$SRC_ROOT/shell_utils.sh" "$PROOT/shell_utils.sh"
for f in utils.sh run-with-creds.sh drift-refresh.sh drift-check.sh aws-preflight.sh gcp-preflight.sh; do
  cp "$SRC_ROOT/tf/$f" "$PROOT/tf/$f"
done
chmod +x "$PROOT/tf/"*.sh

# AWS mode with a bootstrap role configured (drives the aws-preflight role path).
cat > "$PROOT/tf/auto-vars/common.auto.tfvars.json" <<'JSON'
{"cloud_provider":"aws","bootstrap_role":"arn:aws:iam::123456789012:role/insideout-bootstrap","aws_external_id":"ext-abc","aws_region":"us-east-1"}
JSON

# Minimal terraform stand-in for the read-only refresh path (drift-refresh runs
# terraform DIRECTLY, not via mars). init: no-op. plan: create the -out plan
# file. show: emit a no-drift plan JSON so drift-check computes drift_count=0
# and exits 0. Any real invocation is logged.
TFROOT="$WORKDIR/tfbin"
mkdir -p "$TFROOT"
TF_LOG_FILE="$WORKDIR/tf-calls.log"
: > "$TF_LOG_FILE"
cat > "$TFROOT/terraform" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TF_LOG_FILE"
subcmd="\${1:-}"
case "\$subcmd" in
  init) exit 0 ;;
  plan)
    out="refresh.tfplan"
    for arg in "\$@"; do
      case "\$arg" in
        -out=*) out="\${arg#-out=}" ;;
      esac
    done
    : > "\$out"
    exit 0 ;;
  show)
    # No drift, no changes -> drift-check drift_count=0 -> exit 0.
    echo '{"resource_drift":[],"resource_changes":[]}'
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TFROOT/terraform"

# Mock the mars container binary (only used by the Test 2 scope control, which
# drives the real $MARS wrapper). Logs every real invocation.
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
echo "Test 1: drift-refresh.sh cloud-provision is NOT blocked by the preflight"
# ============================================================================
# Run the real drift-refresh.sh from tf/ (so utils.sh's relative workspace cd
# lands in tf/cloud-provision and the basename gate fires). The denied seam
# would fail the preflight closed if it ran — the skip must prevent that, so the
# read-only refresh runs to completion (drift-check reports no drift, exit 0).
out="$(cd "$PROOT/tf" && MARS_PROJECT_ROOT="$PROOT" \
  PATH="$TFROOT:$PATH" \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$DENIED" \
  bash "$PROOT/tf/drift-refresh.sh" cloud-provision 2>&1)"
rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "drift-refresh.sh exits 0 despite the denied bootstrap-permission verdict"
else
  fail "drift-refresh.sh should exit 0 (preflight skipped on the read-only path), got $rc"
  echo "----- output -----"; echo "$out"; echo "------------------"
fi

if grep -q "skipping AWS bootstrap permission preflight" <<<"$out"; then
  pass "the AWS preflight ran and honored SKIP_AWS_BOOTSTRAP_PREFLIGHT=1"
else
  fail "expected the preflight-skip notice (skip may not be wired into drift-refresh.sh)"
  echo "----- output -----"; echo "$out"; echo "------------------"
fi

if grep -qi "AWS BOOTSTRAP PREFLIGHT FAILED" <<<"$out"; then
  fail "drift-refresh was blocked by a fail-closed preflight verdict"
else
  pass "no fail-closed verdict surfaced on the drift-refresh path"
fi

if grep -q "No resource drift detected" <<<"$out"; then
  pass "refresh proceeded past the preflight into drift-check (read-only path completed)"
else
  fail "drift-check never ran — the refresh path did not proceed past the preflight"
  echo "----- output -----"; echo "$out"; echo "------------------"
fi

if grep -q "refresh-only" "$TF_LOG_FILE"; then
  pass "terraform reached 'plan -refresh-only' (the read-only refresh actually ran)"
else
  fail "terraform never ran the refresh-only plan — refresh was aborted"
  echo "----- terraform calls -----"; cat "$TF_LOG_FILE"; echo "---------------------------"
fi

# ============================================================================
echo ""
echo "Test 2: scope control — the guard STILL fails closed off the drift path"
# ============================================================================
# Invoke the real $MARS wrapper (run-with-creds.sh) directly from a
# cloud-provision-named workspace dir with the SAME denied seam and NO skip
# var. This reaches the SAME setupCloudEnv preflight off the drift path — it
# must still fail closed, proving drift-refresh's skip is scoped to its own
# process and did not neuter the preflight for real applies.
WS="$PROOT/tf/cloud-provision"
mkdir -p "$WS"
: > "$MARS_LOG"
out2="$(cd "$WS" && MARS_PROJECT_ROOT="$PROOT" \
  MARS_CONTAINER_ROOT="$MARSROOT" \
  AWS_PREFLIGHT_TEST_SIMULATE_FILE="$DENIED" \
  bash "$PROOT/tf/run-with-creds.sh" default init 2>&1)"
rc2=$?

if [[ "$rc2" -ne 0 ]]; then
  pass "run-with-creds.sh (off-drift-path proxy) fails closed on the denied verdict (exit $rc2)"
else
  fail "guard did NOT fire off the drift path — preflight may be globally disabled"
  echo "----- output -----"; echo "$out2"; echo "------------------"
fi

if grep -qi "AWS BOOTSTRAP PREFLIGHT FAILED" <<<"$out2"; then
  pass "fail-closed verdict surfaced for the non-drift invocation"
else
  fail "expected the fail-closed verdict for the non-drift invocation"
  echo "----- output -----"; echo "$out2"; echo "------------------"
fi

if [[ ! -s "$MARS_LOG" ]]; then
  pass "mars was NOT invoked (blocked before exec, as intended)"
else
  fail "mars was invoked despite the denied verdict off the drift path"
  echo "----- mars calls -----"; cat "$MARS_LOG"; echo "----------------------"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
