#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$SCRIPT_DIR}"
export MARS_PROJECT_ROOT

. "$MARS_PROJECT_ROOT/shell_utils.sh"

exportTemplateVersion
exportPresetsVersion

REVERSE_IMPORT_BIN="${REVERSE_IMPORT_BIN:-/usr/local/bin/insideout-reverse-import}"
REVERSE_IMPORT_REQUEST="${REVERSE_IMPORT_REQUEST:-$MARS_PROJECT_ROOT/reverse-import/request.json}"
REVERSE_IMPORT_OUT_DIR="${REVERSE_IMPORT_OUT_DIR:-$MARS_PROJECT_ROOT/outputs/reverse-import}"

if [[ ! -f "$REVERSE_IMPORT_REQUEST" ]]; then
  echo "ERROR: reverse-import request not found: $REVERSE_IMPORT_REQUEST" >&2
  exit 1
fi

if [[ ! -x "$REVERSE_IMPORT_BIN" ]]; then
  echo "ERROR: reverse-import binary is not executable: $REVERSE_IMPORT_BIN" >&2
  exit 127
fi

mkdir -p "$REVERSE_IMPORT_OUT_DIR"

if ! setupCloudEnv; then
  echo "ERROR: failed to setup cloud environment" >&2
  exit 1
fi
trap 'cleanupCloudEnv' EXIT

echo "reverse_import_request=$REVERSE_IMPORT_REQUEST"
echo "reverse_import_out_dir=$REVERSE_IMPORT_OUT_DIR"

set +e
"$REVERSE_IMPORT_BIN" \
  --request "$REVERSE_IMPORT_REQUEST" \
  --out-dir "$REVERSE_IMPORT_OUT_DIR"
status=$?
set -e

if [[ "$status" -ne 0 ]]; then
  echo "ERROR: reverse-import job failed with exit code $status; preserving artifacts in $REVERSE_IMPORT_OUT_DIR" >&2
fi

exit "$status"
