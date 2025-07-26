#!/usr/bin/env bash
set -euo pipefail

# figure out where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# assume project root is one level up
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# load your gitCommit() helper
. "$MARS_PROJECT_ROOT/shell_utils.sh"

# delegate any args through to gitCommit (e.g. custom message)
gitCommit "$@"
