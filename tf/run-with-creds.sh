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

elif [ -n "${JUMP_ROLE_ARN:-}" ]; then
  # AWS: if JUMP_ROLE_ARN is set, grab temporary creds
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
