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
  # Decoy deploy-time output artifact — must never ride the -infra push (#160).
  echo '{"dummy": true}' > "$proj/outputs/dummy.json"
  cp "$REPO_ROOT/shell_utils.sh" "$proj/shell_utils.sh"
  cp "$REPO_ROOT/tf/utils.sh" "$proj/tf/utils.sh"
  cp "$REPO_ROOT/tf/drift-check.sh" "$proj/tf/drift-check.sh"
  cp "$REPO_ROOT/tf/apply-with-outputs.sh" "$proj/tf/apply-with-outputs.sh"
  cp "$REPO_ROOT/tf/apply-plan.sh" "$proj/tf/apply-plan.sh"
  # Copy the repo's REAL .gitignore into the fixture so `git add -A` in
  # persistInfraRepo honors the #160 denylist — this is what makes the Case G
  # canary below actually exercise the exclusions rather than pass vacuously.
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
# A remote the apply step cannot clone either (persistInfraRepo tries,
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

# =============================================================================
echo ""
echo "=== Case G: #160 canary — sensitive artifacts never reach the -infra repo ==="
# =============================================================================
# make_project copies the repo's real .gitignore into the fixture and drops
# decoys (tf/auto-vars/common.auto.tfvars.json + outputs/dummy.json). Here we
# additionally drop secrets/ credential files, a saved plan, a backend json, and
# a per-stage tfvars copy, then run a real custom-stack apply and assert the
# pushed tree carries NONE of them — the #143 push path must not leak the #160
# artifacts. tfSetup also stages secrets/cloud-credentials.auto.tfvars.json into
# tf/custom-stack-provision/zz-secret.auto.tfvars.json, so the *.auto.tfvars.json
# assertion also covers the Phase-1 staged credential copy.
PROJ="$(make_project projG)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"   # writes a decoy tf/auto-vars/common.auto.tfvars.json
init_project_git "$PROJ"

# Decoy sensitive artifacts that MUST NOT be pushed to the -infra repo (#160):
mkdir -p "$PROJ/secrets"
echo '{"bootstrap_role":"arn:aws:iam::1:role/x","aws_external_id":"topsecret"}' \
  > "$PROJ/secrets/cloud-credentials.auto.tfvars.json"
echo 'deploy-key-material' > "$PROJ/secrets/infra_deploy_key.pem"
mkdir -p "$PROJ/tf/custom-stack-provision"
echo '{"cloud_provider":"aws"}' > "$PROJ/tf/custom-stack-provision/common.auto.tfvars.json"
echo 'plan-bytes'              > "$PROJ/tf/custom-stack-provision/apply.tfplan"
echo '{}'                      > "$PROJ/tf/custom-stack-provision/backend.tf.json"

set +e
outG="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcG=$?
set -e

[[ "$rcG" -eq 0 ]] && pass "G: apply exits 0" || fail "G: expected exit 0, got $rcG. Output: $outG"

# The push must have happened, else the tree-content assertions are vacuous.
if [[ "$(bare_commit_count "$BARE")" -ge 1 ]]; then
  pass "G: a ref landed on the -infra repo"
else
  fail "G: nothing pushed — canary would be vacuous. Output: $outG"
fi

# Enumerate the pushed tree once.
pushed_tree="$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null || echo "")"

# Sanity: a known-good, non-secret file IS present — proves the denylist did not
# nuke the whole tree (i.e. the canary can actually observe a leak).
if echo "$pushed_tree" | grep -qx "shell_utils.sh"; then
  pass "G: known-good file (shell_utils.sh) is present in the pushed tree"
else
  fail "G: expected shell_utils.sh in the pushed tree. Tree: $pushed_tree"
fi

# The #160 canary assertions:
if echo "$pushed_tree" | grep -q '\.auto\.tfvars\.json$'; then
  fail "G: a *.auto.tfvars.json rode the -infra push (#160 leak). Tree: $pushed_tree"
else
  pass "G: NO *.auto.tfvars.json in the pushed tree"
fi

if echo "$pushed_tree" | grep -q '^outputs/'; then
  fail "G: outputs/ rode the -infra push (#160 leak). Tree: $pushed_tree"
else
  pass "G: NO outputs/ directory in the pushed tree"
fi

if echo "$pushed_tree" | grep -q '^secrets/'; then
  fail "G: secrets/ rode the -infra push (#160 leak). Tree: $pushed_tree"
else
  pass "G: NO secrets/ directory in the pushed tree"
fi

# Bonus coverage for the rest of the #160 denylist exercised by the decoys above.
if echo "$pushed_tree" | grep -q '\.tfplan$'; then
  fail "G: a *.tfplan rode the -infra push (#160 leak). Tree: $pushed_tree"
