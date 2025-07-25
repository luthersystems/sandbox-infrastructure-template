#!/usr/bin/env bash

# if JUMP_ROLE_ARN is set, grab temporary creds
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
