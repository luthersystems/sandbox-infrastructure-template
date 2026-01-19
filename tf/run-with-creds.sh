#!/usr/bin/env bash

# Source shell utilities for cloud provider detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shell_utils.sh"

# Setup cloud-specific credentials
if isGCP; then
  echo "🔐 Setting up GCP credentials"
  if ! setupGCPCredentials; then
    echo "❌ Failed to setup GCP credentials" >&2
    exit 1
  fi
  trap 'cleanupGCPCredentials' EXIT

  # Export GCP project and region
  gcp_project=$(getTfVar "gcp_project_id")
  gcp_region=$(getTfVar "gcp_region")

  if [[ -z "$gcp_project" || "$gcp_project" == "null" ]]; then
    echo "❌ ERROR: gcp_project_id not found in tfvars" >&2
    exit 1
  fi

  if [[ -z "$gcp_region" || "$gcp_region" == "null" ]]; then
    echo "❌ ERROR: gcp_region not found in tfvars" >&2
    exit 1
  fi

  export GOOGLE_PROJECT="$gcp_project"
  export GOOGLE_REGION="$gcp_region"

  echo "✅ GCP environment configured:"
  echo "   GOOGLE_PROJECT=$GOOGLE_PROJECT"
  echo "   GOOGLE_REGION=$GOOGLE_REGION"

else
  # AWS/other: Create dummy GCP credentials at runtime to prevent Google provider
  # from trying to load Application Default Credentials (which fails in non-GCP envs)
  _GCP_DUMMY_FILE=$(mktemp /tmp/gcp-dummy-XXXXXX.json)
  # Generate random bytes for the dummy key field (runtime-only, never stored in git)
  _DUMMY_KEY=$(head -c 256 /dev/urandom 2>/dev/null | base64 | tr -d '\n' || echo "dW51c2VkCg==")
  cat > "$_GCP_DUMMY_FILE" << EOFCREDS
{"type":"service_account","project_id":"unused","private_key_id":"unused","private_key":"-----BEGIN PRIVATE KEY-----\n${_DUMMY_KEY}\n-----END PRIVATE KEY-----\n","client_email":"unused@unused.iam.gserviceaccount.com","client_id":"0","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}
EOFCREDS
  export GOOGLE_APPLICATION_CREDENTIALS="$_GCP_DUMMY_FILE"
  trap 'rm -f "$_GCP_DUMMY_FILE"' EXIT
fi

# Handle AWS jump role if set
if [ -n "${JUMP_ROLE_ARN:-}" ]; then
  echo "🔐 assuming jump role ${JUMP_ROLE_ARN}"
  CREDS_JSON=$(aws sts assume-role \
    --role-arn "$JUMP_ROLE_ARN" \
    --role-session-name "mars-jump-session" \
    --output json)

  export AWS_ACCESS_KEY_ID=$(echo "$CREDS_JSON" | jq -r .Credentials.AccessKeyId)
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS_JSON" | jq -r .Credentials.SecretAccessKey)
  export AWS_SESSION_TOKEN=$(echo "$CREDS_JSON" | jq -r .Credentials.SessionToken)
  echo "✅ Now running Terraform under assumed credentials"
fi

# now hand off to the real Mars runner
exec /opt/mars/run.sh "$@"