else
  pass "G: NO *.tfplan in the pushed tree"
fi

if echo "$pushed_tree" | grep -q 'backend\.tf\.json$'; then
  fail "G: backend.tf.json rode the -infra push (#160 leak). Tree: $pushed_tree"
else
  pass "G: NO backend.tf.json in the pushed tree"
fi

# =============================================================================
echo ""
echo "=== Case H: snapshot-fidelity — archive-owned provider siblings ARE pushed, ==="
echo "===         deploy-generated providers-<cloud>.tf is NOT (bridge e2e gap) ==="
# =============================================================================
# The historic over-broad `tf/*/providers-*.tf` .gitignore glob was meant only
# for the deploy-time-generated providers-aws.tf / providers-gcp.tf that
# _selectCloudFiles() (shell_utils.sh) materializes from the .tf.tmpl templates.
# But it ALSO matched the composer-archive-owned providers-imported.tf /
# providers-aliases.tf (insideout-terraform-presets #677) that the InsideOut
# composer emits into the custom-stack archive and rsyncs into
# tf/custom-stack-provision/ — silently dropping those real stack files from the
# persistInfraRepo() `git add -A` snapshot push. The deploy itself was unaffected
# (it reads the rsync'd worktree on disk, not git), so this was a SNAPSHOT-
# FIDELITY bug only, caught by the bridge team's e2e. make_project copies the
# repo's REAL .gitignore into the fixture, so this canary exercises the actual
# narrowed rule rather than passing vacuously.
PROJ="$(make_project projH)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"

mkdir -p "$PROJ/tf/custom-stack-provision"
# Deploy-generated decoy — MUST stay excluded from the -infra snapshot:
echo '# generated by _selectCloudFiles() from providers-aws.tf.tmpl' \
  > "$PROJ/tf/custom-stack-provision/providers-aws.tf"
# Composer-archive-owned siblings (presets #677) rsynced in — MUST land in the
# snapshot. They reference var.bootstrap_role / var.aws_external_id only:
echo 'provider "aws" { alias = "imported" }' \
  > "$PROJ/tf/custom-stack-provision/providers-imported.tf"
echo 'provider "aws" { alias = "us_east_1" }' \
  > "$PROJ/tf/custom-stack-provision/providers-aliases.tf"

set +e
outH="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcH=$?
set -e

[[ "$rcH" -eq 0 ]] && pass "H: apply exits 0" || fail "H: expected exit 0, got $rcH. Output: $outH"

# The push must have happened, else the tree-content assertions are vacuous.
if [[ "$(bare_commit_count "$BARE")" -ge 1 ]]; then
  pass "H: a ref landed on the -infra repo"
else
  fail "H: nothing pushed — canary would be vacuous. Output: $outH"
fi

pushed_tree_H="$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null || echo "")"

if echo "$pushed_tree_H" | grep -qx "tf/custom-stack-provision/providers-imported.tf"; then
  pass "H: archive-owned providers-imported.tf IS in the pushed snapshot"
else
  fail "H: providers-imported.tf missing from snapshot (over-broad glob regressed). Tree: $pushed_tree_H"
fi

if echo "$pushed_tree_H" | grep -qx "tf/custom-stack-provision/providers-aliases.tf"; then
  pass "H: archive-owned providers-aliases.tf IS in the pushed snapshot"
else
  fail "H: providers-aliases.tf missing from snapshot (over-broad glob regressed). Tree: $pushed_tree_H"
fi

if echo "$pushed_tree_H" | grep -qx "tf/custom-stack-provision/providers-aws.tf"; then
  fail "H: deploy-generated providers-aws.tf leaked into the snapshot (glob too narrow). Tree: $pushed_tree_H"
else
  pass "H: deploy-generated providers-aws.tf correctly excluded from the snapshot"
fi

# =============================================================================
echo ""
echo "=== Case I: the custom-stack apply clones the -infra repo when prepare could not ==="
# =============================================================================
# With ui-core's GitHub App, prepare-custom-stack has no token and no deploy
# key, so it leaves the tree without .git; the apply step has the token and
# clones the repo itself (cloneInfraRepo in persistInfraRepo,
# luthersystems/ui-infrastructure#442).
PROJ="$(make_project projI)"
BARE="$(fresh_bare)"
SEED="$WORKDIR/seedI"
git init -q -b main "$SEED"
git -C "$SEED" -c user.email=t@l -c user.name=T commit -q --allow-empty -m "earlier deploy"
git -C "$SEED" push -q "$BARE" main
git -C "$BARE" symbolic-ref HEAD refs/heads/main
set_repo_clone_url "$PROJ" "file://$BARE"
mkdir -p "$PROJ/tf/custom-stack-provision"
echo 'resource "null_resource" "x" {}' > "$PROJ/tf/custom-stack-provision/main.tf"

