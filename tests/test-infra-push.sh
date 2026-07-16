#!/usr/bin/env bash
set -euo pipefail

# Seam test for the per-project -infra repo push path (issue #143).
#
# Root cause captured here: ui-core always runs a custom-stack apply through the
# drift-check code path — `apply-with-outputs.sh <lc> --check-drift` or
# `apply-plan.sh <lc> --plan-file <id> --check-drift`. Neither of those branches
# used to reach gitMergeInfraMain/gitCommit/gitPushInfra (only apply.sh did, and
# ui-core never invokes apply.sh for an apply), so 89/89 -infra repos were left
# EMPTY despite a SUCCESS. The fix wires persistInfraRepo into both real apply
# paths, scoped to the custom-stack-provision stage.
#
# This test uses a MOCK terraform (no cloud) but REAL git, driving the actual
# apply-with-outputs.sh / apply-plan.sh scripts against a local bare "infra"
# repo. It asserts:
#   (i)  the push path is reached and a ref lands on the infra repo when the
#        repo_clone_ssh_url auto-var + a .git are present (custom-stack stage);
#   (ii) the loud, greppable "[git-infra] WARNING:" fires (and the apply still
#        exits 0) when either the .git or the auto-var is absent;
#   (iii) the persist step is SCOPED to custom-stack-provision — a non-custom
#        apply stage does not push.
#
# No rsync dependency (unlike test-prepare-custom-stack.sh) so it runs anywhere
# git + jq + a POSIX terraform mock are available.

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
if ! command -v git &>/dev/null; then
  echo "SKIP: git is required for these tests" >&2
  exit 0
fi

# --- Mock binaries (terraform / mars / chmod) ---------------------------------
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"

CMD_LOG="$WORKDIR/cmd-log.txt"
TF_SHOW_OUTPUT="$WORKDIR/show-output.json"
TF_OUTPUT_JSON="$WORKDIR/output-json.json"
MOCK_MARS="$WORKDIR/mock-mars.sh"

echo '{"resource_drift": []}' > "$TF_SHOW_OUTPUT"
echo '{"vpc_id": {"value": "vpc-123"}}' > "$TF_OUTPUT_JSON"

cat > "$MOCK_BIN/terraform" <<OUTER
#!/usr/bin/env bash
echo "terraform \$*" >> "$CMD_LOG"
if [[ "\$1" == "show" && "\$2" == "-json" ]]; then
  cat "$TF_SHOW_OUTPUT"
elif [[ "\$1" == "output" && "\$2" == "-json" ]]; then
  cat "$TF_OUTPUT_JSON"
elif [[ "\$1" == "init" ]]; then
  :
elif [[ "\$1" == "plan" ]]; then
  for arg in "\$@"; do
    if [[ "\$arg" == -out=* ]]; then touch "\${arg#-out=}"; fi
  done
elif [[ "\$1" == "apply" ]]; then
  :
fi
OUTER
chmod +x "$MOCK_BIN/terraform"

cat > "$MOCK_MARS" <<OUTER
#!/usr/bin/env bash
echo "mars \$*" >> "$CMD_LOG"
OUTER
chmod +x "$MOCK_MARS"

# chmod is a no-op mock so utils.sh's chmod on the mars wrapper never fails.
cat > "$MOCK_BIN/chmod" <<'OUTER'
#!/usr/bin/env bash
exit 0
OUTER
chmod +x "$MOCK_BIN/chmod"

export PATH="$MOCK_BIN:$PATH"

# --- Project-tree factory -----------------------------------------------------
# make_project <name> — build a fake mars project tree with the real scripts.
make_project() {
  local proj="$WORKDIR/$1"
  mkdir -p "$proj/tf/auto-vars"
  mkdir -p "$proj/ansible/inventories/default/group_vars/all"
  mkdir -p "$proj/outputs"
  cat > "$proj/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
  echo '{"cloud_provider": "aws"}' > "$proj/tf/auto-vars/common.auto.tfvars.json"
  cp "$REPO_ROOT/shell_utils.sh" "$proj/shell_utils.sh"
  cp "$REPO_ROOT/tf/utils.sh" "$proj/tf/utils.sh"
  cp "$REPO_ROOT/tf/drift-check.sh" "$proj/tf/drift-check.sh"
  cp "$REPO_ROOT/tf/apply-with-outputs.sh" "$proj/tf/apply-with-outputs.sh"
  cp "$REPO_ROOT/tf/apply-plan.sh" "$proj/tf/apply-plan.sh"
  # Mock apply.sh (only reached by simple mode, which these tests don't use).
  printf '#!/usr/bin/env bash\necho "apply.sh $*" >> "%s"\n' "$CMD_LOG" > "$proj/tf/apply.sh"
  chmod +x "$proj/tf/apply.sh"
  echo "$proj"
}

