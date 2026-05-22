#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

PROJECT="$WORKDIR/project"
BIN_LOG="$WORKDIR/bin.log"
CLOUD_LOG="$WORKDIR/cloud.log"
EVENT_LOG="$WORKDIR/events.log"
mkdir -p "$PROJECT/reverse-import" "$PROJECT/outputs" "$WORKDIR/bin"

cat > "$PROJECT/shell_utils.sh" <<OUTER
#!/usr/bin/env bash
set -euo pipefail

exportTemplateVersion() {
  echo "template_version=test-template"
  export TEMPLATE_VERSION=test-template
}

exportPresetsVersion() {
  echo "presets_version=test-presets"
  export PRESETS_VERSION=test-presets
}

setupCloudEnv() {
  echo "setupCloudEnv" >> "$CLOUD_LOG"
  echo "setupCloudEnv" >> "$EVENT_LOG"
}

cleanupCloudEnv() {
  echo "cleanupCloudEnv" >> "$CLOUD_LOG"
  echo "cleanupCloudEnv" >> "$EVENT_LOG"
}
OUTER

cat > "$PROJECT/reverse-import/request.json" <<'OUTER'
{"version":1,"resources":[]}
OUTER

FAKE_BIN="$WORKDIR/bin/insideout-reverse-import"
cat > "$FAKE_BIN" <<OUTER
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "\$@" >> "$BIN_LOG"
printf '\n' >> "$BIN_LOG"
echo "insideout-reverse-import" >> "$EVENT_LOG"

out_dir=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --out-dir)
      out_dir="\$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "\$out_dir"
echo '{"status":"succeeded"}' > "\$out_dir/reverse-result.json"
echo '{"import_count":0}' > "\$out_dir/plan-summary.json"

if [[ "\${FAKE_REVERSE_IMPORT_FAIL:-false}" == "true" ]]; then
  echo '{"status":"failed"}' > "\$out_dir/reverse-result.json"
  exit 42
fi
OUTER
chmod +x "$FAKE_BIN"

run_wrapper() {
  (
    export MARS_PROJECT_ROOT="$PROJECT"
    export REVERSE_IMPORT_BIN="$FAKE_BIN"
    bash "$ROOT/reverse-import.sh"
  )
}

output="$(run_wrapper 2>&1)"

if ! grep -q "template_version=test-template" <<<"$output"; then
  echo "expected template provenance log in output" >&2
  exit 1
fi

if ! grep -q "presets_version=test-presets" <<<"$output"; then
  echo "expected presets provenance log in output" >&2
  exit 1
fi

if ! grep -qx "setupCloudEnv" "$CLOUD_LOG"; then
  echo "expected setupCloudEnv to run once before the binary" >&2
  exit 1
fi

if ! grep -q -- "--request $PROJECT/reverse-import/request.json --out-dir $PROJECT/outputs/reverse-import" "$BIN_LOG"; then
  echo "expected request and stable output paths in binary args; got:" >&2
  cat "$BIN_LOG" >&2
  exit 1
fi

if [[ ! -f "$PROJECT/outputs/reverse-import/reverse-result.json" ]]; then
  echo "expected reverse-result.json under outputs/reverse-import" >&2
  exit 1
fi

if ! grep -qx "cleanupCloudEnv" "$CLOUD_LOG"; then
  echo "expected cleanupCloudEnv to run after success" >&2
  exit 1
fi

expected_events=$'setupCloudEnv\ninsideout-reverse-import\ncleanupCloudEnv'
if [[ "$(cat "$EVENT_LOG")" != "$expected_events" ]]; then
  echo "expected setup, binary, cleanup order; got:" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi

: > "$CLOUD_LOG"
: > "$BIN_LOG"
: > "$EVENT_LOG"
rm -rf "$PROJECT/outputs/reverse-import"

set +e
failure_output="$(
  export MARS_PROJECT_ROOT="$PROJECT"
  export REVERSE_IMPORT_BIN="$FAKE_BIN"
  export FAKE_REVERSE_IMPORT_FAIL=true
  bash "$ROOT/reverse-import.sh" 2>&1
)"
exit_code=$?
set -e

if [[ "$exit_code" -ne 42 ]]; then
  echo "expected failing binary exit code 42, got $exit_code. Output: $failure_output" >&2
  exit 1
fi

if [[ ! -f "$PROJECT/outputs/reverse-import/reverse-result.json" ]]; then
  echo "expected failure artifacts to be preserved" >&2
  exit 1
fi

if ! grep -qx "cleanupCloudEnv" "$CLOUD_LOG"; then
  echo "expected cleanupCloudEnv to run after failure" >&2
  exit 1
fi

if [[ "$(cat "$EVENT_LOG")" != "$expected_events" ]]; then
  echo "expected setup, binary, cleanup order after failure; got:" >&2
  cat "$EVENT_LOG" >&2
  exit 1
fi
