#!/usr/bin/env bash
set -euo pipefail

# Guards the durable GCP management identity in
# tf/cloud-provision/gcp-resources.tf.tmpl (issue #63, luthersystems/reliable#664).
#
# Why this test exists: ui-core runs post-bootstrap plan/apply/redeploy for a
# GCP project by impersonating a project-scoped management service account. It
# finds that account through the cloud-provision outputs gcp_management_sa_email
# and gcp_management_sa_id. If a later change renames the account, drops the
# owner or token-creator grant, or drops an output, that path breaks for every
# new GCP project, and nothing in this repo would notice.
#
# What this test does NOT prove: that management survives loss of the uploaded
# key. The token-creator grant goes to that key's client_email, and ui-core
# still uses the key as the source credential for the impersonation. Removing
# that dependency needs a keyless source identity (issue #64).
#
# The test copies the real GCP stage file into a scratch module with mock
# providers and the stage's own lock file, and runs `terraform test`. It checks:
#   1. the management account ID is deterministic from short_project_id and is
#      distinct from the inspector ID; both IDs fit the GCP 30-character limit
#      (the inspector ID is the longer one, so it is the one near the limit);
#   2. the management account has roles/owner on the project;
#   3. the deployment identity (client_email of the uploaded key) can mint
#      tokens for the management account, also when the steady-state
#      gcp_impersonate_service_account variable is set;
#   4. the outputs return the management account's email and ID;
#   5. the inspector account keeps roles/viewer and is not the management one.
# A static check also confirms prevent_destroy stays on each service account
# and IAM resource in the file: GCP soft-deletes service accounts for 30 days,
# so a delete-then-create would fail and leave the project without its durable
# identity (issues #104, #106).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
STAGE="$ROOT/tf/cloud-provision"
SRC="$STAGE/gcp-resources.tf.tmpl"

if ! command -v "$TF" >/dev/null 2>&1; then
  echo "FAIL: terraform not found (set TERRAFORM)" >&2
  exit 1
fi

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- Static check: prevent_destroy on each SA / IAM resource ---------------
# Find every google_service_account, google_project_iam_member and
# google_service_account_iam_member block, read it up to its closing brace at
# column 0, and look for an uncommented `prevent_destroy = true` in it. The
# list comes from the file, so a new resource of these types must carry
# prevent_destroy too.
mapfile -t sa_iam_resources < <(sed -nE \
  's/^resource "(google_service_account|google_project_iam_member|google_service_account_iam_member)" "([A-Za-z0-9_-]+)" \{.*/\1 \2/p' \
  "$SRC")
# 9 such resources exist today (inspector and management). Fewer means the
# pattern stopped matching, not that the resources went away.
if [[ ${#sa_iam_resources[@]} -lt 9 ]]; then
  fail "found only ${#sa_iam_resources[@]} service account / IAM resources; expected at least 9"
fi
for entry in "${sa_iam_resources[@]}"; do
  type="${entry%% *}"
  rname="${entry##* }"
  block="$(awk -v r="resource \"$type\" \"$rname\" {" '
    index($0, r) == 1 { on = 1 }
    on { print }
    on && /^}/ { exit }
  ' "$SRC")"
  if [[ -z "$block" ]]; then
    fail "resource $type.$rname block not found"
  elif grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' <<<"$block"; then
    pass "resource $type.$rname has prevent_destroy"
  else
    fail "resource $type.$rname has no prevent_destroy"
  fi
done
for want in insideout_management management_owner management_token_creator; do
  if ! printf '%s\n' "${sa_iam_resources[@]}" | grep -q " ${want}\$"; then
    fail "management resource $want is missing"
  fi
done

# --- terraform test against the real stage file ----------------------------
# _selectCloudFiles() (shell_utils.sh) copies the .tmpl onto its .tmpl-less
# name at deploy time, so copy it the same way. terraform test destroys what
# each run applied when the file ends, and prevent_destroy refuses that
# destroy. The static check above already pins prevent_destroy, so turn it off
# in the scratch copy only.
sed -E 's/prevent_destroy([[:space:]]*)=([[:space:]]*)true/prevent_destroy\1=\2false/' \
  "$SRC" >"$work/gcp-resources.tf"
cp "$STAGE/backend-gcs.tf.tftpl" "$work/backend-gcs.tf.tftpl"
cp "$STAGE/vars.tf" "$work/vars.tf"
cp "$STAGE/unused-vars.tf" "$work/unused-vars.tf"

# Use the stage's lock file so init picks the same provider versions as a
# deploy (google 6.10.0). gcp-resources.tf uses only google and local, so the
# stub requires just those two instead of copying providers-gcp.tf.tmpl.
cp "$STAGE/.terraform.lock.hcl" "$work/.terraform.lock.hcl"
cat >"$work/stub.tf" <<'EOF'
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.1"
    }
  }
}
EOF

