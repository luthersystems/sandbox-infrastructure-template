#!/usr/bin/env bash
set -euo pipefail

# Tests for keyless GCP deploys in setupGCPCredentials (shell_utils.sh),
# luthersystems/ui-core#153.
#
# ui-core names the customer's deploy service account in the tfvar
# gcp_deploy_service_account and writes, as gcp_credentials_b64, an
# external_account credential that impersonates it through the platform's
# deploy workload identity pool. Google's client libraries read the pod's AWS
# session for it only from AWS_* env vars, but ui-core's scope-aws init
# container gives the pod that session as a shared credentials file. So
# setupGCPCredentials must export the session from the file, accept the
# external_account credential only when it impersonates the named account,
# keep refusing a non-key credential without the variable, and skip the key
# preflight. cleanupCloudEnv unsets what it exported and puts back what it replaced.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for tool in jq aws; do
  if ! command -v "$tool" &>/dev/null; then
    echo "SKIP: $tool is required for these tests" >&2
    exit 0
  fi
done

PROJECT="$WORKDIR/project"
mkdir -p "$PROJECT/tf/auto-vars" "$PROJECT/tf/cloud-provision" "$PROJECT/tf/vm-provision"
mkdir -p "$PROJECT/ansible/inventories/default/group_vars/all"
echo "environment: test" >"$PROJECT/ansible/inventories/default/group_vars/all/env.yaml"
cp "$REPO_ROOT/shell_utils.sh" "$PROJECT/shell_utils.sh"

# Stub preflight: records that it ran.
PREFLIGHT_LOG="$WORKDIR/preflight.log"
cat >"$PROJECT/tf/gcp-preflight.sh" <<EOF
#!/usr/bin/env bash
echo "preflight project=\${1:-}" >> "$PREFLIGHT_LOG"
exit 0
EOF

SA="deployer@cust-proj.iam.gserviceaccount.com"
OTHER_SA="someone@cust-proj.iam.gserviceaccount.com"
AUDIENCE="//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/insideout-deploy-test/providers/aws-terraform"

# external_account <service account>: the credential ui-core writes
# (jobs/workflows/gcp_wif.go GCPDeployWIFCredentialB64), base64.
external_account() {
  jq -cn --arg aud "$AUDIENCE" --arg sa "$1" '{
    type: "external_account",
    audience: $aud,
    subject_token_type: "urn:ietf:params:aws:token-type:aws4_request",
    token_url: "https://sts.googleapis.com/v1/token",
    service_account_impersonation_url: ("https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/" + $sa + ":generateAccessToken"),
    credential_source: {
      environment_id: "aws1",
      regional_cred_verification_url: "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    }
  }' | base64 | tr -d '\n'
}

# A key with only the fields the template reads. Built, not a literal: the
# secrets scan reads a literal key as a leak.
service_account_key() {
  jq -cn --arg sa "$SA" '{type: "service_account", client_email: $sa}' | base64 | tr -d '\n'
}

# The file ui-core's scope-aws init container writes (aws_scope.sh).
CREDS_FILE="$WORKDIR/aws-credentials"
cat >"$CREDS_FILE" <<'EOF'
[default]
aws_access_key_id = ASIAEXAMPLEKEY
aws_secret_access_key = example-secret/value=
aws_session_token = example-session-token
EOF

# tfvars <credential b64> <deploy service account>
tfvars() {
  jq -cn --arg c "$1" --arg sa "$2" '{
    cloud_provider: "gcp",
    gcp_project_id: "cust-proj",
    gcp_region: "us-central1",
    gcp_credentials_b64: $c,
    gcp_deploy_service_account: $sa
  }'
}

# run_setup <stage> <tfvars-json> [env assignments...]: runs setupCloudEnv,
# then prints the AWS env it left, then runs cleanupCloudEnv and prints the
# env again. Each line is "key=value"; the last is "rc=<code>".
run_setup() {
  local stage="$1" vars="$2"
  shift 2
  echo "$vars" >"$PROJECT/tf/auto-vars/common.auto.tfvars.json"
  : >"$PREFLIGHT_LOG"
  (
    cd "$PROJECT/tf/$stage"
    unset JUMP_ROLE_ARN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION
    unset AWS_SHARED_CREDENTIALS_FILE AWS_PROFILE GOOGLE_APPLICATION_CREDENTIALS
    export MARS_PROJECT_ROOT="$PROJECT"
    for kv in "$@"; do export "${kv?}"; done
    # shellcheck disable=SC1091
    source "$PROJECT/shell_utils.sh"
    rc=0
    setupCloudEnv 2>&1 || rc=$?
    echo "after_setup_key=${AWS_ACCESS_KEY_ID:-}"
    echo "after_setup_secret=${AWS_SECRET_ACCESS_KEY:-}"
    echo "after_setup_token=${AWS_SESSION_TOKEN:-}"
    echo "after_setup_region=${AWS_REGION:-}"
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" && -f "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
      echo "gac_type=$(jq -r .type "$GOOGLE_APPLICATION_CREDENTIALS")"
    fi
    cleanupCloudEnv >/dev/null 2>&1 || true
    echo "after_cleanup_key=${AWS_ACCESS_KEY_ID:-}"
    echo "rc=$rc"
  )
}

