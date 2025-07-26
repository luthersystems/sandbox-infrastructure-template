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

has_git_repo() {
  [ -e "$MARS_PROJECT_ROOT/.git" ]
}

ensure_git_identity() {
  # if no identity set, give it a CI-friendly default
  if [ -z "$(git config user.email 2>/dev/null)" ]; then
    git config user.email "devbot@luthersystems.com"
  fi
  if [ -z "$(git config user.name 2>/dev/null)" ]; then
    git config user.name "Luther DevBot"
  fi
}

# gitCommit [message]
gitCommit() {
  if ! has_git_repo; then
    echo "Skipping git commit: no .git at repo root: $MARS_PROJECT_ROOT"
    ls -lta "$MARS_PROJECT_ROOT"
    return 0
  fi

  ensure_git_identity

  local msg="${1:-auto-commit: infrastructure changes [ci skip]}"
  git add -A

  if ! git diff --cached --quiet; then
    git commit -m "$msg"
    echo "✅ Git commit created."
  else
    echo "No changes to commit."
  fi
}

gitMergeOriginMain() {
  if ! has_git_repo; then
    echo "Skipping git merge: no .git at repo root: $MARS_PROJECT_ROOT"
    ls -lta "$MARS_PROJECT_ROOT"
    return 0
  fi

  ensure_git_identity

  echo "🔄 Fetching origin/main…"
  git fetch origin main

  echo "🔀 Merging (no‐ff, auto‐edit) origin/main…"
  if git merge origin/main --no-ff --no-edit; then
    echo "✅ Merge commit created."
  else
    echo "⚠️  Merge failed or conflicts detected." >&2
    return 1
  fi
}