# set_repo_clone_url <proj> <url> — add repo_clone_ssh_url to auto-vars.
set_repo_clone_url() {
  jq -n --arg url "$2" '{"cloud_provider":"aws","repo_clone_ssh_url":$url}' \
    > "$1/tf/auto-vars/common.auto.tfvars.json"
}

# init_project_git <proj> — real git repo at project root (branch main).
init_project_git() {
  git -C "$1" init -q -b main
  git -C "$1" config user.email "test@luthersystems.com"
  git -C "$1" config user.name "Test"
}

# fresh_bare — a new empty bare repo to receive pushes; prints its path.
fresh_bare() {
  local bare="$WORKDIR/infra-$RANDOM-$RANDOM.git"
  git init -q --bare "$bare"
  echo "$bare"
}

# run_apply <proj> <script> <args...> — run an apply script in the project.
run_apply() {
  local proj="$1"; shift
  local script="$1"; shift
  : > "$CMD_LOG"
  (
    cd "$proj/tf"
    export MARS_PROJECT_ROOT="$proj"
    export MARS="$MOCK_MARS"
    export HOME="$WORKDIR"
    # No JUMP_ROLE_ARN; stage dir basename gates the preflight, not lifecycle.
    bash "$proj/tf/$script" "$@"
  ) 2>&1
}

bare_commit_count() { git -C "$1" rev-list --all --count 2>/dev/null || echo 0; }

# =============================================================================
echo "=== Case A: apply-with-outputs --check-drift populates -infra repo ==="
# =============================================================================
PROJ="$(make_project projA)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"

set +e
outA="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcA=$?
set -e

[[ "$rcA" -eq 0 ]] && pass "A: apply exits 0" || fail "A: expected exit 0, got $rcA. Output: $outA"

if echo "$outA" | grep -qF "[git-infra] Persisting applied stack"; then
  pass "A: persistInfraRepo was reached (custom-stack scope)"
else
  fail "A: persist step not reached. Output: $outA"
fi

if echo "$outA" | grep -qF "[git-infra] Pushed to infra remote"; then
  pass "A: push success line printed"
else
  fail "A: expected push-success line. Output: $outA"
fi

if [[ "$(bare_commit_count "$BARE")" -ge 1 ]]; then
  pass "A: a ref landed on the (previously empty) -infra repo"
else
  fail "A: -infra repo is still empty after a successful apply (#143 regression)"
fi

if git -C "$BARE" for-each-ref --format='%(refname)' | grep -qF 'refs/heads/main'; then
  pass "A: ref landed on refs/heads/main"
else
  fail "A: no refs/heads/main on the infra repo. refs: $(git -C "$BARE" for-each-ref)"
fi

# =============================================================================
echo ""
echo "=== Case B: apply-plan --check-drift populates -infra repo ==="
# =============================================================================
PROJ="$(make_project projB)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
# Pre-create the saved plan file where apply-plan.sh expects it.
mkdir -p "$PROJ/tf/custom-stack-provision"
echo "fake-plan" > "$PROJ/tf/custom-stack-provision/myplan.tfplan"

set +e
outB="$(run_apply "$PROJ" apply-plan.sh custom-stack-provision --plan-file myplan --check-drift)"
rcB=$?
set -e

[[ "$rcB" -eq 0 ]] && pass "B: apply-plan exits 0" || fail "B: expected exit 0, got $rcB. Output: $outB"

if echo "$outB" | grep -qF "[git-infra] Persisting applied stack"; then
  pass "B: persistInfraRepo was reached"
else
  fail "B: persist step not reached. Output: $outB"
fi

