#!/usr/bin/env bash
set -euo pipefail

# Integration checks: the template's scripts drive the mars infra-* commands.
#
# Every git step on a project tree and its per-project -infra repo is a mars
# command (luthersystems/mars docs/infra-repo.md). The rules themselves (the
# merge's exit codes and refusals, the snapshot on top of infra/main, the
# staging, exec-bit and untrack rules, the snapshot-tree marks) are tested in
# Go in mars, internal/infrarepo, on real temp repos: that is the port of
# this file's 110 earlier checks.
#
# What stays here is what only the template's scripts decide, run with a
# MOCK terraform (no cloud) and REAL git and mars against a local bare
# "infra" repo:
#   - the custom-stack apply paths (apply-with-outputs.sh, apply-plan.sh)
#     persist to the -infra repo, and only for custom-stack-provision (#143);
#   - apply.sh merges infra/main before Terraform, stops on a failed merge
#     with the conflict aborted, and pushes a snapshot after the apply;
#   - destroy.sh exits 75 when the destroy worked but the commit did not, and
#     never on a stray 75 from an earlier step;
#   - pull.sh and commit.sh; the template tracks no ignored file; the
#     template-only workflows carry their repository guard;
#   - a mars without the infra-* commands stops the apply (fail closed).
#
# MARS_BIN must name a mars build with the infra-* commands, for example
#   go build -o /tmp/mars ./cmd/mars   (in a luthersystems/mars checkout)
#   MARS_BIN=/tmp/mars bash tests/test-infra-push.sh

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
# shellcheck source=tests/mars-infra.sh
. "$REPO_ROOT/tests/mars-infra.sh"
requireMarsInfra

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
  # Decoy deploy-time output artifact — must never ride the -infra push (#160).
  echo '{"dummy": true}' > "$proj/outputs/dummy.json"
  cp "$REPO_ROOT/shell_utils.sh" "$proj/shell_utils.sh"
  cp "$REPO_ROOT/tf/utils.sh" "$proj/tf/utils.sh"
  cp "$REPO_ROOT/tf/drift-check.sh" "$proj/tf/drift-check.sh"
  cp "$REPO_ROOT/tf/apply-with-outputs.sh" "$proj/tf/apply-with-outputs.sh"
  cp "$REPO_ROOT/tf/apply-plan.sh" "$proj/tf/apply-plan.sh"
  # The repo's REAL .gitignore: the snapshot's `git add -A` honors the #160
  # denylist (mars tests the denylist itself: TestPersistKeepsSecretsOut).
  cp "$REPO_ROOT/.gitignore" "$proj/.gitignore"
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
  pass "A: mars infra-persist was reached (custom-stack scope)"
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
  pass "B: mars infra-persist was reached"
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
# A remote the apply step cannot clone either (infra-persist tries,
# since a step with the GitHub App token can clone what prepare could not).
set_repo_clone_url "$PROJ" "file://$WORKDIR/no-such-repo.git"
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
echo "=== Case L: the template tracks no file that its .gitignore ignores ==="
# =============================================================================
# Guards the class behind mars TestPersistUntracksTrackedCredentials: a
# tracked file that .gitignore ignores is committed anyway by `git add -A` in
# every project tree cloned from this repo. Fix a hit with `git rm --cached <path>`, or add a `!` carve-out to
# .gitignore if the file is meant to be tracked.
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  tracked_ignored="$(git -C "$REPO_ROOT" ls-files --cached --ignored --exclude-per-directory=.gitignore)"
  if [[ -z "$tracked_ignored" ]]; then
    pass "L: no tracked file is ignored"
  else
    fail "L: tracked files that .gitignore ignores (they reach -infra repos): $tracked_ignored"
  fi
else
  echo "  SKIP: L: $REPO_ROOT is not a git checkout"
fi

# =============================================================================
echo ""
echo "=== Case N: simple-mode apply (apply.sh) after a history squash ==="
# =============================================================================
# apply-with-outputs.sh without --check-drift runs apply.sh. apply.sh merged
# infra/main under set -e before Terraform ran, and the merge always fails on
# ui-core's squashed history, so the apply aborted before it applied. Now it
# applies first and pushes a snapshot, like infra-persist.
PROJ="$(make_project projN)"
cp "$REPO_ROOT/tf/apply.sh" "$PROJ/tf/apply.sh"
# utils.sh points MARS at tf/run-with-creds.sh, so that is the mock here.
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
# infra/main with a history of its own.
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "first deploy"
git -C "$PROJ" push -q "file://$BARE" main
base_headN="$(git -C "$BARE" rev-parse main)"
# The ui-core squash.
rm -rf "$PROJ/.git"
init_project_git "$PROJ"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "ui-core: squashed project history"
mkdir -p "$PROJ/tf/custom-stack-provision"
echo "simple-mode-change" > "$PROJ/tf/custom-stack-provision/main.tf"