echo "=== keyless GCP credential tests (ui-core#153) ==="

echo ""
echo "Test 1: a keyless deploy exports the scoped AWS session and skips the key preflight"
out=$(run_setup cloud-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_PROFILE=default AWS_REGION=us-west-2)
if grep -qx "rc=0" <<<"$out"; then pass "setupCloudEnv returns 0"; else fail "setupCloudEnv failed: $out"; fi
if grep -qx "gac_type=external_account" <<<"$out"; then pass "GOOGLE_APPLICATION_CREDENTIALS is the external_account credential"; else fail "credential file not set: $out"; fi
if grep -qx "after_setup_key=ASIAEXAMPLEKEY" <<<"$out" &&
  grep -qx "after_setup_secret=example-secret/value=" <<<"$out" &&
  grep -qx "after_setup_token=example-session-token" <<<"$out"; then
  pass "AWS session exported from the shared credentials file"
else
  fail "AWS session not exported: $out"
fi
if grep -qx "after_setup_region=us-west-2" <<<"$out"; then pass "AWS_REGION kept"; else fail "AWS_REGION: $out"; fi
if [[ ! -s "$PREFLIGHT_LOG" ]]; then pass "key preflight skipped"; else fail "key preflight ran for a keyless deploy"; fi
if grep -q "skipped for a keyless deploy" <<<"$out"; then pass "skip is logged"; else fail "skip not logged: $out"; fi
if grep -qx "after_cleanup_key=" <<<"$out"; then pass "cleanupCloudEnv unsets the exported session"; else fail "session left after cleanup: $out"; fi
if grep -v '^after_setup_' <<<"$out" | grep -q "ASIAEXAMPLEKEY\|example-secret\|example-session-token"; then
  fail "credentials echoed in the log"
else
  pass "credentials not echoed"
fi

echo ""
echo "Test 2: AWS_DEFAULT_REGION alone is enough (Google's AWS source reads it)"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_DEFAULT_REGION=eu-west-2)
if grep -qx "rc=0" <<<"$out"; then pass "accepted with AWS_DEFAULT_REGION"; else fail "region fallback: $out"; fi
if grep -qx "after_setup_region=" <<<"$out"; then pass "AWS_REGION not set as a side effect"; else fail "AWS_REGION leaked: $out"; fi

echo ""
echo "Test 3: without a credentials file, a session already in the env is used and not unset"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_REGION=us-west-2 AWS_ACCESS_KEY_ID=ASIAENVKEY AWS_SECRET_ACCESS_KEY=envsecret)
if grep -qx "rc=0" <<<"$out" && grep -qx "after_setup_key=ASIAENVKEY" <<<"$out"; then
  pass "env session used"
else
  fail "env session: $out"
fi
if grep -qx "after_cleanup_key=ASIAENVKEY" <<<"$out"; then pass "env session left in place by cleanup"; else fail "cleanup removed a session it did not export: $out"; fi

echo ""
echo "Test 3b: the credentials file wins over an env key pair, which cleanup puts back"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2 AWS_ACCESS_KEY_ID=AKIASTALE AWS_SECRET_ACCESS_KEY=stalesecret)
if grep -qx "rc=0" <<<"$out" && grep -qx "after_setup_key=ASIAEXAMPLEKEY" <<<"$out"; then
  pass "scoped session from the file used"
else
  fail "file not preferred: $out"
fi
if grep -qx "after_cleanup_key=AKIASTALE" <<<"$out"; then pass "earlier env key pair restored"; else fail "env key pair not restored: $out"; fi

echo ""
echo "Test 4: a keyless deploy without the scoped session is refused"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" AWS_REGION=us-west-2)
if grep -qx "rc=1" <<<"$out" && grep -q "AWS_SHARED_CREDENTIALS_FILE" <<<"$out"; then
  pass "refused, names AWS_SHARED_CREDENTIALS_FILE"
