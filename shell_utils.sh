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
  git config --local user.email >/dev/null 2>&1 ||
    git config --local user.email "devbot@luthersystems.com"
  git config --local user.name >/dev/null 2>&1 ||
    git config --local user.name "Luther DevBot"
}

disable_filemode() {
  git config --local core.fileMode false
}

configure_deploy_ssh() {
  local KEY="$MARS_PROJECT_ROOT/secrets/infra_deploy_key.pem"
  if [ ! -f "$KEY" ]; then
    echo "Skipping SSH config: no deploy key at $KEY"
    return 0
  fi

  git config --local core.sshCommand "ssh -i $KEY -o IdentitiesOnly=yes"
}

configure_git() {
  if ! has_git_repo; then
    echo "⚠️  configure_git: no .git at $MARS_PROJECT_ROOT"
    return 1
  fi
  pushd "$MARS_PROJECT_ROOT" >/dev/null
  ensure_git_identity
  disable_filemode
  configure_deploy_ssh
  popd >/dev/null
}

gitCommit() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping commit."
    popd >/dev/null
    return 0
  fi

  msg="${1:-auto-commit: infrastructure changes [ci skip]}"
  git add -A

  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "$msg"
    echo "✅ Git commit created."
  fi

  popd >/dev/null
}

gitMergeOriginMain() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping git merge."
    popd >/dev/null
    return 0
  fi

  echo "🔄 Fetching origin/main…"
  git fetch origin main

  echo "🔀 Merging (no‐ff, auto‐edit) origin/main…"
  if git merge origin/main --no-ff --no-edit; then
    echo "✅ Merge commit created."
  else
    echo_error "⚠️  Merge failed or conflicts detected."
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
}