set +e
outI="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcI=$?
set -e

[[ "$rcI" -eq 0 ]] && pass "I: apply exits 0" || fail "I: expected exit 0, got $rcI. Output: $outI"
if [[ "$(bare_commit_count "$BARE")" -ge 2 ]]; then
  pass "I: the apply cloned the repo and pushed on top of its history"
else
  fail "I: expected a new commit on the -infra repo. Output: $outI"
fi
if git -C "$BARE" ls-tree -r --name-only main | grep -qx "tf/custom-stack-provision/main.tf"; then
  pass "I: the pushed tree has the custom stack"
else
  fail "I: custom stack missing from the pushed tree: $(git -C "$BARE" ls-tree -r --name-only main | tr "\n" " ") Output: $outI"
fi

# =============================================================================
echo ""
echo "=== Case J: git access with the GitHub App token ==="
# =============================================================================
PROJ="$(make_project projJ)"
TOKEN_FILE="$WORKDIR/app-token"
echo "ghs_testtoken" > "$TOKEN_FILE"
set_repo_clone_url "$PROJ" "git@github.com:luthersystems-infra-test/abcd1234-infra.git"
init_project_git "$PROJ"
git -C "$PROJ" config core.sshCommand "ssh -i old-key"

outJ="$(
  export MARS_PROJECT_ROOT="$PROJ" GITHUB_GIT_TOKEN_FILE="$TOKEN_FILE"
  . "$PROJ/shell_utils.sh" >/dev/null 2>&1
  configure_git >/dev/null 2>&1
  echo "remote=$(git -C "$PROJ" remote get-url infra)"
  printf 'protocol=https\nhost=github.com\npath=luthersystems-infra-test/abcd1234-infra.git\n\n' |
    GIT_TERMINAL_PROMPT=0 git -C "$PROJ" credential fill
  echo "ssh=$(git -C "$PROJ" config --local core.sshCommand || true)"
)"
if echo "$outJ" | grep -qx "remote=https://github.com/luthersystems-infra-test/abcd1234-infra.git"; then
  pass "J: with a token, the infra remote is the HTTPS URL"
else
  fail "J: infra remote is not HTTPS. Output: $outJ"
fi
if echo "$outJ" | grep -qx "password=ghs_testtoken" && echo "$outJ" | grep -qx "username=x-access-token"; then
  pass "J: git gets the token from the credential helper"
else
  fail "J: credential helper did not give the token. Output: $outJ"
fi
if echo "$outJ" | grep -qx "ssh="; then
  pass "J: an earlier deploy key's sshCommand is removed"
else
  fail "J: core.sshCommand still set. Output: $outJ"
fi
if grep -rqF "ghs_testtoken" "$PROJ/.git/config"; then
  fail "J: the token is in .git/config, which travels in the project archive"
else
  pass "J: the token is not in .git/config"
fi

outJ2="$(
  export MARS_PROJECT_ROOT="$PROJ"
  unset GITHUB_GIT_TOKEN_FILE GITHUB_TOKEN_FILE
  . "$PROJ/shell_utils.sh" >/dev/null 2>&1
  echo "url=$(infra_remote_url)"
)"
if echo "$outJ2" | grep -qx "url=git@github.com:luthersystems-infra-test/abcd1234-infra.git"; then
  pass "J: without a token, the SSH URL stays"
else
  fail "J: without a token, expected the SSH URL. Output: $outJ2"
fi

PROJ="$(make_project projJ3)"
set_repo_clone_url "$PROJ" "git@github.com:luthersystems-infra-test/abcd1234-infra.git"
outJ3="$(
  export MARS_PROJECT_ROOT="$PROJ"
  unset GITHUB_GIT_TOKEN_FILE GITHUB_TOKEN_FILE
  . "$PROJ/shell_utils.sh" >/dev/null 2>&1
  cloneInfraRepo 2>&1; echo "rc=$?"
)"
if echo "$outJ3" | grep -qF "No GitHub token or deploy key" && echo "$outJ3" | grep -qx "rc=0" && [[ ! -e "$PROJ/.git" ]]; then
  pass "J: with no token and no deploy key, the SSH clone is skipped (non-fatal)"
else
  fail "J: expected a skipped clone. Output: $outJ3"
fi