# The uploaded key is only read for its client_email, so a minimal JSON is
# enough. base64 -w0 is GNU-only; strip newlines instead for macOS.
creds_b64="$(printf '%s' '{"client_email":"deployer@cust-proj.iam.gserviceaccount.com"}' | base64 | tr -d '\n')"

mkdir -p "$work/tests"
cat >"$work/tests/mgmt.tftest.hcl" <<EOF
mock_provider "google" {
  # Fixed emails so the assertions below can compare exact values.
  override_resource {
    target = google_service_account.insideout_management
    values = {
      email = "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
      name  = "projects/cust-proj/serviceAccounts/insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    }
  }
  override_resource {
    target = google_service_account.insideout_inspector
    values = {
      email = "insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
      name  = "projects/cust-proj/serviceAccounts/insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
    }
  }
}
mock_provider "local" {}

variables {
  domain              = "example.com"
  short_project_id    = "abcd1234"
  project_id          = "abcd1234-project"
  cloud_provider      = "gcp"
  gcp_project_id      = "cust-proj"
  gcp_region          = "us-central1"
  gcp_credentials_b64 = "${creds_b64}"
}

run "management_identity" {
  command = apply

  assert {
    condition     = google_service_account.insideout_management.account_id == "insideout-mgmt-abcd1234"
    error_message = "management account ID is not insideout-mgmt-<short_project_id>; ui-core derives it from that name"
  }

  assert {
    condition     = length(google_service_account.insideout_management.account_id) <= 30
    error_message = "management account ID is longer than the GCP limit of 30 characters"
  }

  # The inspector ID is 28 characters for an 8-character short_project_id, so
  # a longer prefix shows up here first.
  assert {
    condition     = length(google_service_account.insideout_inspector.account_id) <= 30
    error_message = "inspector account ID is longer than the GCP limit of 30 characters"
  }

  assert {
    condition     = google_service_account.insideout_management.account_id != google_service_account.insideout_inspector.account_id
    error_message = "management and inspector accounts must be separate identities"
  }

  assert {
    condition     = google_service_account.insideout_management.project == "cust-proj"
    error_message = "management account is not in the customer's GCP project"
  }

  assert {
    condition     = google_project_iam_member.management_owner.role == "roles/owner" && google_project_iam_member.management_owner.project == "cust-proj"
    error_message = "management account must hold roles/owner on the customer's project for steady-state plan/apply"
  }

  assert {
    condition     = google_project_iam_member.management_owner.member == "serviceAccount:insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "roles/owner is not granted to the management account"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.role == "roles/iam.serviceAccountTokenCreator"
    error_message = "management token-creator grant has the wrong role"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.member == "serviceAccount:deployer@cust-proj.iam.gserviceaccount.com"
    error_message = "the deployment identity (client_email of the uploaded key) cannot impersonate the management account"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.service_account_id == google_service_account.insideout_management.name
    error_message = "token-creator grant is not on the management account"
  }

  assert {
    condition     = output.gcp_management_sa_email == "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "output gcp_management_sa_email does not return the management account email"
  }

  assert {
    condition     = output.gcp_management_sa_id == "insideout-mgmt-abcd1234"
    error_message = "output gcp_management_sa_id does not return the management account ID"
  }

  # The inspector must stay read-only and unchanged (issue #63 acceptance).
  assert {
    condition     = google_project_iam_member.inspector_viewer.role == "roles/viewer" && google_project_iam_member.inspector_viewer.member == "serviceAccount:insideout-inspector-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "inspector account lost roles/viewer"
  }

  assert {
    condition     = output.gcp_inspector_sa_email != output.gcp_management_sa_email
    error_message = "inspector and management outputs point at the same account"
  }
}

# Steady state: later runs set gcp_impersonate_service_account to the
# management account. The grant must still go to the uploaded key's identity,
# not to the impersonated account, or the impersonation chain would have no
# source credential that holds the grant.
run "steady_state_impersonation" {
  command = apply

  variables {
    gcp_impersonate_service_account = "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_service_account_iam_member.management_token_creator.member == "serviceAccount:deployer@cust-proj.iam.gserviceaccount.com"
    error_message = "with impersonation set, the token-creator grant no longer goes to the uploaded key's client_email"
  }

  assert {
    condition     = output.gcp_management_sa_email == "insideout-mgmt-abcd1234@cust-proj.iam.gserviceaccount.com"
    error_message = "with impersonation set, output gcp_management_sa_email changed"
  }
}
EOF

cd "$work"
if ! init_out="$("$TF" init -backend=false -input=false 2>&1)"; then
  echo "$init_out" >&2
  fail "terraform init of the scratch module"
elif "$TF" test; then
  pass "terraform test: management identity, grants and outputs"
else
  fail "terraform test: management identity, grants and outputs"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]]
