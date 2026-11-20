#!/usr/bin/env bash
set -euo pipefail

# Guards deploy_policy_mode in tf/cloud-provision (#147, #194).
#
# The test copies the real cloud-provision stage, with the AWS templates
# activated as _selectCloudFiles() does and the generated policies beside it,
# into a scratch tree. The tf-modules bootstrap module is replaced by a stub
# that returns its deploy_policy_json, and the providers are mocked. Then
# `terraform test` checks:
#   1. admin (default) keeps the admin-equivalent body and writes no
#      iam_scope file; it makes the workload boundary only with stack_project
#      (so a project moved back from scoped keeps it);
#   2. scoped attaches the generated policy, known at plan (the bootstrap
#      module counts on it), with every placeholder filled,
#      within the IAM size limit, and denies changing the deploy role, its
#      policy and the boundary;
#   3. scoped makes <stack_project>-workload-boundary off the project path
#      and writes iam_scope.auto.tfvars.json for the composed stack;
#   4. scoped without stack_project fails, and so does an unknown mode.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="${TERRAFORM:-terraform}"
FIXTURES="$ROOT/tests/fixtures/deploy-policy-mode"

if ! command -v "$TF" >/dev/null 2>&1; then
  echo "FAIL: terraform not found (set TERRAFORM)" >&2
  exit 1
fi

work="$(mktemp -d)"
cleanup() { rm -rf -- "${work:?}"; }
trap cleanup EXIT

stage="$work/tf/cloud-provision"
mkdir -p "$stage/tests" "$work/tf/account-setup" "$work/tf/auto-vars"
cp -R "$ROOT/tf/account-setup/policies" "$work/tf/account-setup/policies"
for f in main.tf repo.tf vars.tf unused-vars.tf providers.tf versions.tf backend.tf.tftpl; do
  cp "$ROOT/tf/cloud-provision/$f" "$stage/$f"
done
cp "$ROOT/tf/cloud-provision/providers-aws.tf.tmpl" "$stage/providers-aws.tf"
cp "$ROOT/tf/cloud-provision/aws-resources.tf.tmpl" "$stage/aws-resources.tf"

# The bootstrap module comes from GitHub. The stub keeps the test offline and
# shows what the stage passes to it.
src='source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-bootstrap?ref='
if ! grep -qF "$src" "$stage/aws-resources.tf"; then
  echo "FAIL: module \"bootstrap\" source not found in aws-resources.tf.tmpl" >&2
  exit 1
fi
sed 's#source = "github.com/luthersystems/tf-modules.git//aws-platform-ui-bootstrap?ref=[^"]*"#source = "./stub-bootstrap"#' \
  "$stage/aws-resources.tf" >"$stage/aws-resources.tf.new"
mv "$stage/aws-resources.tf.new" "$stage/aws-resources.tf"
# The scoped run applies (to check the boundary and the iam_scope file), and
# `terraform test` destroys what it applied; prevent_destroy on the inspector
# role would stop that.
sed 's/prevent_destroy = true/prevent_destroy = false/' "$stage/aws-resources.tf" >"$stage/aws-resources.tf.new"
mv "$stage/aws-resources.tf.new" "$stage/aws-resources.tf"
cp -R "$FIXTURES/stub-bootstrap" "$stage/stub-bootstrap"
cp "$FIXTURES/mode.tftest.hcl" "$stage/tests/mode.tftest.hcl"

cd "$stage"
"$TF" init -backend=false -input=false >/dev/null
"$TF" test