# =============================================================================
echo ""
echo "=== Case K: #160 — a TRACKED credentials file is untracked, not pushed ==="
# =============================================================================
# The real leak: the template tracked tf/auto-vars/common.auto.tfvars.json as a
# `{}` seed. .gitignore does not stop git from committing a file it already
# tracks, so after ui-core wrote cloud credentials into it, `git add -A`
# committed them and the push sent them to the -infra repo. Case G passes even
# with that bug, because its fixture never tracks the file. Here the -infra repo
# already tracks the seed (as every repo built from the old template does), and
# the deploy writes a fake key into it.
PROJ="$(make_project projK)"
BARE="$(fresh_bare)"
init_project_git "$PROJ"
echo '{}' > "$PROJ/tf/auto-vars/common.auto.tfvars.json"
git -C "$PROJ" add -f tf/auto-vars/common.auto.tfvars.json
git -C "$PROJ" commit -q -m "old template: seed tracked"
git -C "$PROJ" push -q "file://$BARE" main
# Deploy time: credentials and the repo URL land in the tracked file.
jq -n --arg url "file://$BARE" \
  '{"cloud_provider":"aws","repo_clone_ssh_url":$url,"aws_secret_access_key":"FAKE-SECRET-K"}' \
  > "$PROJ/tf/auto-vars/common.auto.tfvars.json"

set +e
outK="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcK=$?
set -e

[[ "$rcK" -eq 0 ]] && pass "K: apply exits 0" || fail "K: expected exit 0, got $rcK. Output: $outK"

pushed_tree="$(git -C "$BARE" ls-tree -r --name-only main 2>/dev/null || echo "")"
if echo "$pushed_tree" | grep -qx "shell_utils.sh"; then
  pass "K: the deploy pushed the stack (the next checks are not vacuous)"
else
  fail "K: expected shell_utils.sh in the pushed tree. Output: $outK"
fi
if echo "$pushed_tree" | grep -qx "tf/auto-vars/common.auto.tfvars.json"; then
  fail "K: the tracked common.auto.tfvars.json is still in the pushed tree (#160 leak)"
else
  pass "K: common.auto.tfvars.json is no longer in the -infra repo tree"
fi
# Capture first: `git log | grep -q` under pipefail reads as "no match" when
# grep exits early and git dies of SIGPIPE.
pushed_history="$(git -C "$BARE" log -p --all)"
if grep -qF "FAKE-SECRET-K" <<<"$pushed_history"; then
  fail "K: the deploy-time secret reached the -infra repo history (#160 leak)"
else
  pass "K: the deploy-time secret is in no pushed commit"
fi
if grep -qF "FAKE-SECRET-K" "$PROJ/tf/auto-vars/common.auto.tfvars.json"; then
  pass "K: the file stays on disk for later steps (only the git tracking goes)"
else
  fail "K: the credentials file was removed from disk"
fi

# =============================================================================
echo ""
echo "=== Case L: the template tracks no file that its .gitignore ignores ==="
# =============================================================================
# Guards the whole class behind Case K: a tracked file that .gitignore ignores
# is committed anyway by `git add -A` in every project tree cloned from this
# repo. Fix a hit with `git rm --cached <path>`, or add a `!` carve-out to
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
echo "=== Case M: #160 Phase 5 — a re-deploy after a history squash still pushes ==="
# =============================================================================
# ui-core squashes the project tree's git history on every dispatch, so on the
# second deploy the local history and infra/main share no commit. The old
# `git merge infra/main` failed with "refusing to merge unrelated histories",
# the push was rejected non-fast-forward, and every push after a project's
# first was lost (warn-only). The snapshot re-parent fixes it: the deployed
# worktree is committed on top of infra/main and pushed fast-forward.
PROJ="$(make_project projM)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"

set +e
run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift >/dev/null
first_rcM=$?
set -e
first_headM="$(git -C "$BARE" rev-parse --verify -q refs/heads/main || echo "")"

# infra/main gets a file the deploy tree does not have, and an edit to a file
# the deploy has. The -infra repo is an output copy of the deployed state, so
# the snapshot drops the first and takes the deployed version of the second.
# It also gets an executable script that the deploy tree holds as 0644 (an
# archive or mount can lose the bit): the snapshot keeps infra/main's
# 100755, because only a new file's mode is read from disk.
stale_clone="$WORKDIR/projM-stale"
git clone -q -b main "file://$BARE" "$stale_clone"
echo "infra-only file" > "$stale_clone/stale-infra-only.txt"
echo "# infra-only edit" >> "$stale_clone/shell_utils.sh"
printf '#!/bin/sh\n' > "$stale_clone/existing-hook.sh"
/bin/chmod 0755 "$stale_clone/existing-hook.sh"
git -C "$stale_clone" add stale-infra-only.txt shell_utils.sh existing-hook.sh
git -C "$stale_clone" -c user.email=t@l -c user.name=T commit -q -m "infra-only edit"
git -C "$stale_clone" push -q origin main
stale_headM="$(git -C "$BARE" rev-parse refs/heads/main)"
# A tag named main on another commit: fetching "main" would resolve to the
# tag (refs/tags wins over refs/heads), the snapshot would sit on the wrong
# base, and the push would be rejected. fetchInfraMain asks for
# refs/heads/main.
git -C "$stale_clone" -c user.email=t@l -c user.name=T commit -q --allow-empty -m "tagged, not on main"
git -C "$stale_clone" tag main HEAD
git -C "$stale_clone" push -q origin refs/tags/main