if [[ "$(bare_commit_count "$BARE")" -ge 1 ]]; then
  pass "B: a ref landed on the -infra repo via apply-plan.sh"
else
  fail "B: apply-plan.sh left the -infra repo empty (#143 regression)"
fi

# =============================================================================
echo ""
echo "=== Case C: no .git → LOUD warning, no push, apply still succeeds ==="
# =============================================================================
PROJ="$(make_project projC)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
# NOTE: deliberately NOT initializing .git at the project root.

set +e
outC="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcC=$?
set -e

[[ "$rcC" -eq 0 ]] && pass "C: apply exits 0 even without .git (non-fatal)" \
  || fail "C: expected exit 0, got $rcC. Output: $outC"

if echo "$outC" | grep -qF "[git-infra] WARNING:" && echo "$outC" | grep -qF "no .git"; then
  pass "C: loud '[git-infra] WARNING: ... no .git' fired"
else
  fail "C: expected a loud no-.git warning. Output: $outC"
fi

if [[ "$(bare_commit_count "$BARE")" -eq 0 ]]; then
  pass "C: nothing pushed when .git is absent"
else
  fail "C: something was pushed despite missing .git"
fi

# =============================================================================
echo ""
echo "=== Case D: repo_clone_ssh_url empty → LOUD warning, no remote, exits 0 ==="
# =============================================================================
PROJ="$(make_project projD)"
init_project_git "$PROJ"
# auto-vars intentionally has NO repo_clone_ssh_url (default from make_project).

set +e
outD="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcD=$?
set -e

[[ "$rcD" -eq 0 ]] && pass "D: apply exits 0 even with empty repo_clone_ssh_url" \
  || fail "D: expected exit 0, got $rcD. Output: $outD"

if echo "$outD" | grep -qF "[git-infra] WARNING:" && echo "$outD" | grep -qF "repo_clone_ssh_url is empty"; then
  pass "D: loud '[git-infra] WARNING: ... repo_clone_ssh_url is empty' fired"
else
  fail "D: expected a loud empty-URL warning. Output: $outD"
fi

if echo "$outD" | grep -qF "no 'infra' remote configured"; then
  pass "D: gitPushInfra warned that no infra remote is configured"
else
  fail "D: expected 'no infra remote configured' warning. Output: $outD"
fi

# =============================================================================
echo ""
echo "=== Case E: persist is SCOPED to custom-stack-provision ==="
# =============================================================================
PROJ="$(make_project projE)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"

set +e
outE="$(run_apply "$PROJ" apply-with-outputs.sh vm-provision --check-drift)"
rcE=$?
set -e

[[ "$rcE" -eq 0 ]] && pass "E: non-custom apply exits 0" || fail "E: expected exit 0, got $rcE. Output: $outE"

if echo "$outE" | grep -qF "[git-infra] Persisting applied stack"; then
  fail "E: persist step ran for a NON custom-stack lifecycle (should be scoped out)"
else
  pass "E: persist step correctly skipped for vm-provision"
fi

if [[ "$(bare_commit_count "$BARE")" -eq 0 ]]; then
  pass "E: nothing pushed for a non-custom-stack apply"
else
  fail "E: a non-custom apply pushed to the -infra repo"
fi

# =============================================================================
echo ""
echo "=== Case F: re-deploy — second apply fast-forwards the -infra repo ==="
# =============================================================================
PROJ="$(make_project projF)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"

set +e
run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift >/dev/null
first_rc=$?
set -e
first_count="$(bare_commit_count "$BARE")"

# Mutate the working tree so the second apply has something new to commit.
echo "second-deploy-change" > "$PROJ/tf/custom-stack-provision/main.tf"

set +e
outF="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcF=$?
set -e
second_count="$(bare_commit_count "$BARE")"

if [[ "$first_rc" -eq 0 && "$rcF" -eq 0 ]]; then
  pass "F: both applies exit 0"
else
  fail "F: apply exit codes first=$first_rc second=$rcF. Output: $outF"
fi

if [[ "$first_count" -ge 1 && "$second_count" -gt "$first_count" ]]; then
  pass "F: re-deploy added a new commit to the -infra repo ($first_count → $second_count)"
else
  fail "F: re-deploy did not advance the -infra repo ($first_count → $second_count)"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