else
  fail "no scoped session: $out"
fi

echo ""
echo "Test 5: a keyless deploy without a region is refused"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE")
if grep -qx "rc=1" <<<"$out" && grep -q "AWS_REGION" <<<"$out"; then pass "refused, names AWS_REGION"; else fail "no region: $out"; fi

echo ""
echo "Test 6: a credential that impersonates another account is refused"
out=$(run_setup cloud-provision "$(tfvars "$(external_account "$OTHER_SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2)
if grep -qx "rc=1" <<<"$out" && grep -q "ui-core#153" <<<"$out"; then pass "refused"; else fail "mismatch accepted: $out"; fi
if grep -qx "after_setup_key=" <<<"$out"; then pass "no session exported"; else fail "session exported on a refused credential: $out"; fi

echo ""
echo "Test 7: a key with gcp_deploy_service_account set is refused"
out=$(run_setup cloud-provision "$(tfvars "$(service_account_key)" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2)
if grep -qx "rc=1" <<<"$out"; then pass "refused"; else fail "key accepted as keyless: $out"; fi

echo ""
echo "Test 8: an external_account credential without gcp_deploy_service_account is refused"
out=$(run_setup cloud-provision "$(tfvars "$(external_account "$SA")" "")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2)
if grep -qx "rc=1" <<<"$out" && grep -q "Invalid service account key format" <<<"$out"; then pass "refused"; else fail "external_account accepted as a key: $out"; fi

echo ""
echo "Test 9: a key deploy is unchanged: the preflight runs and no AWS session is exported"
out=$(run_setup cloud-provision "$(tfvars "$(service_account_key)" "")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2)
if grep -qx "rc=0" <<<"$out" && grep -qx "gac_type=service_account" <<<"$out"; then pass "key deploy configured"; else fail "key deploy: $out"; fi
if grep -q "preflight project=cust-proj" "$PREFLIGHT_LOG"; then pass "key preflight ran"; else fail "key preflight did not run"; fi
if grep -qx "after_setup_key=" <<<"$out"; then pass "no AWS session exported"; else fail "session exported for a key deploy: $out"; fi

echo ""
echo "Test 10: another profile of the credentials file is read"
cat >"$WORKDIR/multi" <<'EOF'
[default]
aws_access_key_id=ASIADEFAULT
aws_secret_access_key=defaultsecret

[scoped]
aws_access_key_id=ASIASCOPED
aws_secret_access_key=scopedsecret
EOF
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$WORKDIR/multi" AWS_PROFILE=scoped AWS_REGION=us-west-2)
if grep -qx "after_setup_key=ASIASCOPED" <<<"$out" && grep -qx "after_setup_token=" <<<"$out"; then
  pass "profile scoped read, no session token"
else
  fail "profile: $out"
fi

echo ""
echo "Test 11: JUMP_ROLE_ARN is refused on a keyless deploy (it would replace the signing session)"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2 JUMP_ROLE_ARN=arn:aws:iam::111111111111:role/jump)
if grep -qx "rc=1" <<<"$out" && grep -q "JUMP_ROLE_ARN" <<<"$out"; then pass "refused, names JUMP_ROLE_ARN"; else fail "jump role: $out"; fi

echo ""
echo "Test 12: the session is read with the AWS CLI the mars image ships (2.7.0)"
# The mars image pins AWS CLI 2.7.0 (mars Makefile AWSCLI_VERSION), which has
# no "aws configure export-credentials" (added in 2.9). The first keyless
# deploy on test failed on it: "cannot read the AWS session of profile
# default". This shim answers that subcommand as 2.7.0 does, so a read that
# needs a newer CLI fails here and not in a customer's deploy.
mkdir -p "$WORKDIR/oldcli"
REAL_AWS=$(command -v aws)
cat >"$WORKDIR/oldcli/aws" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == configure && "\$2" == export-credentials ]]; then
  echo "aws: error: argument subcommand: Invalid choice" >&2
  exit 252
fi
exec "$REAL_AWS" "\$@"
EOF
chmod +x "$WORKDIR/oldcli/aws"
out=$(run_setup vm-provision "$(tfvars "$(external_account "$SA")" "$SA")" \
  AWS_SHARED_CREDENTIALS_FILE="$CREDS_FILE" AWS_REGION=us-west-2 PATH="$WORKDIR/oldcli:$PATH")
if grep -qx "after_setup_key=ASIAEXAMPLEKEY" <<<"$out" && grep -qx "after_setup_token=example-session-token" <<<"$out"; then
  pass "session read without export-credentials"
else
  fail "old CLI: $out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