set +e
outN="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision)"
rcN=$?
set -e

if [[ "$rcN" -eq 0 ]] && grep -q "apply --approve" "$CMD_LOG"; then
  pass "N: the simple-mode apply ran Terraform and exits 0"
else
  fail "N: simple-mode apply rc=$rcN, or no mars apply ran. Output: $outN"
fi
if git -C "$BARE" merge-base --is-ancestor "$base_headN" main &&
  [[ "$(git -C "$BARE" show main:tf/custom-stack-provision/main.tf 2>/dev/null)" == "simple-mode-change" ]]; then
  pass "N: apply.sh pushed the deployed tree as a fast-forward"
else
  fail "N: apply.sh did not fast-forward infra/main with the deployed tree. Output: $outN"
fi

# =============================================================================
echo ""
echo "=== Case O: template-only files never reach the -infra repo ==="
# =============================================================================
# .github/dependabot.yml configures Dependabot for the template repo. In an
# -infra repo it would open weekly PRs that the next deploy reverts, so the
# snapshot leaves it out, and removes it if an older push added it.
PROJ="$(make_project projO)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
mkdir -p "$PROJ/.github/workflows"
cp "$REPO_ROOT/.github/dependabot.yml" "$PROJ/.github/dependabot.yml"
cp "$REPO_ROOT/.github/workflows/security.yml" "$PROJ/.github/workflows/security.yml"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "older push, with dependabot.yml"
git -C "$PROJ" push -q "file://$BARE" main

set +e
outO="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcO=$?
set -e
pushed_tree="$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null || echo "")"
if [[ "$rcO" -eq 0 ]] && echo "$pushed_tree" | grep -qx "shell_utils.sh"; then
  pass "O: the deploy pushed the stack"
else
  fail "O: rc=$rcO, or nothing pushed. Output: $outO"
fi
if echo "$pushed_tree" | grep -qx ".github/dependabot.yml"; then
  fail "O: .github/dependabot.yml reached the -infra repo"
else
  pass "O: .github/dependabot.yml is not in the -infra repo"
fi
if [[ -f "$PROJ/.github/dependabot.yml" ]]; then
  pass "O: dependabot.yml stays on disk"
else
  fail "O: dependabot.yml was removed from disk"
fi
# security.yml does ride along (it is a workflow file of the tree), so it
# must not run in an -infra repo: the same repository guard as quality.yml.
for wf in quality security; do
  if grep -qF "if: github.repository == 'luthersystems/sandbox-infrastructure-template'" \
    "$REPO_ROOT/.github/workflows/$wf.yml"; then
    pass "O: $wf.yml runs only in the template repo"
  else
    fail "O: $wf.yml has no repository guard, so every -infra repo runs it"
  fi
done

# =============================================================================
echo ""
echo "=== Case P: apply.sh from a stale checkout merges teammates' edits first ==="
# =============================================================================
# A developer's checkout shares history with infra/main but is behind it.
# apply.sh merges infra/main before Terraform runs, so the apply includes the
# teammate's change, then pushes the snapshot.
PROJ="$(make_project projP)"
cp "$REPO_ROOT/tf/apply.sh" "$PROJ/tf/apply.sh"
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "shared base"
git -C "$PROJ" push -q "file://$BARE" main
mate="$WORKDIR/projP-mate"
git clone -q -b main "file://$BARE" "$mate"
echo "teammate change" > "$mate/teammate.txt"
git -C "$mate" add teammate.txt
git -C "$mate" -c user.email=t@l -c user.name=T commit -q -m "teammate edit"
git -C "$mate" push -q origin main
mate_headP="$(git -C "$BARE" rev-parse main)"
# Record whether the teammate's file is in the tree when Terraform runs.
cat > "$PROJ/tf/run-with-creds.sh" <<OUTER
#!/usr/bin/env bash
echo "mars \$*" >> "$CMD_LOG"
if [[ -f "$PROJ/teammate.txt" ]]; then echo "teammate-present" >> "$CMD_LOG"; fi
OUTER
/bin/chmod +x "$PROJ/tf/run-with-creds.sh"

