#!/usr/bin/env bash
set -euo pipefail

# Integration tests for prepare-custom-stack.sh (archive mode + repo mode).
# Tests:
#   1. Archive: .terraform-version from source archive is copied to target
#   2. Archive: preserved files (backend.tf, providers.tf, __customer_*.tf) survive rsync
#   3. Archive: non-preserved files replaced from archive
#   4. Repo: .terraform-version from cloned repo root is copied to target
#   5. Repo: preserved files survive rsync
#   6. Repo: non-preserved files replaced from repo, stale files removed
#   7. Repo: error when both archive and repo URL are empty
#   8. Dotglob: dotfile preserve patterns restored correctly
#   9. Re-deploy: .git/ created from infra repo when repo_clone_ssh_url is set
#  10. Re-deploy: gitCommit succeeds after ensure_git_from_infra runs
#  11. Re-deploy: cached .git fetches and resets to latest
#  12. Re-deploy: no-op when repo_clone_ssh_url is empty
#  13. Re-deploy: graceful degradation when clone fails (nonexistent repo)
#  14. Repo mode with commit SHA ref (token auth)
#  15. Repo mode with commit SHA ref (SSH auth)
#  16. Re-deploy: cached repo respects CUSTOM_REF
#  17. Re-deploy: graceful fallback when ref doesn't exist
#  18. Re-deploy: graceful skip when cached .git has no remotes
#  19. Re-deploy: graceful fallback when fetch fails on cached repo
#  20. Re-deploy: workflow overlay files (auto-vars, env.yaml) survive git reset
# Note: Collaborator invites are now handled declaratively via Terraform
# (github_repository_collaborator resource in tf/cloud-provision/repo.tf).

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
PROJECT="$WORKDIR/project"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- macOS compat: wrap tar to strip --warning flag (BSD tar doesn't support it) ---
if ! tar --warning=no-unknown-keyword --help &>/dev/null; then
  TAR_WRAPPER="$WORKDIR/bin"
  mkdir -p "$TAR_WRAPPER"
  cat > "$TAR_WRAPPER/tar" <<'WRAPPER'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  [[ "$arg" == --warning=* ]] && continue
  args+=("$arg")
done
exec /usr/bin/tar "${args[@]}"
WRAPPER
  chmod +x "$TAR_WRAPPER/tar"
  export PATH="$TAR_WRAPPER:$PATH"
fi

# --- Set up a fake project tree that satisfies shell_utils.sh / the script ---
mkdir -p "$PROJECT/tf/auto-vars"
mkdir -p "$PROJECT/tf/custom-stack-provision"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"

# Minimal env.yaml so shell_utils.sh doesn't error
cat > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

# Empty auto-vars so getTfVar returns ""
echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

# Copy the real scripts
cp "$SCRIPT_DIR/shell_utils.sh" "$PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$PROJECT/prepare-custom-stack.sh"

# --- Pre-populate target with files that should be preserved ---
TARGET="$PROJECT/tf/custom-stack-provision"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "existing-customer" > "$TARGET/__customer_foo.tf"
echo "old-version" > "$TARGET/.terraform-version"
echo "should-be-replaced" > "$TARGET/main.tf"

# --- Build a source archive ---
ARCHIVE_DIR="$WORKDIR/archive-src"
mkdir -p "$ARCHIVE_DIR"
echo "new-main" > "$ARCHIVE_DIR/main.tf"
echo "new-variables" > "$ARCHIVE_DIR/variables.tf"
echo "1.8.0" > "$ARCHIVE_DIR/.terraform-version"

ARCHIVE_TGZ="$WORKDIR/payload.tgz"
tar -czf "$ARCHIVE_TGZ" -C "$ARCHIVE_DIR" .

ARCHIVE_B64="$(base64 < "$ARCHIVE_TGZ")"

# --- Run the script in archive mode ---
echo "Running prepare-custom-stack.sh (archive mode)..."
(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$ARCHIVE_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

echo ""
echo "Results:"

# --- Assertions ---

# 1. .terraform-version should come from the archive (value "1.8.0"), not the old one
if [[ -f "$TARGET/.terraform-version" ]]; then
  tv="$(cat "$TARGET/.terraform-version")"
  if [[ "$tv" == "1.8.0" ]]; then
    pass ".terraform-version copied from archive (got '1.8.0')"
  else
    fail ".terraform-version has wrong content: '$tv' (expected '1.8.0')"
  fi
else
  fail ".terraform-version missing from target"
fi

# 2. Preserved files should still exist with original content
if [[ -f "$TARGET/backend.tf" ]] && [[ "$(cat "$TARGET/backend.tf")" == "existing-backend" ]]; then
  pass "backend.tf preserved"
else
  fail "backend.tf not preserved (missing or content changed)"
fi

if [[ -f "$TARGET/providers.tf" ]] && [[ "$(cat "$TARGET/providers.tf")" == "existing-providers" ]]; then
  pass "providers.tf preserved"
else
  fail "providers.tf not preserved (missing or content changed)"
fi

if [[ -f "$TARGET/__customer_foo.tf" ]] && [[ "$(cat "$TARGET/__customer_foo.tf")" == "existing-customer" ]]; then
  pass "__customer_foo.tf preserved"
else
  fail "__customer_foo.tf not preserved (missing or content changed)"
fi

# 3. Non-preserved files should come from the archive
if [[ -f "$TARGET/main.tf" ]] && [[ "$(cat "$TARGET/main.tf")" == "new-main" ]]; then
  pass "main.tf replaced from archive"
else
  fail "main.tf not replaced from archive"
fi

if [[ -f "$TARGET/variables.tf" ]] && [[ "$(cat "$TARGET/variables.tf")" == "new-variables" ]]; then
  pass "variables.tf copied from archive"
else
  fail "variables.tf not copied from archive"
fi

# --- Repo-mode test ---
echo ""
echo "Setting up repo-mode test..."

# Build a local bare git repo to act as the "custom repo"
REPO_SRC="$WORKDIR/repo-src"
REPO_BARE="$WORKDIR/repo-bare.git"
mkdir -p "$REPO_SRC"
echo "repo-main" > "$REPO_SRC/main.tf"
echo "repo-vars" > "$REPO_SRC/variables.tf"
echo "1.9.0" > "$REPO_SRC/.terraform-version"
(
  cd "$REPO_SRC"
  git init -q -b main
  git add -A
  git commit -q -m "init"
)
git clone -q --bare "$REPO_SRC" "$REPO_BARE"

# Reset the project target directory cleanly for repo-mode run
rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "existing-customer" > "$TARGET/__customer_foo.tf"
echo "old-version" > "$TARGET/.terraform-version"
echo "should-be-replaced" > "$TARGET/main.tf"
echo "stale-content" > "$TARGET/stale-leftover.tf"

echo "Running prepare-custom-stack.sh (repo mode)..."
(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ=""
  # Use file:// protocol with token auth so git clone works locally
  export CUSTOM_REPO_URL="file://$REPO_BARE"
  export CUSTOM_REF="main"
  export CUSTOM_AUTH="token"
  export GITHUB_TOKEN="unused-local-clone"
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

echo ""
echo "Repo-mode results:"

# 4. .terraform-version should come from the repo (value "1.9.0")
if [[ -f "$TARGET/.terraform-version" ]]; then
  tv="$(cat "$TARGET/.terraform-version")"
  if [[ "$tv" == "1.9.0" ]]; then
    pass "repo mode: .terraform-version copied from repo (got '1.9.0')"
  else
    fail "repo mode: .terraform-version has wrong content: '$tv' (expected '1.9.0')"
  fi
else
  fail "repo mode: .terraform-version missing from target"
fi

# 5. Preserved files should still exist with original content
if [[ -f "$TARGET/backend.tf" ]] && [[ "$(cat "$TARGET/backend.tf")" == "existing-backend" ]]; then
  pass "repo mode: backend.tf preserved"
else
  fail "repo mode: backend.tf not preserved (missing or content changed)"
fi

if [[ -f "$TARGET/providers.tf" ]] && [[ "$(cat "$TARGET/providers.tf")" == "existing-providers" ]]; then
  pass "repo mode: providers.tf preserved"
else
  fail "repo mode: providers.tf not preserved (missing or content changed)"
fi

if [[ -f "$TARGET/__customer_foo.tf" ]] && [[ "$(cat "$TARGET/__customer_foo.tf")" == "existing-customer" ]]; then
  pass "repo mode: __customer_foo.tf preserved"
else
  fail "repo mode: __customer_foo.tf not preserved (missing or content changed)"
fi

# 6. Non-preserved files should come from the repo; stale files should be removed
if [[ -f "$TARGET/main.tf" ]] && [[ "$(cat "$TARGET/main.tf")" == "repo-main" ]]; then
  pass "repo mode: main.tf replaced from repo"
else
  fail "repo mode: main.tf not replaced from repo"
fi

if [[ -f "$TARGET/variables.tf" ]] && [[ "$(cat "$TARGET/variables.tf")" == "repo-vars" ]]; then
  pass "repo mode: variables.tf copied from repo"
else
  fail "repo mode: variables.tf not copied from repo"
fi

if [[ ! -f "$TARGET/stale-leftover.tf" ]]; then
  pass "repo mode: stale file removed by rsync --delete"
else
  fail "repo mode: stale file NOT removed (rsync --delete may be broken)"
fi

# --- Error-path test: missing both archive and repo URL ---
echo ""
echo "Error-path test:"
if err_output="$(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ=""
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh 2>&1
)"; then
  fail "expected exit code != 0 when both archive and repo URL are empty"
else
  if echo "$err_output" | grep -q "missing CUSTOM_REPO_URL"; then
    pass "error path: clear error message when both inputs are empty"
  else
    fail "error path: unexpected error output: $err_output"
  fi
fi

# 8. Dotglob test: create a scenario with a dotfile in preserve dir
#    We test this by manually simulating what the restore loop does
echo ""
echo "Dotglob unit test:"
dottest_dir="$(mktemp -d)"
echo "dotfile-content" > "$dottest_dir/.hidden-preserve"
echo "regular-content" > "$dottest_dir/regular-file"

restore_dir="$(mktemp -d)"
shopt -s dotglob nullglob
for f in "$dottest_dir"/*; do
  [[ -e "$f" ]] && cp -f "$f" "$restore_dir/"
done
shopt -u dotglob nullglob

if [[ -f "$restore_dir/.hidden-preserve" ]]; then
  pass "dotglob: hidden file matched by * glob"
else
  fail "dotglob: hidden file NOT matched by * glob"
fi
if [[ -f "$restore_dir/regular-file" ]]; then
  pass "dotglob: regular file matched by * glob"
else
  fail "dotglob: regular file NOT matched by * glob"
fi

rm -rf "$dottest_dir" "$restore_dir"

# --- Re-deploy git initialization tests ----------------------------------------------------------
echo ""
echo "Re-deploy git initialization tests..."

# Build a bare git repo to act as the "infra repo"
INFRA_SRC="$WORKDIR/infra-src"
INFRA_BARE="$WORKDIR/infra-bare.git"
mkdir -p "$INFRA_SRC"
echo "infra-readme" > "$INFRA_SRC/README.md"
(
  cd "$INFRA_SRC"
  git init -q -b main
  git add -A
  git commit -q -m "initial infra commit"
)
git clone -q --bare "$INFRA_SRC" "$INFRA_BARE"

# 9. Re-deploy with archive: .git/ is created when repo_clone_ssh_url is set and no .git exists
echo ""
echo "Test 9: Re-deploy archive creates .git/ from infra repo..."

# Set up a fresh project without .git
REDEPLOY_PROJECT="$WORKDIR/redeploy-project"
mkdir -p "$REDEPLOY_PROJECT/tf/auto-vars"
mkdir -p "$REDEPLOY_PROJECT/tf/custom-stack-provision"
mkdir -p "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

# Set repo_clone_ssh_url in auto-vars pointing to the bare repo
jq -n --arg url "file://$INFRA_BARE" '{"repo_clone_ssh_url": $url}' \
  > "$REDEPLOY_PROJECT/tf/auto-vars/common.auto.tfvars.json"

cp "$SCRIPT_DIR/shell_utils.sh" "$REDEPLOY_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$REDEPLOY_PROJECT/prepare-custom-stack.sh"

# Build a small archive for the custom stack
REDEPLOY_ARCHIVE_DIR="$WORKDIR/redeploy-archive"
mkdir -p "$REDEPLOY_ARCHIVE_DIR"
echo "redeploy-main" > "$REDEPLOY_ARCHIVE_DIR/main.tf"
REDEPLOY_TGZ="$WORKDIR/redeploy-payload.tgz"
tar -czf "$REDEPLOY_TGZ" -C "$REDEPLOY_ARCHIVE_DIR" .
REDEPLOY_B64="$(base64 < "$REDEPLOY_TGZ")"

(
  cd "$REDEPLOY_PROJECT"
  export MARS_PROJECT_ROOT="$REDEPLOY_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$REDEPLOY_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

if [[ -d "$REDEPLOY_PROJECT/.git" ]]; then
  pass "re-deploy: .git/ created from infra repo"
else
  fail "re-deploy: .git/ not created (ensure_git_from_infra did not run)"
fi

# Verify .git/ contains history from the infra repo (not just an empty git init)
if (cd "$REDEPLOY_PROJECT" && git log --oneline | grep -q "initial infra commit"); then
  pass "re-deploy: .git/ contains infra repo history"
else
  fail "re-deploy: .git/ does not contain infra repo history"
fi

# Verify infra remote URL points to the correct repo
expected_infra_url="file://$INFRA_BARE"
actual_infra_url="$(cd "$REDEPLOY_PROJECT" && git remote get-url infra 2>/dev/null || echo "")"
if [[ "$actual_infra_url" == "$expected_infra_url" ]]; then
  pass "re-deploy: infra remote URL matches expected"
else
  fail "re-deploy: infra remote URL is '$actual_infra_url' (expected '$expected_infra_url')"
fi

# 10. Re-deploy commit: gitCommit succeeds after ensure_git_from_infra runs
echo ""
echo "Test 10: Re-deploy gitCommit succeeds..."

# Source shell_utils and run gitCommit in the re-deploy project
(
  cd "$REDEPLOY_PROJECT"
  export MARS_PROJECT_ROOT="$REDEPLOY_PROJECT"
  . "$REDEPLOY_PROJECT/shell_utils.sh"
  gitCommit "test: re-deploy commit"
) 2>&1 | sed 's/^/  | /'

if (cd "$REDEPLOY_PROJECT" && git log --oneline -1 | grep -q "re-deploy commit"); then
  pass "re-deploy: gitCommit created a commit with correct message"
else
  fail "re-deploy: gitCommit did not create expected commit"
fi

# Verify committed tree contains custom stack files from the archive
if (cd "$REDEPLOY_PROJECT" && git show HEAD:tf/custom-stack-provision/main.tf | grep -q "redeploy-main"); then
  pass "re-deploy: commit includes custom stack files"
else
  fail "re-deploy: commit does not include custom stack files"
fi

# Verify working tree is clean after gitCommit
if (cd "$REDEPLOY_PROJECT" && git diff --quiet && git diff --cached --quiet); then
  pass "re-deploy: working tree is clean after gitCommit"
else
  fail "re-deploy: working tree still has uncommitted changes after gitCommit"
fi

# 11. Cached .git fetches and resets to latest
echo ""
echo "Test 11: Cached .git fetches and resets to latest..."

# Add a new commit to the bare infra repo so HEAD advances
(
  INFRA_WORK="$(mktemp -d)"
  git clone -q "$INFRA_BARE" "$INFRA_WORK/repo"
  cd "$INFRA_WORK/repo"
  echo "updated-readme" > README.md
  git add -A
  git commit -q -m "second infra commit"
  git push -q origin main
  rm -rf "$INFRA_WORK"
)

EXPECTED_HEAD="$(git -C "$INFRA_BARE" rev-parse HEAD)"
EXISTING_HEAD="$(cd "$REDEPLOY_PROJECT" && git rev-parse HEAD)"

# Hard precondition: bare repo must have advanced past the project's HEAD
if [[ "$EXISTING_HEAD" == "$EXPECTED_HEAD" ]]; then
  fail "re-deploy: TEST SETUP BROKEN - bare repo HEAD did not advance"
  echo "  SKIP: skipping dependent assertions" >&2
else
  (
    cd "$REDEPLOY_PROJECT"
    export MARS_PROJECT_ROOT="$REDEPLOY_PROJECT"
    export CUSTOM_ARCHIVE_TGZ="$REDEPLOY_B64"
    export CUSTOM_REPO_URL=""
    export CUSTOM_REF=""
    export CUSTOM_AUTH=""
    bash prepare-custom-stack.sh
  ) 2>&1 | sed 's/^/  | /'

  NEW_HEAD="$(cd "$REDEPLOY_PROJECT" && git rev-parse HEAD)"
  if [[ "$NEW_HEAD" == "$EXPECTED_HEAD" ]]; then
    pass "re-deploy: HEAD advanced to latest infra commit after fetch+reset"
  else
    fail "re-deploy: HEAD did not advance (expected $EXPECTED_HEAD, got $NEW_HEAD)"
  fi
fi

# 12. No-op when repo_clone_ssh_url is empty
echo ""
echo "Test 12: No-op when repo_clone_ssh_url is empty..."

NOREPO_PROJECT="$WORKDIR/norepo-project"
mkdir -p "$NOREPO_PROJECT/tf/auto-vars"
mkdir -p "$NOREPO_PROJECT/tf/custom-stack-provision"
mkdir -p "$NOREPO_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$NOREPO_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
echo '{}' > "$NOREPO_PROJECT/tf/auto-vars/common.auto.tfvars.json"

cp "$SCRIPT_DIR/shell_utils.sh" "$NOREPO_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$NOREPO_PROJECT/prepare-custom-stack.sh"

# Build archive
NOREPO_ARCHIVE_DIR="$WORKDIR/norepo-archive"
mkdir -p "$NOREPO_ARCHIVE_DIR"
echo "norepo-main" > "$NOREPO_ARCHIVE_DIR/main.tf"
NOREPO_TGZ="$WORKDIR/norepo-payload.tgz"
tar -czf "$NOREPO_TGZ" -C "$NOREPO_ARCHIVE_DIR" .
NOREPO_B64="$(base64 < "$NOREPO_TGZ")"

(
  cd "$NOREPO_PROJECT"
  export MARS_PROJECT_ROOT="$NOREPO_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$NOREPO_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

if [[ ! -d "$NOREPO_PROJECT/.git" ]]; then
  pass "re-deploy: no .git/ created when repo_clone_ssh_url is empty"
else
  fail "re-deploy: .git/ was created despite empty repo_clone_ssh_url"
fi

# 13. Graceful degradation when clone fails (nonexistent repo)
echo ""
echo "Test 13: Graceful degradation when infra clone fails..."

BADFAIL_PROJECT="$WORKDIR/badfail-project"
mkdir -p "$BADFAIL_PROJECT/tf/auto-vars"
mkdir -p "$BADFAIL_PROJECT/tf/custom-stack-provision"
mkdir -p "$BADFAIL_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$BADFAIL_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

# Point repo_clone_ssh_url to a nonexistent repo
jq -n '{"repo_clone_ssh_url": "file:///nonexistent/repo.git"}' \
  > "$BADFAIL_PROJECT/tf/auto-vars/common.auto.tfvars.json"

cp "$SCRIPT_DIR/shell_utils.sh" "$BADFAIL_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$BADFAIL_PROJECT/prepare-custom-stack.sh"

# Build archive
BADFAIL_ARCHIVE_DIR="$WORKDIR/badfail-archive"
mkdir -p "$BADFAIL_ARCHIVE_DIR"
echo "badfail-main" > "$BADFAIL_ARCHIVE_DIR/main.tf"
BADFAIL_TGZ="$WORKDIR/badfail-payload.tgz"
tar -czf "$BADFAIL_TGZ" -C "$BADFAIL_ARCHIVE_DIR" .
BADFAIL_B64="$(base64 < "$BADFAIL_TGZ")"

clone_fail_output="$(
  cd "$BADFAIL_PROJECT"
  export MARS_PROJECT_ROOT="$BADFAIL_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$BADFAIL_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh 2>&1
)"
clone_fail_rc=$?

if [[ $clone_fail_rc -eq 0 ]]; then
  pass "re-deploy: script exits 0 when infra clone fails (graceful)"
else
  fail "re-deploy: script crashed (exit $clone_fail_rc) when infra clone failed"
fi

if [[ ! -d "$BADFAIL_PROJECT/.git" ]]; then
  pass "re-deploy: no .git/ created when clone fails"
else
  fail "re-deploy: .git/ was created despite clone failure"
fi

if echo "$clone_fail_output" | grep -q "WARNING: failed to clone infra repo"; then
  pass "re-deploy: warning logged when clone fails"
else
  fail "re-deploy: expected warning log not found in output"
fi

# --- Test 14: Repo mode with commit SHA ref (token auth) ---
echo ""
echo "Test 14: Repo mode with commit SHA ref (token auth)..."

# Get the SHA of the commit in the bare repo we already created
SHA_REF="$(git -C "$REPO_BARE" rev-parse HEAD)"

# Reset the project target directory for this test
rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "old-version" > "$TARGET/.terraform-version"

(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ=""
  export CUSTOM_REPO_URL="file://$REPO_BARE"
  export CUSTOM_REF="$SHA_REF"
  export CUSTOM_AUTH="token"
  export GITHUB_TOKEN="unused-local-clone"
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

if [[ -f "$TARGET/main.tf" ]] && [[ "$(cat "$TARGET/main.tf")" == "repo-main" ]]; then
  pass "SHA ref (token): main.tf checked out from commit SHA"
else
  fail "SHA ref (token): main.tf not found or wrong content"
fi

if [[ -f "$TARGET/.terraform-version" ]] && [[ "$(cat "$TARGET/.terraform-version")" == "1.9.0" ]]; then
  pass "SHA ref (token): .terraform-version correct"
else
  fail "SHA ref (token): .terraform-version missing or wrong"
fi

if [[ -f "$TARGET/backend.tf" ]] && [[ "$(cat "$TARGET/backend.tf")" == "existing-backend" ]]; then
  pass "SHA ref (token): preserved files intact"
else
  fail "SHA ref (token): preserved files not intact"
fi

# --- Test 15: Repo mode with commit SHA ref (SSH auth) ---
echo ""
echo "Test 15: Repo mode with commit SHA ref (SSH auth)..."

# Reset the project target directory for this test
rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "old-version" > "$TARGET/.terraform-version"

(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ=""
  export CUSTOM_REPO_URL="file://$REPO_BARE"
  export CUSTOM_REF="$SHA_REF"
  export CUSTOM_AUTH="ssh"
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

if [[ -f "$TARGET/main.tf" ]] && [[ "$(cat "$TARGET/main.tf")" == "repo-main" ]]; then
  pass "SHA ref (ssh): main.tf checked out from commit SHA"
else
  fail "SHA ref (ssh): main.tf not found or wrong content"
fi

if [[ -f "$TARGET/.terraform-version" ]] && [[ "$(cat "$TARGET/.terraform-version")" == "1.9.0" ]]; then
  pass "SHA ref (ssh): .terraform-version correct"
else
  fail "SHA ref (ssh): .terraform-version missing or wrong"
fi

if [[ -f "$TARGET/backend.tf" ]] && [[ "$(cat "$TARGET/backend.tf")" == "existing-backend" ]]; then
  pass "SHA ref (ssh): preserved files intact"
else
  fail "SHA ref (ssh): preserved files not intact"
fi

# --- Test 16: Cached repo respects CUSTOM_REF ---
echo ""
echo "Test 16: Cached repo respects CUSTOM_REF..."

# Create a feature branch on the bare infra repo with a distinct file
(
  BRANCH_WORK="$(mktemp -d)"
  git clone -q "$INFRA_BARE" "$BRANCH_WORK/repo"
  cd "$BRANCH_WORK/repo"
  git checkout -q -b feature/test-branch
  echo "branch-only-content" > branch-marker.txt
  git add -A
  git commit -q -m "add branch marker"
  git push -q origin feature/test-branch
  rm -rf "$BRANCH_WORK"
)

# Restore project structure (git reset --hard in test 11 may have removed files)
mkdir -p "$REDEPLOY_PROJECT/tf/auto-vars"
mkdir -p "$REDEPLOY_PROJECT/tf/custom-stack-provision"
mkdir -p "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
jq -n --arg url "file://$INFRA_BARE" '{"repo_clone_ssh_url": $url}' \
  > "$REDEPLOY_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cp "$SCRIPT_DIR/shell_utils.sh" "$REDEPLOY_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$REDEPLOY_PROJECT/prepare-custom-stack.sh"

# Re-run prepare-custom-stack with CUSTOM_REF pointing to the feature branch
(
  cd "$REDEPLOY_PROJECT"
  export MARS_PROJECT_ROOT="$REDEPLOY_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$REDEPLOY_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF="feature/test-branch"
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

if [[ -f "$REDEPLOY_PROJECT/branch-marker.txt" ]] && [[ "$(cat "$REDEPLOY_PROJECT/branch-marker.txt")" == "branch-only-content" ]]; then
  pass "cached repo: CUSTOM_REF checked out feature branch content"
else
  fail "cached repo: branch-marker.txt not found or wrong content (CUSTOM_REF not respected)"
fi

EXPECTED_BRANCH_HEAD="$(git -C "$INFRA_BARE" rev-parse refs/heads/feature/test-branch)"
ACTUAL_HEAD="$(cd "$REDEPLOY_PROJECT" && git rev-parse HEAD)"
if [[ "$ACTUAL_HEAD" == "$EXPECTED_BRANCH_HEAD" ]]; then
  pass "cached repo: HEAD matches feature branch tip"
else
  fail "cached repo: HEAD is $ACTUAL_HEAD (expected $EXPECTED_BRANCH_HEAD)"
fi

# --- Test 17: Graceful fallback when ref doesn't exist ---
echo ""
echo "Test 17: Graceful fallback when ref doesn't exist..."

# Restore project structure
mkdir -p "$REDEPLOY_PROJECT/tf/auto-vars"
mkdir -p "$REDEPLOY_PROJECT/tf/custom-stack-provision"
mkdir -p "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$REDEPLOY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
jq -n --arg url "file://$INFRA_BARE" '{"repo_clone_ssh_url": $url}' \
  > "$REDEPLOY_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cp "$SCRIPT_DIR/shell_utils.sh" "$REDEPLOY_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$REDEPLOY_PROJECT/prepare-custom-stack.sh"

# Record HEAD before running with nonexistent ref
BEFORE_HEAD="$(cd "$REDEPLOY_PROJECT" && git rev-parse HEAD)"

fallback_output="$(
  cd "$REDEPLOY_PROJECT"
  export MARS_PROJECT_ROOT="$REDEPLOY_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$REDEPLOY_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF="nonexistent/branch-that-does-not-exist"
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh 2>&1
)"
fallback_rc=$?

if [[ $fallback_rc -eq 0 ]]; then
  pass "fallback: script exits 0 with nonexistent ref"
else
  fail "fallback: script exited $fallback_rc (expected 0)"
fi

if echo "$fallback_output" | grep -q "WARNING.*ref 'nonexistent/branch-that-does-not-exist' not found"; then
  pass "fallback: warning logged for nonexistent ref"
else
  fail "fallback: expected warning about ref not found in output"
fi

AFTER_HEAD="$(cd "$REDEPLOY_PROJECT" && git rev-parse HEAD)"
if [[ "$BEFORE_HEAD" == "$AFTER_HEAD" ]]; then
  pass "fallback: HEAD unchanged when ref doesn't exist"
else
  fail "fallback: HEAD changed unexpectedly (was $BEFORE_HEAD, now $AFTER_HEAD)"
fi

# --- Test 18: Graceful skip when cached .git has no remotes ---
echo ""
echo "Test 18: Graceful skip when cached .git has no remotes..."

NOREMOTE_PROJECT="$WORKDIR/noremote-project"
mkdir -p "$NOREMOTE_PROJECT/tf/auto-vars"
mkdir -p "$NOREMOTE_PROJECT/tf/custom-stack-provision"
mkdir -p "$NOREMOTE_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$NOREMOTE_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
echo '{}' > "$NOREMOTE_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cp "$SCRIPT_DIR/shell_utils.sh" "$NOREMOTE_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$NOREMOTE_PROJECT/prepare-custom-stack.sh"

# Initialize a .git with no remotes
(cd "$NOREMOTE_PROJECT" && git init -q -b main && git add -A && git commit -q -m "init")
(cd "$NOREMOTE_PROJECT" && git remote remove origin 2>/dev/null || true)

NOREMOTE_ARCHIVE_DIR="$WORKDIR/noremote-archive"
mkdir -p "$NOREMOTE_ARCHIVE_DIR"
echo "noremote-main" > "$NOREMOTE_ARCHIVE_DIR/main.tf"
NOREMOTE_TGZ="$WORKDIR/noremote-payload.tgz"
tar -czf "$NOREMOTE_TGZ" -C "$NOREMOTE_ARCHIVE_DIR" .
NOREMOTE_B64="$(base64 < "$NOREMOTE_TGZ")"

NOREMOTE_HEAD="$(cd "$NOREMOTE_PROJECT" && git rev-parse HEAD)"

noremote_output="$(
  cd "$NOREMOTE_PROJECT"
  export MARS_PROJECT_ROOT="$NOREMOTE_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$NOREMOTE_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh 2>&1
)"
noremote_rc=$?

if [[ $noremote_rc -eq 0 ]]; then
  pass "no-remote: script exits 0"
else
  fail "no-remote: script exited $noremote_rc (expected 0)"
fi

if echo "$noremote_output" | grep -q "WARNING.*no infra or origin remote"; then
  pass "no-remote: warning logged about missing remotes"
else
  fail "no-remote: expected 'no infra or origin remote' warning"
fi

NOREMOTE_AFTER="$(cd "$NOREMOTE_PROJECT" && git rev-parse HEAD)"
if [[ "$NOREMOTE_HEAD" == "$NOREMOTE_AFTER" ]]; then
  pass "no-remote: HEAD unchanged"
else
  fail "no-remote: HEAD changed unexpectedly"
fi

# --- Test 19: Graceful fallback when fetch fails on cached repo ---
echo ""
echo "Test 19: Graceful fallback when fetch fails on cached repo..."

FETCHFAIL_PROJECT="$WORKDIR/fetchfail-project"
mkdir -p "$FETCHFAIL_PROJECT/tf/auto-vars"
mkdir -p "$FETCHFAIL_PROJECT/tf/custom-stack-provision"
mkdir -p "$FETCHFAIL_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$FETCHFAIL_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
echo '{}' > "$FETCHFAIL_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cp "$SCRIPT_DIR/shell_utils.sh" "$FETCHFAIL_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$FETCHFAIL_PROJECT/prepare-custom-stack.sh"

# Initialize .git with a remote pointing to a dead URL
(cd "$FETCHFAIL_PROJECT" && git init -q -b main && git add -A && git commit -q -m "init")
(cd "$FETCHFAIL_PROJECT" && git remote remove origin 2>/dev/null || true)
(cd "$FETCHFAIL_PROJECT" && git remote add infra "file:///nonexistent/dead-repo.git")

FETCHFAIL_ARCHIVE_DIR="$WORKDIR/fetchfail-archive"
mkdir -p "$FETCHFAIL_ARCHIVE_DIR"
echo "fetchfail-main" > "$FETCHFAIL_ARCHIVE_DIR/main.tf"
FETCHFAIL_TGZ="$WORKDIR/fetchfail-payload.tgz"
tar -czf "$FETCHFAIL_TGZ" -C "$FETCHFAIL_ARCHIVE_DIR" .
FETCHFAIL_B64="$(base64 < "$FETCHFAIL_TGZ")"

FETCHFAIL_HEAD="$(cd "$FETCHFAIL_PROJECT" && git rev-parse HEAD)"

fetchfail_output="$(
  cd "$FETCHFAIL_PROJECT"
  export MARS_PROJECT_ROOT="$FETCHFAIL_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$FETCHFAIL_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh 2>&1
)"
fetchfail_rc=$?

if [[ $fetchfail_rc -eq 0 ]]; then
  pass "fetch-fail: script exits 0"
else
  fail "fetch-fail: script exited $fetchfail_rc (expected 0)"
fi

if echo "$fetchfail_output" | grep -q "WARNING.*git fetch failed"; then
  pass "fetch-fail: warning logged about fetch failure"
else
  fail "fetch-fail: expected 'git fetch failed' warning"
fi

FETCHFAIL_AFTER="$(cd "$FETCHFAIL_PROJECT" && git rev-parse HEAD)"
if [[ "$FETCHFAIL_HEAD" == "$FETCHFAIL_AFTER" ]]; then
  pass "fetch-fail: HEAD unchanged"
else
  fail "fetch-fail: HEAD changed unexpectedly"
fi

# --- Test 20: Workflow overlay files survive git reset ---
echo ""
echo "Test 20: Workflow overlay files survive git reset..."

# Set up a project with .git from infra, then write workflow-populated overlays
OVERLAY_PROJECT="$WORKDIR/overlay-project"
mkdir -p "$OVERLAY_PROJECT/tf/auto-vars"
mkdir -p "$OVERLAY_PROJECT/tf/custom-stack-provision"
mkdir -p "$OVERLAY_PROJECT/ansible/inventories/default/group_vars/all"
cat > "$OVERLAY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF
echo '{}' > "$OVERLAY_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cp "$SCRIPT_DIR/shell_utils.sh" "$OVERLAY_PROJECT/shell_utils.sh"
cp "$SCRIPT_DIR/prepare-custom-stack.sh" "$OVERLAY_PROJECT/prepare-custom-stack.sh"

# Clone infra repo to get .git, then commit everything so overlay
# modifications show up as dirty tracked files
(
  cd "$OVERLAY_PROJECT"
  tmp_clone="$(mktemp -d)"
  git clone -q "file://$INFRA_BARE" "$tmp_clone/repo"
  mv "$tmp_clone/repo/.git" "$OVERLAY_PROJECT/.git"
  rm -rf "$tmp_clone"
  git remote rename origin infra 2>/dev/null || true
  git add -A
  git commit -q -m "add project files"
)

# Simulate workflow writing real values into overlay files
jq -n '{"bootstrap_state_bucket": "my-real-bucket", "repo_clone_ssh_url": "file:///some/repo.git"}' \
  > "$OVERLAY_PROJECT/tf/auto-vars/common.auto.tfvars.json"
cat > "$OVERLAY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: production
cloud_provider: aws
region: us-east-1
EOF

OVERLAY_ARCHIVE_DIR="$WORKDIR/overlay-archive"
mkdir -p "$OVERLAY_ARCHIVE_DIR"
echo "overlay-main" > "$OVERLAY_ARCHIVE_DIR/main.tf"
OVERLAY_TGZ="$WORKDIR/overlay-payload.tgz"
tar -czf "$OVERLAY_TGZ" -C "$OVERLAY_ARCHIVE_DIR" .
OVERLAY_B64="$(base64 < "$OVERLAY_TGZ")"

# Run prepare-custom-stack — this will fetch + stash + reset + pop
(
  cd "$OVERLAY_PROJECT"
  export MARS_PROJECT_ROOT="$OVERLAY_PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$OVERLAY_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  bash prepare-custom-stack.sh
) 2>&1 | sed 's/^/  | /'

# Verify auto-vars survived the reset
if [[ -f "$OVERLAY_PROJECT/tf/auto-vars/common.auto.tfvars.json" ]]; then
  overlay_bucket="$(jq -r '.bootstrap_state_bucket // empty' "$OVERLAY_PROJECT/tf/auto-vars/common.auto.tfvars.json")"
  if [[ "$overlay_bucket" == "my-real-bucket" ]]; then
    pass "overlay: auto-vars preserved through git reset (bootstrap_state_bucket intact)"
  else
    fail "overlay: auto-vars reverted — bootstrap_state_bucket is '$overlay_bucket' (expected 'my-real-bucket')"
  fi
else
  fail "overlay: auto-vars file missing after reset"
fi

# Verify env.yaml survived the reset
if [[ -f "$OVERLAY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" ]]; then
  overlay_env="$(grep -c 'cloud_provider' "$OVERLAY_PROJECT/ansible/inventories/default/group_vars/all/env.yaml" || true)"
  if [[ "$overlay_env" -ge 1 ]]; then
    pass "overlay: env.yaml preserved through git reset (workflow values intact)"
  else
    fail "overlay: env.yaml reverted to placeholder"
  fi
else
  fail "overlay: env.yaml missing after reset"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
