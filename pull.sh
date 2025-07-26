#!/usr/bin/env bash
set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
MARS_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# delegate any args through to gitCommit (e.g. custom message)
gitMergeOriginMain "$@"