set +e
outP="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision)"
rcP=$?
set -e
if [[ "$rcP" -eq 0 ]] && grep -q "apply --approve" "$CMD_LOG" && grep -q "teammate-present" "$CMD_LOG"; then
  pass "P: the stale checkout merged infra/main before Terraform ran"
else
  fail "P: rc=$rcP, or Terraform ran without the teammate's edit. Output: $outP"
fi
if git -C "$BARE" merge-base --is-ancestor "$mate_headP" main &&
  git -C "$BARE" cat-file -e main:teammate.txt 2>/dev/null; then
  pass "P: the push fast-forwards and keeps the teammate's edit"
else
  fail "P: infra/main lost the teammate's edit or did not fast-forward"
fi

# =============================================================================
echo ""
echo "=== Case Q: apply.sh stops on a real merge conflict, before Terraform ==="
# =============================================================================
PROJ="$(make_project projQ)"
cp "$REPO_ROOT/tf/apply.sh" "$PROJ/tf/apply.sh"
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
echo "base" > "$PROJ/conflict.txt"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "shared base"
git -C "$PROJ" push -q "file://$BARE" main
mate="$WORKDIR/projQ-mate"
git clone -q -b main "file://$BARE" "$mate"
echo "theirs" > "$mate/conflict.txt"
git -C "$mate" -c user.email=t@l -c user.name=T commit -q -am "their edit"
git -C "$mate" push -q origin main
echo "ours" > "$PROJ/conflict.txt"
git -C "$PROJ" commit -q -am "our edit"

set +e
outQ="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision)"
rcQ=$?
set -e
if [[ "$rcQ" -ne 0 ]] && ! grep -q "apply --approve" "$CMD_LOG"; then
  pass "Q: a merge conflict stops the apply before Terraform runs"
else
  fail "Q: rc=$rcQ; a conflicted checkout must not apply. Output: $outQ"
fi
# apply.sh aborts the failed merge: a MERGE_HEAD or conflict markers left on
# disk would be pushed by a later snapshot.
if [[ ! -e "$PROJ/.git/MERGE_HEAD" ]] && [[ "$(cat "$PROJ/conflict.txt")" == "ours" ]] &&
  [[ -z "$(git -C "$PROJ" status --porcelain --untracked-files=no)" ]]; then
  pass "Q: the conflicted merge is aborted (no MERGE_HEAD, no markers)"
else
  fail "Q: the conflicted merge was left in place: $(git -C "$PROJ" status --short) / $(cat "$PROJ/conflict.txt")"
fi

# pull.sh leaves the conflict in place for the developer to resolve, as
# a plain git merge does.
PROJ="$(make_project projQ2)"
cp "$REPO_ROOT/pull.sh" "$PROJ/pull.sh"
BARE="$(fresh_bare)"
TPL="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
echo "base" > "$PROJ/conflict.txt"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m "shared base"
git -C "$PROJ" push -q "file://$BARE" main
git -C "$PROJ" push -q "file://$TPL" main
git -C "$PROJ" remote add origin "file://$TPL"
git -C "$PROJ" remote add infra "file://$BARE"
mate="$WORKDIR/projQ2-mate"
git clone -q -b main "file://$BARE" "$mate"
echo "theirs" > "$mate/conflict.txt"
git -C "$mate" -c user.email=t@l -c user.name=T commit -q -am "their edit"
git -C "$mate" push -q origin main
echo "ours" > "$PROJ/conflict.txt"
git -C "$PROJ" commit -q -am "our edit"
set +e
outQ2="$(cd "$PROJ" && MARS_PROJECT_ROOT="$PROJ" HOME="$WORKDIR" bash ./pull.sh 2>&1)"
rcQ2=$?
set -e
if [[ "$rcQ2" -ne 0 ]] && [[ -e "$PROJ/.git/MERGE_HEAD" ]] && grep -q '<<<<<<<' "$PROJ/conflict.txt"; then
  pass "Q: pull.sh fails on a conflict and leaves it to resolve (MERGE_HEAD stays)"
else
  fail "Q: pull.sh rc=$rcQ2, MERGE_HEAD=$([[ -e "$PROJ/.git/MERGE_HEAD" ]] && echo yes || echo no). Output: $outQ2"