# The ui-core squash: a new root commit with no shared history. Like the
# trees of projects built from the old template, it tracks the credentials
# file, so the snapshot must still untrack what .gitignore ignores.
rm -rf "$PROJ/.git"
init_project_git "$PROJ"
git -C "$PROJ" add -A
git -C "$PROJ" add -f tf/auto-vars/common.auto.tfvars.json
git -C "$PROJ" commit -q -m "ui-core: squashed project history"
jq -n --arg url "file://$BARE" \
  '{"cloud_provider":"aws","repo_clone_ssh_url":$url,"aws_secret_access_key":"FAKE-SECRET-M"}' \
  > "$PROJ/tf/auto-vars/common.auto.tfvars.json"
echo "third-deploy-change" > "$PROJ/tf/custom-stack-provision/main.tf"
printf '#!/bin/sh\n' > "$PROJ/existing-hook.sh"
/bin/chmod 0644 "$PROJ/existing-hook.sh"
# A new executable script: configure_git sets core.fileMode=false, and the
# snapshot must still record it as 100755. /bin/chmod: chmod is mocked.
printf '#!/bin/sh\necho hi\n' > "$PROJ/tf/custom-stack-provision/new-hook.sh"
/bin/chmod 0755 "$PROJ/tf/custom-stack-provision/new-hook.sh"
git -C "$PROJ" fetch -q "file://$BARE" refs/heads/main
if git -C "$PROJ" merge-base HEAD FETCH_HEAD >/dev/null 2>&1; then
  fail "M: fixture error — the squashed history shares a commit with infra/main"
else
  pass "M: fixture — the squashed history and infra/main are unrelated"
fi

set +e
outM="$(run_apply "$PROJ" apply-with-outputs.sh custom-stack-provision --check-drift)"
rcM=$?
set -e
headM="$(git -C "$BARE" rev-parse refs/heads/main)"

if [[ "$first_rcM" -eq 0 && "$rcM" -eq 0 && -n "$first_headM" ]]; then
  pass "M: both applies exit 0 and the first one pushed"
else
  fail "M: first=$first_rcM second=$rcM first_head=$first_headM. Output: $outM"
fi
if [[ "$headM" != "$stale_headM" ]] && git -C "$BARE" merge-base --is-ancestor "$stale_headM" "$headM"; then
  pass "M: the second push landed as a fast-forward of infra/main"
else
  fail "M: infra/main did not fast-forward ($stale_headM → $headM). Output: $outM"
fi
if [[ "$(git -C "$BARE" show refs/heads/main:tf/custom-stack-provision/main.tf 2>/dev/null)" == "third-deploy-change" ]]; then
  pass "M: the pushed snapshot carries the deployed change"
else
  fail "M: the pushed main.tf is not the deployed one"
fi
if git -C "$BARE" cat-file -e refs/heads/main:stale-infra-only.txt 2>/dev/null; then
  fail "M: a file only on infra/main survived — the snapshot is not the deployed tree"
else
  pass "M: the snapshot is the deployed tree (the infra-only file is gone)"
fi
if git -C "$BARE" show refs/heads/main:shell_utils.sh | grep -qF "# infra-only edit"; then
  fail "M: a file in both places kept the infra/main version, not the deployed one"
else
  pass "M: a file in both places takes the deployed version"
fi
if [[ "$(git -C "$BARE" ls-tree refs/heads/main tf/custom-stack-provision/new-hook.sh | cut -d' ' -f1)" == "100755" ]]; then
  pass "M: a new 0755 script is pushed as 100755"
else
  fail "M: the new script lost its exec bit: $(git -C "$BARE" ls-tree refs/heads/main tf/custom-stack-provision/new-hook.sh)"
fi
if [[ "$(git -C "$BARE" ls-tree refs/heads/main existing-hook.sh | cut -d' ' -f1)" == "100755" ]]; then
  pass "M: an existing 100755 file that is 0644 on disk stays 100755"
else
  fail "M: the disk mode replaced infra/main's: $(git -C "$BARE" ls-tree refs/heads/main existing-hook.sh)"
fi
if [[ "$(git -C "$BARE" rev-list --count "$stale_headM..refs/heads/main")" -eq 1 ]]; then
  pass "M: the snapshot is one commit on top of infra/main"
