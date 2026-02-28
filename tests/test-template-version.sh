#!/usr/bin/env bash
set -euo pipefail

# Tests for logTemplateVersion() in shell_utils.sh.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Build a minimal project tree ---
PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT/tf/auto-vars"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"

cat > "$PROJECT/ansible/inventories/default/group_vars/all/env.yaml" <<'EOF'
environment: test
EOF

echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

# Copy shell_utils.sh
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"

# Helper: source shell_utils and call logTemplateVersion in the project context
run_log_version() {
  (
    export MARS_PROJECT_ROOT="$PROJECT"
    # shellcheck disable=SC1091
    . "$PROJECT/shell_utils.sh"
    logTemplateVersion
  )
}

# ============================================================
# Test 1: No .template_version file → outputs "unknown"
# ============================================================
echo "Test 1: Missing .template_version file..."

rm -f "$PROJECT/.template_version"
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "missing file: outputs template_version=unknown"
else
  fail "missing file: expected 'template_version=unknown', got '$output'"
fi

# ============================================================
# Test 2: .template_version with a normal value
# ============================================================
echo "Test 2: Normal version string..."

echo "abc123def" > "$PROJECT/.template_version"
output="$(run_log_version)"

if [[ "$output" == "template_version=abc123def" ]]; then
  pass "normal value: outputs correct version"
else
  fail "normal value: expected 'template_version=abc123def', got '$output'"
fi

# ============================================================
# Test 3: Whitespace and newlines are stripped
# ============================================================
echo "Test 3: Whitespace stripping..."

printf "  v1.2.3  \n\n" > "$PROJECT/.template_version"
output="$(run_log_version)"

if [[ "$output" == "template_version=v1.2.3" ]]; then
  pass "whitespace: stripped correctly"
else
  fail "whitespace: expected 'template_version=v1.2.3', got '$output'"
fi

# ============================================================
# Test 4: Empty file → outputs "unknown"
# ============================================================
echo "Test 4: Empty .template_version file..."

: > "$PROJECT/.template_version"
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "empty file: outputs template_version=unknown"
else
  fail "empty file: expected 'template_version=unknown', got '$output'"
fi

# ============================================================
# Test 5: File with only whitespace → outputs "unknown"
# ============================================================
echo "Test 5: Whitespace-only .template_version file..."

printf "   \n  \n" > "$PROJECT/.template_version"
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "whitespace-only: outputs template_version=unknown"
else
  fail "whitespace-only: expected 'template_version=unknown', got '$output'"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
