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

resolveMarsBinary() {
  local mars_root="${MARS_CONTAINER_ROOT:-/opt/mars}"
  if [[ -x "$mars_root/mars" ]]; then
    echo "$mars_root/mars"
    return 0
  fi
  echo "$mars_root/run.sh"
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
#   Print the value of VAR_NAME from any JSON file in auto-vars/ (or, as a
#   fallback, the gitignored secrets/*.auto.tfvars.json credential drop) or
#   empty string if not found.
getTfVar() {
  local key="$1"

  if [[ ! -d "$AUTO_VARS_DIR" ]]; then
    echo "ERROR: Terraform auto vars directory '$AUTO_VARS_DIR' not found" >&2
    echo ""
    exit 1
  fi

  # jq filter to get the variable from any JSON file, first match wins.
  #
  # Scan order matters (#160): tf/auto-vars/*.json FIRST, so behavior is
  # unchanged while ui-core still writes credentials into
  # tf/auto-vars/common.auto.tfvars.json; THEN fall back to the gitignored
  # secrets/*.auto.tfvars.json credential drop. secrets/ is excluded from the
  # -infra snapshot (mars infra-persist), so credentials placed there never leak
  # into the per-project -infra repo (unlike common.auto.tfvars.json). Absent or
  # empty secrets/ is a silent no-op: the `[[ -e ]]` guard (existing style, no
  # nullglob) skips the unexpanded glob, so nothing errors under callers' `set
  # -euo pipefail` when secrets/ has no *.auto.tfvars.json (today's state).
  local result=""
  local file val
  for file in "$AUTO_VARS_DIR"/*.json "$MARS_PROJECT_ROOT"/secrets/*.auto.tfvars.json; do
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

# ============================================================================
# The per-project -infra repo
# ============================================================================
#
# Every git step on the project tree and its -infra repo is a mars command
# (luthersystems/mars docs/infra-repo.md): infra-clone, infra-merge,
# infra-pull, infra-commit, infra-snapshot, infra-push and infra-persist.
# They hold the rules this file used to hold in shell (the snapshot on top
# of infra/main, the exec-bit and untrack rules, the refusal of a merge,
# rebase, cherry-pick or revert in progress, the luther.infraSnapshotTree
# mark; #160, #143), tested in Go against real git repos.

# resolveMarsCLI prints the mars program the infra-* commands run on:
#   - $MARS_BIN, when set: a native mars build, for example
#     `go install github.com/luthersystems/mars/cmd/mars@<release>`. Use it
#     on a laptop for pull.sh and push.sh, which reach GitHub: the docker
#     wrapper below has neither your SSH keys nor a token file;
#   - in a mars image (where ui-core's Argo jobs run the template), the
#     image's own mars, as resolveMarsBinary finds it;
#   - else the project's ./mars docker wrapper, at the pinned .mars-version.
resolveMarsCLI() {
  if [[ -n "${MARS_BIN:-}" ]]; then
    echo "$MARS_BIN"
    return 0
  fi
  local mars_root="${MARS_CONTAINER_ROOT:-/opt/mars}"
  if [[ -x "$mars_root/mars" || -e "$mars_root/run.sh" ]]; then
    resolveMarsBinary
    return 0
  fi
  echo "$MARS_PROJECT_ROOT/mars"
}

# resolveNativeMarsCLI prints the mars that the stage commands run on: a
# native mars ($MARS_BIN, or the mars image's own), never the ./mars docker
# wrapper. That wrapper forwards only AWS_* and TF_LOG into its container,
# and a stage needs more of this shell than that: TF_CLI_ARGS_plan (ui-core's
# -out and the parallelism), MARS_STAGE_PREPARED, TEMPLATE_VERSION,
# PRESETS_VERSION, the SKIP_*_BOOTSTRAP_PREFLIGHT flags and the GCP
# credential file in /tmp. Without them a stage would plan with the wrong
# name, run the preflight twice or lose its credentials, so it fails here
# instead (#114).
resolveNativeMarsCLI() {
  local bin
  bin="$(resolveMarsCLI)"
  if [[ "$bin" == "$MARS_PROJECT_ROOT/mars" ]]; then
    echo "ERROR: the mars stage commands need a native mars: set MARS_BIN to a mars v0.149.0 or later (the release in .mars-version); the ./mars docker wrapper does not pass the stage's environment. [#114]" >&2
    return 1
  fi
  echo "$bin"
}

# MARS_INFRA_CHECKED caches, per process, the mars that answered for the
# infra-* commands, so apply.sh's three calls start it once more, not three
# times.
MARS_INFRA_CHECKED=""

# marsInfra <command> [args...] runs `mars default <command>` on the
# project root and returns its exit code (docs/infra-repo.md lists them).
# It runs in the project root with --root ., so the path is right both for
# a native mars and inside the docker wrapper, which mounts the current
# directory.
#
# A mars older than the infra-* commands fails closed (1) with a loud
# warning when there is git work to do: the merge then stops the apply, and
# the non-fatal steps (push, persist) warn as for any git problem. With no
# .git, merge, commit, snapshot and push have nothing to do and return 0, as
# the mars commands themselves would; only infra-clone and infra-persist,
# which make the .git, still need the command.
marsInfra() {
  local cmd="$1" bin
  shift
  bin="$(resolveMarsCLI)"
  if [[ "$MARS_INFRA_CHECKED" != "$bin" ]]; then
    if ! "$bin" default infra-commit --help >/dev/null 2>&1; then
      if [[ ! -e "$MARS_PROJECT_ROOT/.git" && "$cmd" != infra-clone && "$cmd" != infra-persist ]]; then
        echo "ℹ️  [git-infra] no .git at $MARS_PROJECT_ROOT and $bin has no infra-* commands; skipping $cmd." >&2
        return 0
      fi
      echo "⚠️  [git-infra] WARNING: $bin has no 'mars $cmd' (or does not run); it needs a mars release with the infra-* commands (luthersystems/mars#368). [sandbox-infrastructure-template#190]" >&2
      return 1
    fi
    MARS_INFRA_CHECKED="$bin"
  fi
  (cd "$MARS_PROJECT_ROOT" && "$bin" default "$cmd" --root . "$@")
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
# 1 when setupGCPCredentials exported the scoped AWS session as AWS_* env vars
# for a keyless deploy, so cleanupGCPCredentials unsets them again.
_GCP_EXPORTED_AWS_SESSION=0
# The AWS_* env vars (declare -p) that the export replaced, restored on cleanup.
_GCP_SAVED_AWS_ENV=""

# _gcpDeployServiceAccount prints gcp_deploy_service_account, empty for a key
# deploy. A non-empty value makes the deploy keyless (ui-core#153).
_gcpDeployServiceAccount() {
  local sa
  sa=$(getTfVar "gcp_deploy_service_account")
  [[ "$sa" == "null" ]] && sa=""
  printf '%s' "$sa"
}

# setupGCPCredentials decodes gcp_credentials_b64 and writes it to a
# temporary file with secure permissions. Sets GOOGLE_APPLICATION_CREDENTIALS.
#
# Two kinds of credential (ui-core#153):
#   - A key deploy: a service_account key. gcp_deploy_service_account is empty.
#   - A keyless deploy: gcp_deploy_service_account names the customer's
#     deploy service account, and the credential is an external_account
#     credential that impersonates it through the platform's deploy workload
#     identity pool. It holds no key: Google's client libraries sign an AWS
#     GetCallerIdentity request with the pod's scoped AWS session and trade it
#     at Google STS. They read that session only from AWS_ACCESS_KEY_ID,
#     AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_REGION (or
#     AWS_DEFAULT_REGION), so the session is exported here from the shared
#     credentials file ui-core's scope-aws init container wrote
#     (AWS_SHARED_CREDENTIALS_FILE).
# Returns: 0 on success, 1 on failure
setupGCPCredentials() {
  local creds_b64 deploy_sa cred_type
  creds_b64=$(getTfVar "gcp_credentials_b64")
  deploy_sa=$(_gcpDeployServiceAccount)

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

  cred_type=$(jq -r '.type // ""' "$_GCP_CREDENTIALS_FILE" 2>/dev/null || echo "")
  if [[ -z "$deploy_sa" ]]; then
    if [[ "$cred_type" != "service_account" ]]; then
      echo_error "ERROR: Invalid service account key format"
      rm -f "$_GCP_CREDENTIALS_FILE"
      return 1
    fi
  else
    if ! _checkGCPExternalAccount "$_GCP_CREDENTIALS_FILE" "$deploy_sa" || ! _exportScopedAWSSession; then
      rm -f "$_GCP_CREDENTIALS_FILE"
      _GCP_CREDENTIALS_FILE=""
      return 1
    fi
    echo "GCP keyless deploy: impersonating $deploy_sa through workload identity federation"
  fi

  export GOOGLE_APPLICATION_CREDENTIALS="$_GCP_CREDENTIALS_FILE"
  echo "GCP credentials configured: $GOOGLE_APPLICATION_CREDENTIALS"
  return 0
}

# _checkGCPExternalAccount checks that the credential file is the AWS
# external_account credential ui-core writes for a keyless deploy, and that it
# impersonates deploy_sa. A mismatch would make cloud-provision grant token
# creator to an account the deploy does not run as.
_checkGCPExternalAccount() {
  local file="$1" deploy_sa="$2" want_url
  want_url="https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${deploy_sa}:generateAccessToken"
  if ! jq -e --arg url "$want_url" '
      .type == "external_account"
      and .subject_token_type == "urn:ietf:params:aws:token-type:aws4_request"
      and (.credential_source.environment_id // "" | startswith("aws"))
      and .service_account_impersonation_url == $url' "$file" >/dev/null 2>&1; then
    echo_error "ERROR: gcp_deploy_service_account is set, but gcp_credentials_b64 is not an AWS external_account credential that impersonates ${deploy_sa} [ui-core#153]"
    return 1
  fi
  return 0
}

# _exportScopedAWSSession exports the pod's scoped AWS session as AWS_* env
# vars, for the external_account credential of a keyless GCP deploy. It reads
# the session from the shared credentials file the scope-aws init container
# wrote (AWS_SHARED_CREDENTIALS_FILE, profile AWS_PROFILE or default), ahead of
# any key pair already in the env: a nested run can inherit an unrelated one,
# and Google STS would refuse it with a 403 far from the cause. Only without
# that file is an env session used. The region comes from AWS_REGION or
# AWS_DEFAULT_REGION, which Google's AWS source both read.
_exportScopedAWSSession() {
  if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
    echo_error "ERROR: a keyless GCP deploy needs AWS_REGION (the region of the AWS session it signs with) [ui-core#153]"
    return 1
  fi
  if [[ -n "${JUMP_ROLE_ARN:-}" ]]; then
    echo_error "ERROR: a keyless GCP deploy signs with the scoped AWS session, which JUMP_ROLE_ARN would replace; unset it [ui-core#153]"
    return 1
  fi
  local file="${AWS_SHARED_CREDENTIALS_FILE:-}" profile="${AWS_PROFILE:-default}"
  if [[ -z "$file" ]]; then
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
      echo "GCP keyless deploy: signing with the AWS session in the environment"
      return 0
    fi
    echo_error "ERROR: a keyless GCP deploy needs the pod's scoped AWS session, but AWS_SHARED_CREDENTIALS_FILE is unset; it needs scoped terraform credentials [ui-core#153]"
    return 1
  fi
  local session key secret token
  if [[ ! -r "$file" ]] || ! session=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      aws configure export-credentials --profile "$profile" --format process 2>/dev/null); then
    echo_error "ERROR: cannot read the AWS session of profile ${profile} from ${file} [ui-core#153]"
    return 1
  fi
  key=$(jq -r '.AccessKeyId // ""' <<<"$session")
  secret=$(jq -r '.SecretAccessKey // ""' <<<"$session")
  token=$(jq -r '.SessionToken // ""' <<<"$session")
  if [[ -z "$key" || -z "$secret" ]]; then
    echo_error "ERROR: profile ${profile} in ${file} has no AWS access key [ui-core#153]"
    return 1
  fi
  _GCP_SAVED_AWS_ENV=$(declare -p AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true)
  export AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret"
  if [[ -n "$token" ]]; then
    export AWS_SESSION_TOKEN="$token"
  else
    unset AWS_SESSION_TOKEN
  fi
  _GCP_EXPORTED_AWS_SESSION=1
  echo "GCP keyless deploy: signing with the AWS session of profile ${profile}"
  return 0
}

# cleanupGCPCredentials removes the temporary credential file, and the AWS
# session env vars setupGCPCredentials exported for a keyless deploy.
cleanupGCPCredentials() {
  if [[ -n "$_GCP_CREDENTIALS_FILE" ]] && [[ -f "$_GCP_CREDENTIALS_FILE" ]]; then
    rm -f "$_GCP_CREDENTIALS_FILE"
    echo "Cleaned up GCP credentials file"
  fi
  _GCP_CREDENTIALS_FILE=""
  unset GOOGLE_APPLICATION_CREDENTIALS 2>/dev/null || true
  if [[ "$_GCP_EXPORTED_AWS_SESSION" == "1" ]]; then
    # Put back whatever AWS_* the env held before the export.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    if [[ -n "$_GCP_SAVED_AWS_ENV" ]]; then
      eval "${_GCP_SAVED_AWS_ENV//declare /declare -g }"
    fi
    _GCP_SAVED_AWS_ENV=""
    _GCP_EXPORTED_AWS_SESSION=0
  fi
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

# The cloud setup has two parts:
#   - the process part (_setupCloudCredentials, assumeJumpRole): the
#     credential file and the exported variables terraform reads. It must
#     run in the process that starts terraform (or mars), because an export
#     reaches only child processes;
#   - the stage part (_selectCloudFiles, _bootstrapPreflight): the cloud's
#     .tf files and the bootstrap preflight, both keyed on the stage
#     directory that is the current directory.
# setupCloudEnv runs both, for one stage. A mars stage command that plans
# several stages (plan-all.sh) runs setupCloudCredentials once before mars,
# and its per-stage setup hook (tf/stage-setup.sh) runs prepareCloudStage in
# each stage directory (#114).

# setupCloudEnv configures the environment for the target cloud provider,
# for the stage whose directory is the current directory.
# Call this before running terraform commands.
# Returns: 0 on success, 1 on failure
setupCloudEnv() {
  echo "Setting up environment for cloud provider: $(getCloudProvider)"

  # Activate cloud-specific templates (copies .tf.tmpl -> .tf)
  _selectCloudFiles

  _setupCloudCredentials || return 1
  _bootstrapPreflight || return 1

  # Handle AWS jump role assumption (applies to all providers)
  assumeJumpRole

  return 0
}

# setupCloudCredentials is the process part of setupCloudEnv: the
# credentials and exported variables, without the stage's files or its
# preflight. Returns: 0 on success, 1 on failure
setupCloudCredentials() {
  echo "Setting up credentials for cloud provider: $(getCloudProvider)"
  _setupCloudCredentials || return 1
  assumeJumpRole
}

# prepareCloudStage is the stage part of setupCloudEnv, in the stage
# directory that is the current directory: the cloud's .tf files and the
# bootstrap preflight. It needs the process part to have run in a parent
# (the GCP preflight reads GOOGLE_PROJECT and the credential file).
# Returns: 0 on success, 1 on failure
prepareCloudStage() {
  _selectCloudFiles
  _bootstrapPreflight
}

# _setupCloudCredentials writes the cloud's credential file and exports the
# variables terraform reads. Returns: 0 on success, 1 on failure
_setupCloudCredentials() {
  local cloud
  cloud=$(getCloudProvider)

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
}

# _bootstrapPreflight runs the bootstrap permission preflight of the
# cloud-provision stage, when the current directory is that stage.
# Returns: 0 on success or when it does not apply, 1 on failure
_bootstrapPreflight() {
  local cloud
  cloud=$(getCloudProvider)

  case "$cloud" in
    gcp)
      # Fail-fast GCP bootstrap-permission preflight (luthersystems/reliable#2243).
      # Only the cloud-provision stage creates the GCS tfstate bucket + the two
      # service accounts + the Owner grant, so scope the check to that stage
      # dir — every other stage is left untouched. CWD is the stage dir here
      # (setupCloudEnv already assumes this via _selectCloudFiles), so gate on
      # its basename. The preflight runs BEFORE any terraform init/plan/apply
      # (this is the earliest hook where GOOGLE_APPLICATION_CREDENTIALS is set),
      # so a missing-permission failure aborts before repo.tf's GitHub side
      # creates the orphaned partial state #2243 was about. gcp-preflight.sh
      # fails OPEN on its own infra/transport errors and only fails CLOSED
      # (exit 1) on a definitive verdict.
      # A keyless deploy (gcp_deploy_service_account, ui-core#153) skips it:
      # the preflight can mint a token only from a service_account key, and
      # the oracle already ran the same permission checks as the federated
      # identity before it started the job.
      local gcp_deploy_sa
      gcp_deploy_sa=$(_gcpDeployServiceAccount)
      if [[ "$(basename "$PWD")" == "cloud-provision" && -n "$gcp_deploy_sa" ]]; then
        echo "GCP bootstrap preflight: skipped for a keyless deploy (the oracle checked ${gcp_deploy_sa})"
      elif [[ "$(basename "$PWD")" == "cloud-provision" ]]; then
        if ! bash "$MARS_PROJECT_ROOT/tf/gcp-preflight.sh" "$GOOGLE_PROJECT"; then
          echo_error "ERROR: GCP bootstrap permission preflight failed — aborting before terraform runs. [reliable#2243]"
          return 1
        fi
      fi
      ;;

    aws)
      # Fail-fast AWS bootstrap-permission preflight (luthersystems/reliable#2243).
      # Twin of the GCP preflight above. Only the cloud-provision stage creates
      # the S3 tfstate bucket + KMS key + the admin/inspector IAM roles, so scope
      # the check to that stage dir — every other stage is left untouched. CWD is
      # the stage dir here. The preflight runs BEFORE any terraform init/plan/apply
      # so a denied-action failure aborts before repo.tf's GitHub side creates the
      # orphaned partial state #2243 was about. providers-aws.tf.tmpl has the aws
      # provider assume the customer bootstrap_role (with aws_external_id), so pass
      # those from tfvars — the preflight assumes that role and simulates against
      # it (empty bootstrap_role ⇒ it simulates the ambient caller identity).
      # aws-preflight.sh fails OPEN on its own infra/transport errors (incl. an
      # inability to run the simulation) and only fails CLOSED on a definitive
      # denied-action verdict or an explicit AccessDenied on the assume-role.
      # NOTE: assumeJumpRole runs after this case; in the mars/Argo deploy path
      # JUMP_ROLE_ARN is unset, so the ambient (IRSA) creds the preflight uses to
      # assume bootstrap_role match those terraform will use.
      if [[ "$(basename "$PWD")" == "cloud-provision" ]]; then
        local aws_bootstrap_role aws_external_id aws_region_v aws_access_key_id
        aws_bootstrap_role=$(getTfVar "bootstrap_role")
        aws_external_id=$(getTfVar "aws_external_id")
        aws_region_v=$(getTfVar "aws_region")
        aws_access_key_id=$(getTfVar "aws_access_key_id")
        # Customer credentials are required (luthersystems/reliable#2461).
        # With neither a bootstrap_role nor access keys, the aws provider
        # falls back to the runner's own IRSA identity and builds the
        # customer's stack in the platform account. Refuse instead.
        if [[ -z "$aws_bootstrap_role" && -z "$aws_access_key_id" ]]; then
          echo_error "ERROR: no customer AWS credentials (bootstrap_role or aws_access_key_id) — refusing to run as the runner's own identity. [reliable#2461]"
          return 1
        fi
        # Access-key mode: ui-core already simulated the required actions
        # against these keys before dispatch. The preflight below only
        # knows role and ambient modes, and ambient would check the runner
        # instead of the customer, so skip it here.
        if [[ -n "$aws_access_key_id" && -z "$aws_bootstrap_role" ]]; then
          echo "AWS credentials: customer access keys (bootstrap preflight skipped)"
        elif ! AWS_BOOTSTRAP_ROLE="$aws_bootstrap_role" \
             AWS_EXTERNAL_ID="$aws_external_id" \
             AWS_PREFLIGHT_REGION="${aws_region_v:-us-east-1}" \
             bash "$MARS_PROJECT_ROOT/tf/aws-preflight.sh" "$aws_bootstrap_role"; then
          echo_error "ERROR: AWS bootstrap permission preflight failed — aborting before terraform runs. [reliable#2243]"
          return 1
        fi
      fi
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
