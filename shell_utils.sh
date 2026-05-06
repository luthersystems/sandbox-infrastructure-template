#!/usr/bin/env bash
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
    if [[ -n "$val" && "$val" != "null" ]]; then
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
  # Check if main branch exists on remote before fetching
  if ! git ls-remote --heads infra main | grep -q main; then
    echo "ℹ️  infra/main does not exist yet (new repo) - skipping merge"
    popd >/dev/null
    return 0
  fi

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
# Cloud-Specific File Selection
# ============================================================================

# _selectCloudFiles copies all cloud-specific .tf.tmpl templates for the
# active cloud into the current directory.  Matches two naming conventions:
#   providers-<cloud>.tf.tmpl  (provider declarations)
#   <cloud>-resources.tf.tmpl  (cloud-only resources, outputs, locals)
#
# The generated .tf files are gitignored so they never get committed.
# Designed for future mix/match mode: call once per cloud or extend the list.
_selectCloudFiles() {
  local cloud
  cloud=$(getCloudProvider)

  local tmpl target
  for tmpl in "providers-${cloud}.tf.tmpl" "${cloud}-resources.tf.tmpl"; do
    [[ -e "$tmpl" ]] || continue
    target="${tmpl%.tmpl}"
    cp "$tmpl" "$target"
    echo "Activated: $target"
  done
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
#
# WIF short-circuit: when GOOGLE_OAUTH_ACCESS_TOKEN is already set in the
# environment (Phase-2 ops where ui-core has minted an impersonated token via
# Workload Identity Federation), there is nothing to do. The google provider
# picks up the env var directly; no SA key file is needed.
setupGCPCredentials() {
  if [[ -n "${GOOGLE_OAUTH_ACCESS_TOKEN:-}" ]]; then
    echo "GCP access token supplied via GOOGLE_OAUTH_ACCESS_TOKEN; skipping SA-key setup"
    return 0
  fi

  local creds_b64
  creds_b64=$(getTfVar "gcp_credentials_b64")

  if [[ -z "$creds_b64" || "$creds_b64" == "null" ]]; then
    echo_error "ERROR: gcp_credentials_b64 not found in tfvars (and no GOOGLE_OAUTH_ACCESS_TOKEN set)"
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
# AWS Jump Role
# ============================================================================

# assumeJumpRole assumes the role specified by JUMP_ROLE_ARN (if set).
# Exports temporary AWS credentials for the assumed role.
assumeJumpRole() {
  if [[ -z "${JUMP_ROLE_ARN:-}" ]]; then
    return 0
  fi

  echo "Assuming jump role: $JUMP_ROLE_ARN"
  local creds_json
  creds_json=$(aws sts assume-role \
    --role-arn "$JUMP_ROLE_ARN" \
    --role-session-name "mars-jump-session" \
    --output json)

  AWS_ACCESS_KEY_ID=$(echo "$creds_json" | jq -r .Credentials.AccessKeyId)
  AWS_SECRET_ACCESS_KEY=$(echo "$creds_json" | jq -r .Credentials.SecretAccessKey)
  AWS_SESSION_TOKEN=$(echo "$creds_json" | jq -r .Credentials.SessionToken)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "Now running under assumed jump role credentials"
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

  # Activate cloud-specific templates (copies .tf.tmpl -> .tf)
  _selectCloudFiles

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
      # AWS uses IRSA (IAM Roles for Service Accounts) for AWS auth.
      # No GCP provider or credentials needed — all cloud-specific resources
      # and providers are isolated in .tf.tmpl template files.
      echo "AWS environment: using IRSA"
      ;;

    *)
      echo_error "ERROR: Unknown cloud provider: $cloud"
      return 1
      ;;
  esac

  # Handle AWS jump role assumption (applies to all providers)
  assumeJumpRole

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
  esac
}

# logTemplateVersion logs the infrastructure template version.
# Reads template_ref from TF auto-vars (set by Oracle during template refresh).
logTemplateVersion() {
  local ver
  ver=$(getTfVar "template_ref")
  echo "template_version=${ver:-unknown}"
}

# exportTemplateVersion exports TEMPLATE_VERSION and logs template_version=<sha>.
# Use in scripts that invoke child processes (e.g. drift-check.sh) which read
# TEMPLATE_VERSION from env. For log-only use, prefer logTemplateVersion.
exportTemplateVersion() {
  export TEMPLATE_VERSION
  TEMPLATE_VERSION="$(getTfVar template_ref)"
  echo "template_version=${TEMPLATE_VERSION:-unknown}"
}

# logPresetsVersion logs the insideout-terraform-presets module version.
# Reads presets_ref from TF auto-vars (written alongside template_ref).
logPresetsVersion() {
  local ver
  ver=$(getTfVar "presets_ref")
  echo "presets_version=${ver:-unknown}"
}

# exportPresetsVersion exports PRESETS_VERSION and logs presets_version=<sha>.
# Use in scripts that invoke child processes (e.g. drift-check.sh) which read
# PRESETS_VERSION from env. For log-only use, prefer logPresetsVersion.
exportPresetsVersion() {
  export PRESETS_VERSION
  PRESETS_VERSION="$(getTfVar presets_ref)"
  echo "presets_version=${PRESETS_VERSION:-unknown}"
}
