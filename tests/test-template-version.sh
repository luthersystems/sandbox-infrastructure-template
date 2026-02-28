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

# Helper: set template_ref in the tfvars JSON
set_template_ref() {
  local val="$1"
  cat > "$PROJECT/tf/auto-vars/common.auto.tfvars.json" <<EOF
{"template_ref": "$val"}
EOF
}

# ============================================================
# Test 1: No template_ref in tfvars → outputs "unknown"
# ============================================================
echo "Test 1: Missing template_ref in tfvars..."

echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "missing key: outputs template_version=unknown"
else
  fail "missing key: expected 'template_version=unknown', got '$output'"
fi

# ============================================================
# Test 2: template_ref with a normal value
# ============================================================
echo "Test 2: Normal version string..."

set_template_ref "main"
output="$(run_log_version)"

if [[ "$output" == "template_version=main" ]]; then
  pass "normal value: outputs correct version"
else
  fail "normal value: expected 'template_version=main', got '$output'"
fi

# ============================================================
# Test 3: template_ref set to JSON null → outputs "unknown"
# ============================================================
echo "Test 3: JSON null template_ref value..."

cat > "$PROJECT/tf/auto-vars/common.auto.tfvars.json" <<'EOF'
{"template_ref": null}
EOF
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "null value: outputs template_version=unknown"
else
  fail "null value: expected 'template_version=unknown', got '$output'"
fi

# ============================================================
# Test 4: template_ref with empty string → outputs "unknown"
# ============================================================
echo "Test 4: Empty template_ref value..."

set_template_ref ""
output="$(run_log_version)"

if [[ "$output" == "template_version=unknown" ]]; then
  pass "empty value: outputs template_version=unknown"
else
  fail "empty value: expected 'template_version=unknown', got '$output'"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
