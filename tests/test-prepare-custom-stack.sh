#!/usr/bin/env bash
set -euo pipefail

# Quick integration test for prepare-custom-stack.sh (archive mode).
# Tests:
#   1. .terraform-version from source archive is copied to target (not excluded)
#   2. Preserved files (backend.tf, __customer_foo.tf) survive rsync
#   3. dotglob: dotfile preserve patterns (if any) are restored correctly

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

# 4. Dotglob test: create a scenario with a dotfile in preserve dir
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

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