else
  fail "M: expected exactly one new commit on infra/main"
fi
# The #160 canary on the snapshot push.
pushed_tree="$(git -C "$BARE" ls-tree -r --name-only refs/heads/main 2>/dev/null || echo "")"
if echo "$pushed_tree" | grep -qE '\.auto\.tfvars\.json$|^outputs/|^secrets/|\.tfplan$'; then
  fail "M: a tfvars, outputs, secrets or plan file rode the snapshot push (#160). Tree: $pushed_tree. Output: $outM"
else
  pass "M: no tfvars, outputs, secrets or plan file in the snapshot"
fi
pushed_history="$(git -C "$BARE" log -p --all)"
if grep -qF "FAKE-SECRET-M" <<<"$pushed_history"; then
  fail "M: the deploy-time secret reached the -infra repo history (#160 leak)"
else
  pass "M: the deploy-time secret is in no pushed commit"
fi
if grep -qF "FAKE-SECRET-M" "$PROJ/tf/auto-vars/common.auto.tfvars.json"; then
  pass "M: the credentials file stays on disk"
else
  fail "M: the credentials file was removed from disk"
fi

# =============================================================================
echo ""
echo "=== Case N: simple-mode apply (apply.sh) after a history squash ==="
# =============================================================================
# apply-with-outputs.sh without --check-drift runs apply.sh. apply.sh merged
# infra/main under set -e before Terraform ran, and the merge always fails on
# ui-core's squashed history, so the apply aborted before it applied. Now it
# applies first and pushes a snapshot, like persistInfraRepo.
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
# gitMergeOriginMain does.
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

# =============================================================================
echo ""
echo "=== Case R: gitCommit (commit.sh, destroy.sh) uses the same staging rules ==="
# =============================================================================
PROJ="$(make_project projR)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
mkdir -p "$PROJ/.github"
echo "version: 2" > "$PROJ/.github/dependabot.yml"
printf '#!/bin/sh\n' > "$PROJ/r-new-hook.sh"
/bin/chmod 0755 "$PROJ/r-new-hook.sh"
outR="$(
  cd "$PROJ" && MARS_PROJECT_ROOT="$PROJ" HOME="$WORKDIR" bash -c '
    . ./shell_utils.sh
    gitCommit "commit.sh run"
  ' 2>&1
)"
# Only the snapshot drops the template-only paths (Case O); gitCommit keeps
# them, so a tree that tracks the template commits no deletion.
if git -C "$PROJ" cat-file -e HEAD:.github/dependabot.yml 2>/dev/null; then
  pass "R: gitCommit keeps .github/dependabot.yml"
else
  fail "R: gitCommit dropped .github/dependabot.yml. Output: $outR"
fi
if [[ "$(git -C "$PROJ" ls-tree HEAD r-new-hook.sh | cut -d' ' -f1)" == "100755" ]]; then
  pass "R: gitCommit records a new 0755 script as 100755"
else
  fail "R: gitCommit lost the new script's exec bit: $(git -C "$PROJ" ls-tree HEAD r-new-hook.sh)"
fi

# Mode rule: +x only for NEW paths that are executable on disk and start
# with "#!". Existing paths keep their index mode, so a 0777 extraction
# churns no modes; the cost is that a 644->755 change of an existing script
# is not recorded.
PROJ="$(make_project projR2)"
init_project_git "$PROJ"
printf '#!/bin/sh\n' > "$PROJ/was-644.sh"
printf '#!/bin/sh\n' > "$PROJ/was-755.sh"
echo 'resource "x" "y" {}' > "$PROJ/data.tf"
echo '{}' > "$PROJ/data.json"
git -C "$PROJ" add was-644.sh was-755.sh data.tf data.json
git -C "$PROJ" update-index --chmod=+x was-755.sh
git -C "$PROJ" commit -q -m base
/bin/chmod 0755 "$PROJ/was-644.sh"
/bin/chmod 0644 "$PROJ/was-755.sh"
/bin/chmod 0777 "$PROJ/data.tf" "$PROJ/data.json"
echo "change" >> "$PROJ/data.json"
printf '#!/bin/sh\n' > "$PROJ/new-script.sh"
echo 'x = 1' > "$PROJ/new-data.tf"
/bin/chmod 0755 "$PROJ/new-script.sh"
/bin/chmod 0777 "$PROJ/new-data.tf"
outR2="$(
  cd "$PROJ" && MARS_PROJECT_ROOT="$PROJ" HOME="$WORKDIR" bash -c '
    . ./shell_utils.sh
    gitCommit "commit.sh run"
  ' 2>&1
)"
modeR2() { git -C "$PROJ" ls-tree HEAD "$1" | cut -d' ' -f1; }
if [[ "$(modeR2 new-script.sh)" == "100755" ]]; then
  pass "R: a new 0755 script is recorded as 100755"
