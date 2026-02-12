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
  git init -q
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

# --- Collaborator invite tests -------------------------------------------------------------------
echo ""
echo "Collaborator invite tests:"

# 9. Invite skipped when GITHUB_USERNAME is empty (archive mode succeeds without error)
rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "existing-customer" > "$TARGET/__customer_foo.tf"

invite_output="$(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$ARCHIVE_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  export GITHUB_USERNAME=""
  bash prepare-custom-stack.sh 2>&1
)"
if [[ $? -eq 0 ]] && ! echo "$invite_output" | grep -qi "inviting.*collaborator"; then
  pass "collaborator invite skipped when GITHUB_USERNAME is empty"
else
  fail "collaborator invite should be skipped when GITHUB_USERNAME is empty"
fi

# 10. Invite attempted when GITHUB_USERNAME is set (curl stub records call)
CURL_STUB_DIR="$WORKDIR/curl-stub"
CURL_LOG="$WORKDIR/curl-stub-log"
mkdir -p "$CURL_STUB_DIR"
cat > "$CURL_STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${CURL_LOG}"
# Simulate 201 Created
echo "201"
STUB
chmod +x "$CURL_STUB_DIR/curl"

rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "existing-customer" > "$TARGET/__customer_foo.tf"

# Write repo_org and repo_name into auto-vars so getTfVar can find them
cat > "$PROJECT/tf/auto-vars/git_repo.auto.tfvars.json" <<'EOF'
{"repo_org": "testorg", "repo_name": "testrepo"}
EOF

rm -f "$CURL_LOG"
invite_output="$(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$ARCHIVE_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  export GITHUB_USERNAME="testuser"
  export GITHUB_TOKEN="fake-token-123"
  export CURL_LOG="$CURL_LOG"
  export PATH="$CURL_STUB_DIR:$PATH"
  bash prepare-custom-stack.sh 2>&1
)"
if [[ -f "$CURL_LOG" ]] && grep -q "repos/testorg/testrepo/collaborators/testuser" "$CURL_LOG"; then
  pass "collaborator invite API called with correct URL"
else
  fail "collaborator invite API not called correctly (log: $(cat "$CURL_LOG" 2>/dev/null || echo 'missing'))"
fi

# Clean up auto-vars for next tests
rm -f "$PROJECT/tf/auto-vars/git_repo.auto.tfvars.json"

# 11. Invite skipped gracefully when GITHUB_TOKEN is missing
rm -rf "$TARGET"
mkdir -p "$TARGET"
echo "existing-backend" > "$TARGET/backend.tf"
echo "existing-providers" > "$TARGET/providers.tf"
echo "existing-customer" > "$TARGET/__customer_foo.tf"

invite_output="$(
  cd "$PROJECT"
  export MARS_PROJECT_ROOT="$PROJECT"
  export CUSTOM_ARCHIVE_TGZ="$ARCHIVE_B64"
  export CUSTOM_REPO_URL=""
  export CUSTOM_REF=""
  export CUSTOM_AUTH=""
  export GITHUB_USERNAME="testuser"
  unset GITHUB_TOKEN
  bash prepare-custom-stack.sh 2>&1
)"
if [[ $? -eq 0 ]] && echo "$invite_output" | grep -q "GITHUB_TOKEN not set"; then
  pass "collaborator invite skipped with warning when GITHUB_TOKEN missing"
else
  fail "collaborator invite should warn and skip when GITHUB_TOKEN is missing (output: $invite_output)"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
