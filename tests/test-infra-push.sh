#!/usr/bin/env bash
set -euo pipefail

# Regression tests for issue #143: the applied customer stack was never pushed
# to the <project>-infra GitHub repo, so every infra repo stayed empty even on
# a SUCCESSFUL apply.
#
# Root cause: the commit/push was wired only in tf/apply.sh, but Oracle/ui-core
# drives deploys through tf/apply-with-outputs.sh --check-drift, whose
# drift-check branch ran terraform directly with NO git operations. The push
# helper (gitPushInfra) also silently returned 0 when no infra remote was
# configured, so the gap was invisible.
#
# These tests use a REAL local bare repo as the `infra` remote (file://) so we
# can assert the end-state the bug got wrong: the infra repo goes from empty to
# populated. terraform/mars are mocked so no cloud access is needed.

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

# Deterministic committer identity for the helpers' commits.
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@luthersystems.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@luthersystems.com"

# --- A real bare repo that plays the role of <project>-infra ---------------
INFRA_BARE="$WORKDIR/infra.git"
git init -q --bare -b main "$INFRA_BARE"

bare_object_count() {
  # 0 => empty repo (the issue #143 failure mode), >0 => populated.
  git -C "$INFRA_BARE" rev-list --all --count 2>/dev/null || echo 0
}

# --- Build a fake project tree whose working dir IS a clone of the infra repo
# (mirrors prepare-custom-stack.sh's ensure_git_from_infra state) -----------
make_project() {
  local proj="$1"
  mkdir -p "$proj/tf/auto-vars" "$proj/tf/custom-stack-provision" \
    "$proj/ansible/inventories/default/group_vars/all" "$proj/outputs"
  echo "environment: test" \
    > "$proj/ansible/inventories/default/group_vars/all/env.yaml"

  # auto-vars: the contract that wires the push (written by cloud-provision's
  # repo.tf in production).
  jq -n --arg url "$INFRA_BARE" \
    '{cloud_provider:"aws", repo_clone_ssh_url:$url}' \
    > "$proj/tf/auto-vars/git_repo.auto.tfvars.json"

  cp "$REPO_ROOT/shell_utils.sh" "$proj/shell_utils.sh"
  cp "$REPO_ROOT/tf/utils.sh" "$proj/tf/utils.sh"
  cp "$REPO_ROOT/tf/drift-check.sh" "$proj/tf/drift-check.sh"
  cp "$REPO_ROOT/tf/apply-with-outputs.sh" "$proj/tf/apply-with-outputs.sh"
  cp "$REPO_ROOT/tf/apply.sh" "$proj/tf/apply.sh"

  # Establish .git as a clone of the (empty) infra repo, then add the applied
  # stack content (what terraform would have produced).
  (
    cd "$proj"
    git init -q -b main
    git remote add infra "$INFRA_BARE"
    echo "applied stack" > tf/custom-stack-provision/main.tf
  )
}

# --- Mock binaries (terraform + mars) so apply-with-outputs can run ---------
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"
TF_OUTPUT_JSON="$WORKDIR/output-json.json"
echo '{"vpc_id": {"value": "vpc-123"}}' > "$TF_OUTPUT_JSON"

cat > "$MOCK_BIN/terraform" <<OUTER
#!/usr/bin/env bash
if [[ "\$1" == "output" && "\$2" == "-json" ]]; then
  cat "$TF_OUTPUT_JSON"
elif [[ "\$1" == "show" && "\$2" == "-json" ]]; then
  echo '{"resource_drift": []}'
elif [[ "\$1" == "plan" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == -out=* ]]; then touch "\${arg#-out=}"; fi
  done
fi
# init/apply and all branches: succeed
exit 0
OUTER
chmod +x "$MOCK_BIN/terraform"

cat > "$MOCK_BIN/mars" <<'OUTER'
#!/usr/bin/env bash
exit 0
OUTER
chmod +x "$MOCK_BIN/mars"
export PATH="$MOCK_BIN:$PATH"