fi
# The developer resolves the conflict; commit.sh concludes the merge.
cp "$REPO_ROOT/commit.sh" "$PROJ/commit.sh"
echo "resolved" > "$PROJ/conflict.txt"
git -C "$PROJ" add conflict.txt
set +e
outQ3="$(cd "$PROJ" && HOME="$WORKDIR" bash ./commit.sh "resolve" 2>&1)"
rcQ3=$?
set -e
if [[ "$rcQ3" -eq 0 ]] && [[ ! -e "$PROJ/.git/MERGE_HEAD" ]] &&
  [[ "$(git -C "$PROJ" rev-list --parents -n1 HEAD | wc -w)" -eq 3 ]]; then
  pass "Q: commit.sh concludes a resolved merge (a merge commit)"
else
  fail "Q: commit.sh after resolving: rc=$rcQ3. Output: $outQ3"
fi

# =============================================================================
# =============================================================================
echo ""
echo "=== Case T: destroy.sh exit codes ==="
# =============================================================================
# conflicted_proj <name> — a project with an infra remote and a conflicted
# `git merge infra/main` in progress; prints its path.
conflicted_proj() {
  local proj bare mate
  proj="$(make_project "$1")"
  bare="$(fresh_bare)"
  set_repo_clone_url "$proj" "file://$bare"
  init_project_git "$proj"
  echo "base" > "$proj/conflict.txt"
  git -C "$proj" add -A
  git -C "$proj" commit -q -m "shared base"
  git -C "$proj" push -q "file://$bare" main
  git -C "$proj" remote add infra "file://$bare"
  mate="$WORKDIR/$1-mate"
  git clone -q -b main "file://$bare" "$mate"
  echo "theirs" > "$mate/conflict.txt"
  git -C "$mate" -c user.email=t@l -c user.name=T commit -q -am "their edit"
  git -C "$mate" push -q origin main
  echo "ours" > "$proj/conflict.txt"
  git -C "$proj" commit -q -am "our edit"
  git -C "$proj" fetch -q infra main
  git -C "$proj" merge -q infra/main >/dev/null 2>&1 || true
  echo "$proj"
}


# destroy.sh: the destroy worked but the commit did not -> exit 3 and say so.
PROJ="$(conflicted_proj projT6)"
cp "$REPO_ROOT/tf/destroy.sh" "$PROJ/tf/destroy.sh"
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
set +e
outT6="$(run_apply "$PROJ" destroy.sh custom-stack-provision)"
rcT6=$?
set -e
if [[ "$rcT6" -eq 75 ]] && grep -q "destroy --approve" "$CMD_LOG" &&
  grep -qi "destroyed" <<<"$outT6" && grep -q "commit.sh" <<<"$outT6"; then
  pass "T: destroy.sh exits 75 with a clear message when the commit is refused after the destroy"
else
  fail "T: destroy.sh after a failed commit: rc=$rcT6. Output: $outT6"
fi

# A failing pre-commit hook: infra-commit reports the failed commit itself.
PROJ="$(make_project projT7)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m base
cp "$REPO_ROOT/tf/destroy.sh" "$PROJ/tf/destroy.sh"
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
printf '#!/bin/sh\nexit 1\n' > "$PROJ/.git/hooks/pre-commit"
/bin/chmod +x "$PROJ/.git/hooks/pre-commit"
headT7="$(git -C "$PROJ" rev-parse HEAD)"
set +e
outT7="$(run_apply "$PROJ" destroy.sh custom-stack-provision)"
rcT7=$?
set -e
if [[ "$rcT7" -eq 75 ]] && [[ "$(git -C "$PROJ" rev-parse HEAD)" == "$headT7" ]]; then
  pass "T: a failing pre-commit hook makes destroy.sh exit 75"
else
  fail "T: destroy.sh with a failing hook: rc=$rcT7. Output: $outT7"
fi



# destroy.sh: a pre-destroy step that exits 75 does not look like "destroyed,
# commit failed".
PROJ="$(make_project projT13)"
init_project_git "$PROJ"
git -C "$PROJ" add -A
git -C "$PROJ" commit -q -m base
cp "$REPO_ROOT/tf/destroy.sh" "$PROJ/tf/destroy.sh"
cat > "$PROJ/tf/run-with-creds.sh" <<OUTER
#!/usr/bin/env bash
echo "mars \$*" >> "$CMD_LOG"
if [[ " \$* " == *" init "* ]]; then exit 75; fi
OUTER
/bin/chmod +x "$PROJ/tf/run-with-creds.sh"
set +e
outT13="$(run_apply "$PROJ" destroy.sh custom-stack-provision)"
rcT13=$?
set -e
if [[ "$rcT13" -ne 0 && "$rcT13" -ne 75 ]] && ! grep -q "destroy --approve" "$CMD_LOG"; then
  pass "T: a pre-destroy step exiting 75 makes destroy.sh exit $rcT13, not 75"