else
  fail "R: new-script.sh is $(modeR2 new-script.sh). Output: $outR2"
fi
if [[ "$(modeR2 was-644.sh)" == "100644" ]]; then
  pass "R: an existing path keeps its index mode (100644) whatever the disk says"
else
  fail "R: was-644.sh changed to $(modeR2 was-644.sh)"
fi
if [[ "$(modeR2 data.tf)" == "100644" && "$(modeR2 data.json)" == "100644" &&
  "$(modeR2 new-data.tf)" == "100644" ]]; then
  pass "R: 0777 data files (.tf, .json; new and existing) stay 100644"
else
  fail "R: data files got the exec bit: data.tf=$(modeR2 data.tf) data.json=$(modeR2 data.json) new-data.tf=$(modeR2 new-data.tf)"
fi
if [[ "$(modeR2 was-755.sh)" == "100755" ]]; then
  pass "R: an existing 100755 script that is 0644 on disk stays 100755"
else
  fail "R: was-755.sh lost its exec bit: $(modeR2 was-755.sh)"
fi

# =============================================================================
echo ""
echo "=== Case S: gitMergeInfraMain skips what it cannot or must not merge ==="
# =============================================================================
# merge_infra <proj> [PATH prefix] — run gitMergeInfraMain; prints output,
# then "rc=<n>" on the last line.
merge_infra() {
  local proj="$1" pre="${2:-}"
  (
    cd "$proj" && MARS_PROJECT_ROOT="$proj" HOME="$WORKDIR" PATH="${pre:+$pre:}$PATH" bash -c '
      . ./shell_utils.sh
      rc=0; gitMergeInfraMain || rc=$?; echo "rc=$rc"
    ' 2>&1
  )
}
# seed_infra <bare> — push a one-commit main with infra.txt; prints its sha.
seed_infra() {
  local src="$WORKDIR/seed-$RANDOM$RANDOM"
  git init -q -b main "$src"
  echo "infra" > "$src/infra.txt"
  git -C "$src" add -A
  git -C "$src" -c user.email=t@l -c user.name=T commit -q -m "infra base"
  git -C "$src" push -q "file://$1" main
  git -C "$src" rev-parse HEAD
}

# 1. An unborn HEAD (cloned while infra was empty): nothing to merge.
PROJ="$(make_project projS1)"
BARE="$(fresh_bare)"
set_repo_clone_url "$PROJ" "file://$BARE"
init_project_git "$PROJ"
git -C "$PROJ" remote add infra "file://$BARE"
seed_infra "$BARE" >/dev/null
outS1="$(merge_infra "$PROJ")"
if [[ "$(tail -1 <<<"$outS1")" == "rc=2" ]] && ! git -C "$PROJ" rev-parse -q --verify HEAD >/dev/null &&
  [[ ! -e "$PROJ/.git/MERGE_HEAD" ]]; then
  pass "S: an unborn HEAD skips the merge with rc 2"
else
  fail "S: unborn HEAD: $outS1"
fi

# 2. Uncommitted local changes that do not overlap infra/main's merge: git
# merges as usual and keeps them (it refuses only overlapping changes, which
# fails the merge, rc 1).
BARE="$(fresh_bare)"
seed_infra "$BARE" >/dev/null
PROJ="$WORKDIR/projS2"
git clone -q -b main "file://$BARE" "$PROJ"
git -C "$PROJ" remote add infra "file://$BARE"
cp "$REPO_ROOT/shell_utils.sh" "$PROJ/shell_utils.sh"
mate="$WORKDIR/projS2-mate"
git clone -q -b main "file://$BARE" "$mate"
echo "mate" > "$mate/mate.txt"
git -C "$mate" add -A
git -C "$mate" -c user.email=t@l -c user.name=T commit -q -m "mate edit"
git -C "$mate" push -q origin main
echo "archive" > "$PROJ/infra.txt"
headS2="$(git -C "$PROJ" rev-parse HEAD)"
outS2="$(merge_infra "$PROJ")"
if [[ "$(tail -1 <<<"$outS2")" == "rc=0" ]] && [[ -f "$PROJ/mate.txt" ]] &&
  [[ "$(git -C "$PROJ" rev-parse HEAD)" != "$headS2" ]] && [[ "$(cat "$PROJ/infra.txt")" == "archive" ]]; then
  pass "S: uncommitted non-overlapping changes merge as usual and stay on disk"
else
  fail "S: dirty worktree: $outS2"
fi

