#!/usr/bin/env bash
set -euo pipefail

# Guards the durable GCP management identity in
# tf/cloud-provision/gcp-resources.tf.tmpl (issue #63, luthersystems/reliable#664).
#
# Why this test exists: after bootstrap, the uploaded GCP key can expire or be
# revoked. Oracle must then plan/apply/redeploy as a project-scoped management
# service account that it impersonates. ui-core finds that account through the
# cloud-provision outputs gcp_management_sa_email and gcp_management_sa_id. If
# a later change renames the account, drops the token-creator grant, or drops
# an output, post-bootstrap management of every new GCP project breaks, and
# nothing in this repo would notice. The inspector account must also stay
# read-only and separate from the management account.
#
# The test copies the real GCP stage files into a scratch module with mock
# providers and runs `terraform test`. It checks:
#   1. the management account ID is deterministic from short_project_id, is
#      distinct from the inspector ID, and fits the GCP 30-character limit;
#   2. the management account has roles/owner on the project;
#   3. the deployment identity (client_email of the uploaded key) can mint
#      tokens for the management account;
#   4. the outputs return the management account's email and ID;
#   5. the inspector account keeps roles/viewer and is not the management one.
# A static check also confirms prevent_destroy stays on each management
# resource: GCP soft-deletes service accounts for 30 days, so a delete-then-
# create would fail and leave the project without its durable identity
# (issues #104, #106).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
STAGE="$ROOT/tf/cloud-provision"

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

# --- Static check: prevent_destroy on each management resource -------------
# Read the block of each resource up to its closing brace at column 0 and look
# for prevent_destroy = true inside it.
for res in \
  'google_service_account" "insideout_management' \
  'google_project_iam_member" "management_owner' \
  'google_service_account_iam_member" "management_token_creator'; do
  block="$(awk -v r="resource \"$res\"" '
    index($0, r) == 1 { on = 1 }
    on { print }
    on && /^}/ { exit }
  ' "$STAGE/gcp-resources.tf.tmpl")"
  name="${res//\" \"/.}"
  if [[ -z "$block" ]]; then
    fail "resource $name is missing"
  elif grep -Eq 'prevent_destroy[[:space:]]*=[[:space:]]*true' <<<"$block"; then
    pass "resource $name has prevent_destroy"
  else
    fail "resource $name has no prevent_destroy"
  fi
done

# --- terraform test against the real stage files ---------------------------
# The .tmpl files are what _selectCloudFiles() (shell_utils.sh) copies onto
# their .tmpl-less names at deploy time, so copy them the same way.
# terraform test destroys what each run applied when the file ends, and
# prevent_destroy refuses that destroy. The static check above already pins
# prevent_destroy, so turn it off in the scratch copy only.
sed -E 's/prevent_destroy([[:space:]]*)=([[:space:]]*)true/prevent_destroy\1=\2false/' \
  "$STAGE/gcp-resources.tf.tmpl" >"$work/gcp-resources.tf"
cp "$STAGE/providers-gcp.tf.tmpl" "$work/providers-gcp.tf"
cp "$STAGE/backend-gcs.tf.tftpl" "$work/backend-gcs.tf.tftpl"
cp "$STAGE/vars.tf" "$work/vars.tf"
cp "$STAGE/unused-vars.tf" "$work/unused-vars.tf"

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
mock_provider "random" {}
mock_provider "tls" {}
mock_provider "github" {}
mock_provider "time" {}

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
EOF

cd "$work"
"$TF" init -backend=false -input=false >/dev/null
if "$TF" test; then
  pass "terraform test: management identity, grants and outputs"
else
  fail "terraform test: management identity, grants and outputs"
fi

echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]]