else
  fail "T: pre-destroy 75: rc=$rcT13. Output: $outT13"
fi


# =============================================================================
echo ""
echo "=== Case U: pull.sh in an -infra clone ==="
# =============================================================================
# seed_infra <bare> — push a one-commit main to bare; prints the commit.
seed_infra() {
  local src="$WORKDIR/seed-$RANDOM$RANDOM"
  git init -q -b main "$src"
  echo "infra" > "$src/infra.txt"
  git -C "$src" add -A
  git -C "$src" -c user.email=t@l -c user.name=T commit -q -m "infra base"
  git -C "$src" push -q "file://$1" main
  git -C "$src" rev-parse HEAD
}
# An -infra clone has no origin remote: pull.sh skips the template merge and
# still merges infra/main.
BARE="$(fresh_bare)"
seed_infra "$BARE" >/dev/null
PROJ="$WORKDIR/projU1"
git clone -q -b main "file://$BARE" "$PROJ"
git -C "$PROJ" remote rename origin infra
git -C "$PROJ" config user.email t@l
git -C "$PROJ" config user.name T
cp "$REPO_ROOT/shell_utils.sh" "$REPO_ROOT/pull.sh" "$PROJ/"
printf 'shell_utils.sh\npull.sh\n' >> "$PROJ/.git/info/exclude"
mkdir -p "$PROJ/tf/auto-vars"
jq -n --arg url "file://$BARE" '{"repo_clone_ssh_url":$url}' > "$PROJ/tf/auto-vars/common.auto.tfvars.json"
echo "tf/auto-vars/" >> "$PROJ/.git/info/exclude"
mate="$WORKDIR/projU1-mate"
git clone -q -b main "file://$BARE" "$mate"
echo "mate" > "$mate/mate.txt"
git -C "$mate" add -A
git -C "$mate" -c user.email=t@l -c user.name=T commit -q -m "mate edit"
git -C "$mate" push -q origin main
git -C "$PROJ" -c user.email=t@l -c user.name=T commit -q --allow-empty -m "local"
set +e
outU1="$(cd "$PROJ" && MARS_PROJECT_ROOT="$PROJ" HOME="$WORKDIR" bash ./pull.sh 2>&1)"
rcU1=$?
set -e
if [[ "$rcU1" -eq 0 ]] && [[ -f "$PROJ/mate.txt" ]] && grep -qi "no origin remote" <<<"$outU1"; then
  pass "U: pull.sh in an -infra clone skips origin and merges infra/main"
else
  fail "U: -infra clone pull: rc=$rcU1. Output: $outU1"
fi


# =============================================================================
echo ""
echo "=== Case W: a mars without the infra-* commands stops the apply ==="
# =============================================================================
# ui-core's Argo jobs pin their own mars image. If it predates the infra-*
# commands, marsInfra must fail closed: apply.sh stops before Terraform, as
# for any failed merge, instead of applying with no -infra repo handling.
PROJ="$(make_project projW)"
cp "$REPO_ROOT/tf/apply.sh" "$PROJ/tf/apply.sh"
cp "$MOCK_MARS" "$PROJ/tf/run-with-creds.sh"
init_project_git "$PROJ"
OLD_MARS="$WORKDIR/old-mars"
printf '#!/usr/bin/env bash\necho "mars: error: unexpected argument $2" >&2\nexit 80\n' > "$OLD_MARS"
/bin/chmod +x "$OLD_MARS"
set +e
outW="$(MARS_BIN="$OLD_MARS" run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision)"
rcW=$?
set -e
if [[ "$rcW" -eq 1 ]] && ! grep -q "apply --approve" "$CMD_LOG" &&
  grep -qF "has no 'mars infra-merge'" <<<"$outW"; then
  pass "W: an old mars stops the apply before Terraform, with a loud warning"
else
  fail "W: old mars: rc=$rcW. Output: $outW"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