# 3. A shallow clone whose merge base is below the shallow cut: deepen, then
# merge (rc 0), not "unrelated".
BARE="$(fresh_bare)"
src="$WORKDIR/projS3-src"
git init -q -b main "$src"
for c in c1 c2 c3; do
  echo "$c" > "$src/$c.txt"; git -C "$src" add -A
  git -C "$src" -c user.email=t@l -c user.name=T commit -q -m "$c"
done
git -C "$src" push -q "file://$BARE" main
git -C "$src" push -q "file://$BARE" main:refs/heads/keep-c3
PROJ="$WORKDIR/projS3"
git clone -q --depth 1 -b main "file://$BARE" "$PROJ"
git -C "$PROJ" config user.email t@l
git -C "$PROJ" config user.name T
git -C "$PROJ" remote add infra "file://$BARE"
cp "$REPO_ROOT/shell_utils.sh" "$PROJ/shell_utils.sh"
echo "shell_utils.sh" >> "$PROJ/.git/info/exclude"
# infra/main moves to a branch off c2, so the merge base (c2) is below the cut.
git -C "$src" checkout -q -b side HEAD~1
echo "c5" > "$src/c5.txt"; git -C "$src" add -A
git -C "$src" -c user.email=t@l -c user.name=T commit -q -m c5
git -C "$src" push -q -f "file://$BARE" side:main
outS3="$(merge_infra "$PROJ")"
if [[ "$(tail -1 <<<"$outS3")" == "rc=0" ]] && [[ -f "$PROJ/c5.txt" ]] &&
  [[ "$(git -C "$PROJ" rev-parse --is-shallow-repository)" == "false" ]]; then
  pass "S: a shallow clone is deepened, then merged"
else
  fail "S: shallow clone: $outS3"
fi

# 4. merge-base failing for any reason other than "no common ancestor"
# (exit 1) is an error (rc 1), not "unrelated".
BARE="$(fresh_bare)"
seed_infra "$BARE" >/dev/null
PROJ="$WORKDIR/projS4"
git clone -q -b main "file://$BARE" "$PROJ"
git -C "$PROJ" remote add infra "file://$BARE"
cp "$REPO_ROOT/shell_utils.sh" "$PROJ/shell_utils.sh"
echo "shell_utils.sh" >> "$PROJ/.git/info/exclude"
shim="$WORKDIR/git-shim"
mkdir -p "$shim"
cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == merge-base ]]; then exit 128; fi
exec "$(command -v git)" "\$@"
SHIM
/bin/chmod +x "$shim/git"
outS4="$(merge_infra "$PROJ" "$shim")"
if [[ "$(tail -1 <<<"$outS4")" == "rc=1" ]]; then
  pass "S: a merge-base error (not exit 1) returns rc 1"
else
  fail "S: merge-base error: $outS4"
fi

# 5. A failed deepen is a warning, not an error: merge-base runs as before
# (here it finds no common ancestor below the cut, so rc 2).
BARE="$(fresh_bare)"
src="$WORKDIR/projS5-src"
git init -q -b main "$src"
for c in c1 c2 c3; do
  echo "$c" > "$src/$c.txt"; git -C "$src" add -A
  git -C "$src" -c user.email=t@l -c user.name=T commit -q -m "$c"
done
git -C "$src" push -q "file://$BARE" main
git -C "$src" push -q "file://$BARE" main:refs/heads/keep-c3
PROJ="$WORKDIR/projS5"
git clone -q --depth 1 -b main "file://$BARE" "$PROJ"
git -C "$PROJ" config user.email t@l
git -C "$PROJ" config user.name T
git -C "$PROJ" remote add infra "file://$BARE"
cp "$REPO_ROOT/shell_utils.sh" "$PROJ/shell_utils.sh"
echo "shell_utils.sh" >> "$PROJ/.git/info/exclude"
git -C "$src" checkout -q -b side HEAD~1
echo "c5" > "$src/c5.txt"; git -C "$src" add -A
git -C "$src" -c user.email=t@l -c user.name=T commit -q -m c5
git -C "$src" push -q -f "file://$BARE" side:main
shim5="$WORKDIR/git-shim-unshallow"
mkdir -p "$shim5"
cat > "$shim5/git" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == fetch && " \$* " == *" --unshallow "* ]]; then exit 1; fi
exec "$(command -v git)" "\$@"
SHIM
/bin/chmod +x "$shim5/git"
outS5="$(merge_infra "$PROJ" "$shim5")"
if [[ "$(tail -1 <<<"$outS5")" == "rc=2" ]] && grep -qi "deepen" <<<"$outS5"; then
  pass "S: a failed deepen warns and falls through to merge-base"
else
  fail "S: failed deepen: $outS5"
fi

# --- Summary -----------------------------------------------------------------
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
