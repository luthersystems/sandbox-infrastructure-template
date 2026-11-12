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
# The test copies the real GCP stage file into a scratch module with the
# fixture in tests/fixtures/gcp-management-identity/ (mock providers) and the
# stage's own lock file, and runs `terraform test`. It checks:
#   1. the management account ID is deterministic from short_project_id and is
#      distinct from the inspector ID; both IDs fit the GCP 30-character limit
#      (the inspector ID is the longer one, so it is the one near the limit);
#   2. the management account has roles/owner on the project;
#   3. the deployment identity (client_email of the uploaded key) can mint
#      tokens for the management account, also when the steady-state
#      gcp_impersonate_service_account variable is set;
#   4. the outputs return the management account's email and ID;
#   5. the inspector account keeps roles/viewer and is not the management one;
#   6. inspector_wif_principal_set (ui-core#157): empty grants nothing; a
#      principal set gets roles/iam.serviceAccountTokenCreator on the
#      inspector, and the deployment identity keeps its grant (the stored-key
#      fallback); a value that is not a principalSet:// URI fails validation.
# A static check also confirms prevent_destroy stays on each service account
# and IAM resource in the file: GCP soft-deletes service accounts for 30 days,
# so a delete-then-create would fail and leave the project without its durable
# identity (issues #104, #106). The one exception is the WIF grant, which must
# stay removable: the check confirms it has a count and no prevent_destroy.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
STAGE="$ROOT/tf/cloud-provision"
SRC="$STAGE/gcp-resources.tf.tmpl"
FIXTURE="$ROOT/tests/fixtures/gcp-management-identity"

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
# 10 such resources exist today (inspector and management). Fewer means the
# pattern stopped matching, not that the resources went away.
if [[ ${#sa_iam_resources[@]} -lt 10 ]]; then
  fail "found only ${#sa_iam_resources[@]} service account / IAM resources; expected at least 10"
fi
# Grants that a variable turns on and off. They are IAM members only (the
# service account they sit on keeps prevent_destroy), so removing one is safe.
# Each entry is "type name", so only that exact resource is exempt.
REMOVABLE_GRANTS=("google_service_account_iam_member inspector_wif_token_creator")
removable_seen=0
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
  elif printf '%s\n' "${REMOVABLE_GRANTS[@]}" | grep -qxF "$entry"; then
    # A removable grant must not carry prevent_destroy, or clearing its
    # variable would fail the plan. It must be optional (count).
    removable_seen=$((removable_seen + 1))
    if grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' <<<"$block"; then
      fail "removable grant $type.$rname has prevent_destroy"
    elif ! grep -Eq '^[[:space:]]*count[[:space:]]*=' <<<"$block"; then
      fail "removable grant $type.$rname has no count"
    else
      pass "removable grant $type.$rname has a count and no prevent_destroy"
    fi
  elif grep -Eq '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' <<<"$block"; then
    pass "resource $type.$rname has prevent_destroy"
  else
    fail "resource $type.$rname has no prevent_destroy"
  fi
done
if [[ $removable_seen -ne ${#REMOVABLE_GRANTS[@]} ]]; then
  fail "found $removable_seen of ${#REMOVABLE_GRANTS[@]} removable grants (${REMOVABLE_GRANTS[*]})"
fi
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

# The scratch module's provider block and the test file are real HCL files in
# tests/fixtures/gcp-management-identity/, so terraform fmt checks them. The
# stage's lock file makes init pick the same provider versions as a deploy.
cp "$STAGE/.terraform.lock.hcl" "$work/.terraform.lock.hcl"
cp "$FIXTURE/providers.tf" "$work/providers.tf"
mkdir -p "$work/tests"
cp "$FIXTURE/tests/mgmt.tftest.hcl" "$work/tests/mgmt.tftest.hcl"

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