# ===========================================================================
echo "=== persistInfra: applied stack is pushed (issue #143) ==="
echo ""
echo "Test 1: persistInfra populates the empty infra repo..."

P1="$WORKDIR/p1"
make_project "$P1"

before="$(bare_object_count)"
if [[ "$before" -eq 0 ]]; then
  pass "precondition: infra repo starts empty (reproduces the bug's start state)"
else
  fail "precondition: infra repo not empty before push (count=$before)"
fi

set +e
out1="$(
  cd "$P1"
  export MARS_PROJECT_ROOT="$P1"
  . "$P1/shell_utils.sh"
  persistInfra custom-stack-provision "test: apply" 2>&1
)"
rc1=$?
set -e

if [[ $rc1 -eq 0 ]]; then
  pass "persistInfra: exit 0 on happy path"
else
  fail "persistInfra: expected exit 0, got $rc1. Output: $out1"
fi

after="$(bare_object_count)"
if [[ "$after" -gt 0 ]]; then
  pass "persistInfra: infra repo is NOW populated (was the issue #143 failure)"
else
  fail "persistInfra: infra repo STILL empty after push (issue #143 not fixed)"
fi

# The pushed commit must carry the applied stack content.
if git -C "$INFRA_BARE" show main:tf/custom-stack-provision/main.tf 2>/dev/null \
   | grep -q "applied stack"; then
  pass "persistInfra: pushed main contains applied stack content"
else
  fail "persistInfra: pushed main does not contain applied stack content"
fi

# ===========================================================================
echo ""
echo "=== apply-with-outputs.sh --check-drift pushes (production path) ==="
echo ""
echo "Test 2: drift-check deploy path populates the infra repo..."

# Fresh bare + project so the count is unambiguous.
rm -rf "$INFRA_BARE"
git init -q --bare -b main "$INFRA_BARE"

P2="$WORKDIR/p2"
make_project "$P2"

set +e
out2="$(
  cd "$P2/tf"
  export MARS_PROJECT_ROOT="$P2"
  export MARS="$MOCK_BIN/mars"
  export HOME="$WORKDIR"
  bash "$P2/tf/apply-with-outputs.sh" custom-stack-provision --check-drift 2>&1
)"
rc2=$?
set -e

if [[ $rc2 -eq 0 ]]; then
  pass "drift-check path: exit 0"
else
  fail "drift-check path: expected exit 0, got $rc2. Output: $out2"
fi

# THE core regression assertion: pre-fix the drift-check branch did zero git
# ops, so this stayed 0 and the test fails. Post-fix persistInfra runs.
if [[ "$(bare_object_count)" -gt 0 ]]; then
  pass "drift-check path: infra repo populated via apply-with-outputs.sh (issue #143)"
else
  fail "drift-check path: infra repo STILL empty after deploy (issue #143 regression)"
fi

if echo "$out2" | grep -q "Pushing to infra"; then
  pass "drift-check path: push path was reached (logged 'Pushing to infra')"
else
  fail "drift-check path: push path NOT reached. Output: $out2"
fi

# ===========================================================================
echo ""
echo "=== Loud-on-failure: no silent skip when remote is unconfigured ==="
echo ""
echo "Test 3: gitPushInfra with INFRA_PUSH_REQUIRED=1 and no remote fails loudly..."

P3="$WORKDIR/p3"
mkdir -p "$P3/tf/auto-vars" "$P3/ansible/inventories/default/group_vars/all"
echo "environment: test" > "$P3/ansible/inventories/default/group_vars/all/env.yaml"
echo '{}' > "$P3/tf/auto-vars/common.auto.tfvars.json"
cp "$REPO_ROOT/shell_utils.sh" "$P3/shell_utils.sh"
( cd "$P3" && git init -q -b main )   # has .git, but NO infra remote

set +e
out3="$(
  cd "$P3"
  export MARS_PROJECT_ROOT="$P3"
  . "$P3/shell_utils.sh"
  INFRA_PUSH_REQUIRED=1 gitPushInfra 2>&1
)"
rc3=$?
set -e

