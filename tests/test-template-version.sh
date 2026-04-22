#!/usr/bin/env bash
set -euo pipefail

# Tests for logTemplateVersion(), exportTemplateVersion(), logPresetsVersion(),
# and exportPresetsVersion() in shell_utils.sh.

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

# ============================================================
# Test 5: exportTemplateVersion logs AND exports TEMPLATE_VERSION
# ============================================================
echo "Test 5: exportTemplateVersion exports env var..."

set_template_ref "abcdef12"

# Child process sees TEMPLATE_VERSION from env after exportTemplateVersion runs.
child_sees="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportTemplateVersion >/dev/null
  bash -c 'echo "${TEMPLATE_VERSION:-NOTSET}"'
)"

if [[ "$child_sees" == "abcdef12" ]]; then
  pass "export: child process sees TEMPLATE_VERSION=abcdef12"
else
  fail "export: expected child to see 'abcdef12', got '$child_sees'"
fi

# Also still logs the same line.
log_output="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportTemplateVersion
)"

if [[ "$log_output" == "template_version=abcdef12" ]]; then
  pass "export: log line matches template_version=abcdef12"
else
  fail "export: expected log 'template_version=abcdef12', got '$log_output'"
fi

# ============================================================
# Test 6: exportTemplateVersion falls back to unknown when template_ref missing
# ============================================================
echo "Test 6: exportTemplateVersion falls back to unknown..."

echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

log_output="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportTemplateVersion
)"

if [[ "$log_output" == "template_version=unknown" ]]; then
  pass "export fallback: logs template_version=unknown"
else
  fail "export fallback: expected 'template_version=unknown', got '$log_output'"
fi

# ============================================================
# Test 7: logTemplateVersion does NOT export TEMPLATE_VERSION
# Guards against accidental cross-contamination from the two helpers.
# ============================================================
echo "Test 7: logTemplateVersion does not export..."

set_template_ref "should-not-leak"

child_sees="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  unset TEMPLATE_VERSION
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  logTemplateVersion >/dev/null
  bash -c 'echo "${TEMPLATE_VERSION:-NOTSET}"'
)"

if [[ "$child_sees" == "NOTSET" ]]; then
  pass "logTemplateVersion: does not export (child sees NOTSET)"
else
  fail "logTemplateVersion: unexpectedly exported TEMPLATE_VERSION; child saw '$child_sees'"
fi

# ============================================================
# Presets_ref helpers mirror the template_ref helpers exactly.
# ============================================================

run_log_presets() {
  (
    export MARS_PROJECT_ROOT="$PROJECT"
    # shellcheck disable=SC1091
    . "$PROJECT/shell_utils.sh"
    logPresetsVersion
  )
}

set_presets_ref() {
  local val="$1"
  cat > "$PROJECT/tf/auto-vars/common.auto.tfvars.json" <<EOF
{"presets_ref": "$val"}
EOF
}

# ============================================================
# Test 8: No presets_ref in tfvars → outputs "unknown"
# ============================================================
echo "Test 8: Missing presets_ref in tfvars..."

echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"
output="$(run_log_presets)"

if [[ "$output" == "presets_version=unknown" ]]; then
  pass "missing key: outputs presets_version=unknown"
else
  fail "missing key: expected 'presets_version=unknown', got '$output'"
fi

# ============================================================
# Test 9: presets_ref with a normal value
# ============================================================
echo "Test 9: Normal presets_ref value..."

set_presets_ref "v1.4.2"
output="$(run_log_presets)"

if [[ "$output" == "presets_version=v1.4.2" ]]; then
  pass "normal value: outputs correct presets version"
else
  fail "normal value: expected 'presets_version=v1.4.2', got '$output'"
fi

# ============================================================
# Test 10: presets_ref JSON null → outputs "unknown"
# ============================================================
echo "Test 10: JSON null presets_ref value..."

cat > "$PROJECT/tf/auto-vars/common.auto.tfvars.json" <<'EOF'
{"presets_ref": null}
EOF
output="$(run_log_presets)"

if [[ "$output" == "presets_version=unknown" ]]; then
  pass "null value: outputs presets_version=unknown"
else
  fail "null value: expected 'presets_version=unknown', got '$output'"
fi

# ============================================================
# Test 11: presets_ref empty string → outputs "unknown"
# ============================================================
echo "Test 11: Empty presets_ref value..."

set_presets_ref ""
output="$(run_log_presets)"

if [[ "$output" == "presets_version=unknown" ]]; then
  pass "empty value: outputs presets_version=unknown"
else
  fail "empty value: expected 'presets_version=unknown', got '$output'"
fi

# ============================================================
# Test 12: exportPresetsVersion logs AND exports PRESETS_VERSION
# ============================================================
echo "Test 12: exportPresetsVersion exports env var..."

set_presets_ref "v9.9.9"

child_sees="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportPresetsVersion >/dev/null
  bash -c 'echo "${PRESETS_VERSION:-NOTSET}"'
)"

if [[ "$child_sees" == "v9.9.9" ]]; then
  pass "export: child process sees PRESETS_VERSION=v9.9.9"
else
  fail "export: expected child to see 'v9.9.9', got '$child_sees'"
fi

log_output="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportPresetsVersion
)"

if [[ "$log_output" == "presets_version=v9.9.9" ]]; then
  pass "export: log line matches presets_version=v9.9.9"
else
  fail "export: expected log 'presets_version=v9.9.9', got '$log_output'"
fi

# ============================================================
# Test 13: exportPresetsVersion falls back to unknown when missing
# ============================================================
echo "Test 13: exportPresetsVersion falls back to unknown..."

echo '{}' > "$PROJECT/tf/auto-vars/common.auto.tfvars.json"

log_output="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  exportPresetsVersion
)"

if [[ "$log_output" == "presets_version=unknown" ]]; then
  pass "export fallback: logs presets_version=unknown"
else
  fail "export fallback: expected 'presets_version=unknown', got '$log_output'"
fi

# ============================================================
# Test 14: logPresetsVersion does NOT export PRESETS_VERSION
# ============================================================
echo "Test 14: logPresetsVersion does not export..."

set_presets_ref "should-not-leak"

child_sees="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  unset PRESETS_VERSION
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  logPresetsVersion >/dev/null
  bash -c 'echo "${PRESETS_VERSION:-NOTSET}"'
)"

if [[ "$child_sees" == "NOTSET" ]]; then
  pass "logPresetsVersion: does not export (child sees NOTSET)"
else
  fail "logPresetsVersion: unexpectedly exported PRESETS_VERSION; child saw '$child_sees'"
fi

# ============================================================
# Test 15: Both template_ref and presets_ref set → both log correctly
# ============================================================
echo "Test 15: Both refs set independently..."

cat > "$PROJECT/tf/auto-vars/common.auto.tfvars.json" <<'EOF'
{"template_ref": "deadbeef", "presets_ref": "v1.4.2"}
EOF

combined="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  # shellcheck disable=SC1091
  . "$PROJECT/shell_utils.sh"
  logTemplateVersion
  logPresetsVersion
)"

if [[ "$combined" == *"template_version=deadbeef"* && "$combined" == *"presets_version=v1.4.2"* ]]; then
  pass "combined: both versions logged with correct values"
else
  fail "combined: expected both versions, got: $combined"
fi

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
