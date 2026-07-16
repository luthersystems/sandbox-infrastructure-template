#!/usr/bin/env bash
set -euo pipefail

# Guards the AWS *provider* region invariant across every provisioning stage,
# and the downstream remote-state region invariant.
#
# INVARIANT (Check 1): an AWS `provider "aws"` block's `region =` must resolve
# to the project's own resource region (var.aws_region) or a hard-coded region
# literal (e.g. "us-east-1" for CloudFront/WAF, "us-west-2" for the GCP-path
# fallback). It must NEVER be var.bootstrap_state_region.
#
# WHY — do NOT "fix" a region mismatch by switching the provider to
# bootstrap_state_region. That exact change was made in PR #77 and reverted in
# PR #79; issue #75 proposes it again (option 2). It is unsound:
#   * aws_region is PER-PROJECT. ui-core sends it from cloudArgs.AWSRegion —
#     the region the customer's resources (EKS, KMS, Route53, and the
#     per-project state bucket module.bootstrap creates) actually live in.
#   * bootstrap_state_region is a PLATFORM CONSTANT. ui-core sends it from
#     s.config.BootstrapStateRegion — the region of the shared *environment
#     bootstrap* state bucket. It is identical for every project the platform
#     deploys (see ui-core jobs/workflows/workflows.go).
#   These two agree only when a project happens to be deployed in the platform's
#   bootstrap region; they DIVERGE for any cross-region project. Pointing the
#   provider at bootstrap_state_region would create/read the customer's
#   resources in the platform's region instead of the customer's — a much
#   broader breakage than the corrupted-aws_region case #75 describes (which is
#   repaired at the data source by ui-core's --force-region, PR #264).
#
# Only backend / remote-state *state-access* configs use bootstrap_state_region
# (the separate, correct fix from PR #73), because the platform bootstrap state
# bucket genuinely lives in the platform region. Check 2 covers the one
# remote-state read that instead targets a PER-PROJECT bucket (vm-provision's
# state), which must take its region from the cloud-provision output.
#
# History note: this guard originally hard-coded cloud-provision/providers.tf,
# but the AWS provider block moved to providers-aws.tf.tmpl in PR #92. The old
# guard then greped a file that no longer holds a provider region and silently
# passed. Check 1 now scans every provider-declaration file and asserts the
# known hot-spot file exists, so a future rename fails loudly instead of
# dropping the guard.

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$SCRIPT_DIR/tf"

# --- Check 1: AWS provider region must not use bootstrap_state_region ---
echo "Check 1: AWS provider region must not use bootstrap_state_region..."

c1_fail=0

# The cloud-provision AWS provider is the historical hot spot (issue #75). It
# lives in a .tf.tmpl activated by _selectCloudFiles() at deploy time, so assert
# it explicitly: a future rename must update this list, not silently drop the
# guard.
REQUIRED_PROVIDER_FILES=(
  "cloud-provision/providers-aws.tf.tmpl"
)

for rel in "${REQUIRED_PROVIDER_FILES[@]}"; do
  if [[ ! -f "$TF_DIR/$rel" ]]; then
    fail "required provider file missing: tf/$rel (renamed? update this guard)"
    c1_fail=1
  fi
done

# Scan every provider-declaration file in every stage (.tf and .tf.tmpl).
shopt -s nullglob
provider_files=("$TF_DIR"/*/providers*.tf "$TF_DIR"/*/providers*.tf.tmpl)
shopt -u nullglob

if [[ ${#provider_files[@]} -eq 0 ]]; then
  fail "no provider files found under tf/*/ (glob may be wrong)"
  c1_fail=1
fi

for pf in "${provider_files[@]}"; do
  # A provider-block 'region =' line that references bootstrap_state_region is
  # the bug pattern.
  bad_lines="$(grep -nE 'region[[:space:]]*=' "$pf" \
    | grep 'bootstrap_state_region' || true)"
  if [[ -n "$bad_lines" ]]; then
    fail "${pf#"$TF_DIR"/}: provider region uses bootstrap_state_region (must be var.aws_region or a region literal):"
    echo "$bad_lines" | sed 's/^/         /'
    c1_fail=1
  fi
done

if [[ $c1_fail -eq 0 ]]; then
  pass "all ${#provider_files[@]} provider files: region uses var.aws_region / region literal (never bootstrap_state_region)"
fi

# --- Check 2: Downstream remote-state data sources ---
echo ""
echo "Check 2: per-project remote-state region references..."

# These files contain terraform_remote_state blocks that read state created by
# an EARLIER stage into a PER-PROJECT bucket (which lives in var.aws_region, not
# the platform bootstrap region). Their region must come from the upstream
# stage's output, not bare var.aws_region.
#
# NOTE: the *cloud-provision-state.tf files (which read cloud-provision's OWN
# state from the platform bootstrap bucket) correctly use
# var.bootstrap_state_region and are intentionally NOT listed here.
STATE_FILES=(
  "k8s-provision/vm-provision-state.tf"
)

for rel_path in "${STATE_FILES[@]}"; do
  state_file="$TF_DIR/$rel_path"

  if [[ ! -f "$state_file" ]]; then
    fail "$rel_path: file not found"
    continue
  fi

  bad_lines="$(grep -nE 'region[[:space:]]*=' "$state_file" \
    | grep 'var\.aws_region' || true)"

  if [[ -z "$bad_lines" ]]; then
    pass "$rel_path: region references upstream stage output (not bare var.aws_region)"
  else
    fail "$rel_path: uses var.aws_region for state region (should use upstream stage output):"
    echo "$bad_lines" | sed 's/^/         /'
  fi
done

# --- Summary ---
echo ""
echo "================================"
echo "  $PASS passed, $FAIL failed"
echo "================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