if [[ $rc3 -ne 0 ]]; then
  pass "required push: returns non-zero when no remote (no silent success)"
else
  fail "required push: silently succeeded with no remote (rc=0) — the issue #143 smell"
fi

if echo "$out3" | grep -q "ERROR: gitPushInfra"; then
  pass "required push: emitted a loud ERROR"
else
  fail "required push: no loud ERROR emitted. Output: $out3"
fi

# Default (non-required) callers stay lenient: skip + exit 0.
set +e
out3b="$(
  cd "$P3"
  export MARS_PROJECT_ROOT="$P3"
  . "$P3/shell_utils.sh"
  gitPushInfra 2>&1
)"
rc3b=$?
set -e

if [[ $rc3b -eq 0 ]] && echo "$out3b" | grep -q "Skipping gitPushInfra"; then
  pass "default push: stays lenient (skip + exit 0) for standalone push.sh callers"
else
  fail "default push: expected lenient skip+exit0. rc=$rc3b output=$out3b"
fi

# ===========================================================================
echo ""
echo "Test 4: ensure_infra_remote warns loudly when repo_clone_ssh_url empty..."

set +e
out4="$(
  cd "$P3"
  export MARS_PROJECT_ROOT="$P3"
  . "$P3/shell_utils.sh"
  ensure_infra_remote 2>&1
)"
set -e

if echo "$out4" | grep -q "WARNING: repo_clone_ssh_url is empty"; then
  pass "ensure_infra_remote: emits a loud WARNING when url missing"
else
  fail "ensure_infra_remote: no WARNING when url missing. Output: $out4"
fi

# ===========================================================================
echo ""
echo "Test 5: persistInfra is a benign no-op for a BOOTSTRAP stage with no .git..."

P5="$WORKDIR/p5"   # no .git at all
mkdir -p "$P5/tf/auto-vars" "$P5/ansible/inventories/default/group_vars/all"
echo "environment: test" > "$P5/ansible/inventories/default/group_vars/all/env.yaml"
echo '{}' > "$P5/tf/auto-vars/common.auto.tfvars.json"
cp "$REPO_ROOT/shell_utils.sh" "$P5/shell_utils.sh"

set +e
out5="$(
  cd "$P5"
  export MARS_PROJECT_ROOT="$P5"
  . "$P5/shell_utils.sh"
  persistInfra cloud-provision 2>&1
)"
rc5=$?
set -e

if [[ $rc5 -eq 0 ]] && echo "$out5" | grep -q "WARNING: persistInfra: no .git"; then
  pass "persistInfra: no-.git bootstrap stage warns and exits 0 (doesn't break cloud-provision)"
else
  fail "persistInfra: expected warn + exit 0 for no-.git bootstrap stage. rc=$rc5 output=$out5"
fi

# ===========================================================================
echo ""
echo "Test 6: persistInfra HARD-FAILS when the customer stage has no .git..."
# Codex P1: if prepare-custom-stack.sh's infra clone failed (or repo_clone_ssh_url
# was empty), custom-stack-provision could apply terraform, warn, exit success,
# and leave <project>-infra empty — the original issue #143 bug class. The
# required stage must fail the deploy instead of silently skipping.

set +e
out6="$(
  cd "$P5"
  export MARS_PROJECT_ROOT="$P5"
  . "$P5/shell_utils.sh"
  persistInfra custom-stack-provision 2>&1
)"
rc6=$?
set -e

if [[ $rc6 -ne 0 ]]; then
  pass "persistInfra: required stage with no .git returns non-zero (fails the deploy, not silent)"
else
  fail "persistInfra: required stage with no .git SILENTLY succeeded (rc=0) — issue #143 bug class. Output: $out6"
fi

if echo "$out6" | grep -q "ERROR: persistInfra: no .git"; then
  pass "persistInfra: required stage with no .git emits a loud ERROR"
else
  fail "persistInfra: required stage missing loud ERROR. Output: $out6"
fi

# --- Summary ---------------------------------------------------------------
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
