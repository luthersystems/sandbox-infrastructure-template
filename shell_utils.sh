#!/bin/sh
set -euo pipefail

# Determine project root: use $MARS_PROJECT_ROOT if set, otherwise resolve relative to this script or fallback to $PWD
if [ -z "${MARS_PROJECT_ROOT:-}" ]; then
  # Try to find project root as the parent of the directory containing this script
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  MARS_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export MARS_PROJECT_ROOT

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

gitMergeInfraMain() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping git merge."
    popd >/dev/null
    return 0
  fi

  if ! git remote get-url infra >/dev/null 2>&1; then
    echo "Skipping gitMergeInfraMain: no infra remote configured"
    popd >/dev/null
    return 0
  fi

  echo "🔄 Fetching infra/main…"
  git fetch infra main

  echo "🔀 Merging (no-ff, auto-edit) infra/main…"
  if git merge infra/main --no-ff --no-edit; then
    echo "✅ Merge commit created."
  else
    echo_error "⚠️  Merge failed or conflicts detected."
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
}

# ============================================================================
# Cloud Provider Detection
# ============================================================================

# getCloudProvider returns the cloud provider from tfvars
# Returns: "aws" or "gcp" (defaults to "aws" for backward compatibility)
getCloudProvider() {
  local cloud
  cloud=$(getTfVar "cloud_provider")

  if [[ -z "$cloud" || "$cloud" == "null" ]]; then
    echo "aws"
  else
    echo "$cloud"
  fi
}

# isGCP returns true if deploying to GCP
isGCP() {
  [[ "$(getCloudProvider)" == "gcp" ]]
}

# isAWS returns true if deploying to AWS
isAWS() {
  [[ "$(getCloudProvider)" == "aws" ]]
}

# ============================================================================
# GCP Credential Management
# ============================================================================

# GCP credential file path (set by setupGCPCredentials)
_GCP_CREDENTIALS_FILE=""

# setupGCPCredentials decodes the base64-encoded service account key
# and writes it to a temporary file with secure permissions.
# Sets GOOGLE_APPLICATION_CREDENTIALS environment variable.
# Returns: 0 on success, 1 on failure
setupGCPCredentials() {
  local creds_b64
  creds_b64=$(getTfVar "gcp_credentials_b64")

  if [[ -z "$creds_b64" || "$creds_b64" == "null" ]]; then
    echo_error "ERROR: gcp_credentials_b64 not found in tfvars"
    return 1
  fi

  # Create unique temporary file with secure permissions
  _GCP_CREDENTIALS_FILE=$(mktemp /tmp/gcp-sa-XXXXXX.json)
  chmod 600 "$_GCP_CREDENTIALS_FILE"

  # Decode and write (avoid logging the content)
  if ! echo "$creds_b64" | base64 -d > "$_GCP_CREDENTIALS_FILE" 2>/dev/null; then
    echo_error "ERROR: Failed to decode gcp_credentials_b64"
    rm -f "$_GCP_CREDENTIALS_FILE"
    return 1
  fi

  # Validate it's valid JSON with required fields
  if ! jq -e '.type == "service_account"' "$_GCP_CREDENTIALS_FILE" >/dev/null 2>&1; then
    echo_error "ERROR: Invalid service account key format"
    rm -f "$_GCP_CREDENTIALS_FILE"
    return 1
  fi

  export GOOGLE_APPLICATION_CREDENTIALS="$_GCP_CREDENTIALS_FILE"
  echo "GCP credentials configured: $GOOGLE_APPLICATION_CREDENTIALS"
  return 0
}

# cleanupGCPCredentials removes the temporary credential file
cleanupGCPCredentials() {
  if [[ -n "$_GCP_CREDENTIALS_FILE" ]] && [[ -f "$_GCP_CREDENTIALS_FILE" ]]; then
    rm -f "$_GCP_CREDENTIALS_FILE"
    echo "Cleaned up GCP credentials file"
  fi
  _GCP_CREDENTIALS_FILE=""
  unset GOOGLE_APPLICATION_CREDENTIALS 2>/dev/null || true
}

# ============================================================================
# Cloud Environment Setup
# ============================================================================

# setupCloudEnv configures the environment for the target cloud provider.
# Call this before running terraform commands.
# Returns: 0 on success, 1 on failure
setupCloudEnv() {
  local cloud
  cloud=$(getCloudProvider)

  echo "Setting up environment for cloud provider: $cloud"

  case "$cloud" in
    gcp)
      # Setup GCP credentials
      if ! setupGCPCredentials; then
        return 1
      fi

      # Export GCP project and region
      local gcp_project gcp_region
      gcp_project=$(getTfVar "gcp_project_id")
      gcp_region=$(getTfVar "gcp_region")

      if [[ -z "$gcp_project" || "$gcp_project" == "null" ]]; then
        echo_error "ERROR: gcp_project_id not found in tfvars"
        return 1
      fi

      if [[ -z "$gcp_region" || "$gcp_region" == "null" ]]; then
        echo_error "ERROR: gcp_region not found in tfvars"
        return 1
      fi

      export GOOGLE_PROJECT="$gcp_project"
      export GOOGLE_REGION="$gcp_region"

      echo "GCP environment configured:"
      echo "  GOOGLE_PROJECT=$GOOGLE_PROJECT"
      echo "  GOOGLE_REGION=$GOOGLE_REGION"
      echo "  GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"
      ;;

    aws)
      # AWS uses IRSA (IAM Roles for Service Accounts) - no additional setup needed
      # The pod's service account already has the required IAM role attached
      echo "AWS environment: using IRSA (no additional setup required)"
      ;;

    *)
      echo_error "ERROR: Unknown cloud provider: $cloud"
      return 1
      ;;
  esac

  return 0
}

# cleanupCloudEnv cleans up any cloud-specific resources (credential files, etc.)
# Call this on script exit (typically via trap)
cleanupCloudEnv() {
  local cloud
  cloud=$(getCloudProvider)

  case "$cloud" in
    gcp)
      cleanupGCPCredentials
      ;;
    aws)
      # No cleanup needed for AWS
      ;;
  esac
}
