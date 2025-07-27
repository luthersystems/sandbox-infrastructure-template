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

AUTO_VARS_DIR="${MARS_PROJECT_ROOT}/tf/auto-vars"

# getTfVar VAR_NAME
#   Print the value of VAR_NAME from any JSON file in auto-vars/ or empty string if not found
getTfVar() {
  local key="$1"

  if [[ ! -d "$AUTO_VARS_DIR" ]]; then
    echo "ERROR: Terraform auto vars directory '$AUTO_VARS_DIR' not found" >&2
    echo ""
    exit 1
  fi

  # jq filter to get the variable from any JSON file in the directory, first match wins
  local result=""
  for file in "$AUTO_VARS_DIR"/*.json; do
    # skip if no matching files
    [[ -e "$file" ]] || continue

    val=$(jq -r --arg k "$key" 'if has($k) then .[$k] else empty end' "$file" 2>/dev/null || echo "")
    if [[ -n "$val" ]]; then
      result="$val"
      break
    fi
  done

  echo "${result:-}"
}

# mustGetTfVar VAR_NAME
#   Print the value of VAR_NAME from auto-vars or exit if not set/empty
mustGetTfVar() {
  local val
  val="$(getTfVar "$1")"
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "ERROR: required terraform variable '$1' missing or empty in $AUTO_VARS_DIR" >&2
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

ensure_infra_remote() {
  # repo_clone_ssh_url should be set via terraform auto-vars
  url=$(getTfVar "repo_clone_ssh_url")
  if [ -n "$url" ]; then
    if git remote get-url infra >/dev/null 2>&1; then
      git remote set-url infra "$url"
    else
      git remote add infra "$url"
    fi
    echo "🔧 infra remote configured → $url"
  fi
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
  ensure_infra_remote
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

gitPushInfra() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null
  if git remote get-url infra >/dev/null 2>&1; then
    echo "🚀 Pushing to infra…"
    git push infra HEAD
  else
    echo "Skipping gitPushInfra: no infra remote configured"
  fi
  popd >/dev/null
}
