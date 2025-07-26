#!/bin/sh
set -euo pipefail

# Determine project root: use $MARS_PROJECT_ROOT if set, otherwise resolve relative to this script or fallback to $PWD
if [ -z "${MARS_PROJECT_ROOT:-}" ]; then
  # Try to find project root as the parent of the directory containing this script
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  MARS_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

ANSIBLE_ENV_FILE="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/env.yaml"

echo_error() {
  echo "$1" >&2
}

# getAnsibleField <key>
getAnsibleField() {
  key="$1"
  if [ ! -f "$ANSIBLE_ENV_FILE" ]; then
    echo_error "ERROR: cannot find $ANSIBLE_ENV_FILE"
    exit 1
  fi
  grep -E "^[[:space:]]*$key:" "$ANSIBLE_ENV_FILE" | head -n1 | sed 's/^[[:space:]]*'"$key"':[[:space:]]*//'
}

# mustGetAnsibleField <key>
mustGetAnsibleField() {
  key="$1"
  val="$(getAnsibleField "$key")"
  if [ -z "$val" ]; then
    echo_error "ERROR: required ansible field '$key' is missing or empty in $ANSIBLE_ENV_FILE"
    exit 1
  fi
  echo "$val"
}

# gitCommit [message]
gitCommit() {
  # Always run from the repo root for reliability
  if ! git -C "$MARS_PROJECT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Skipping git commit: not inside a git repo: ${MARS_PROJECT_ROOT}"
    echo "─── $MARS_PROJECT_ROOT ───────────────────────────────────"
    ls -lta "${MARS_PROJECT_ROOT}"
    if [ -e "${MARS_PROJECT_ROOT}/.git" ]; then
      echo "─── ${MARS_PROJECT_ROOT}/.git ─────────────────────────────"
      ls -lta "${MARS_PROJECT_ROOT}/.git"
    else
      echo "No .git directory/file found under ${MARS_PROJECT_ROOT}"
    fi
    return 0
  fi

  msg="${1:-"auto-commit: infrastructure changes [ci skip]"}"
  git -C "$MARS_PROJECT_ROOT" add -A

  if ! git -C "$MARS_PROJECT_ROOT" diff --cached --quiet; then
    git -C "$MARS_PROJECT_ROOT" commit -m "$msg"
    echo "✅ Git commit created."
  else
    echo "No changes to commit."
  fi
}
