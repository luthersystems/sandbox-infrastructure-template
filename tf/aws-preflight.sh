#!/usr/bin/env bash
# shellcheck shell=bash
#
# aws-preflight.sh — Fail-fast AWS bootstrap-permission preflight.
#
# The AWS twin of tf/gcp-preflight.sh. Defense-in-depth guard for
# luthersystems/reliable#2243 (the Beatloom incident): a customer's
# under-privileged connecting credential passed credential validation and
# reached the `cloud-provision` Terraform apply, then 403'd mid-apply on a
# create action (on GCP it was storage.buckets.create / iam.serviceAccounts
# .create; the AWS analogue is s3:CreateBucket / iam:CreateRole) — AFTER the
# GitHub half of that apply (tf/cloud-provision/repo.tf) had already created a
# repo, deploy key, and Actions variables, leaving orphaned partial state.
#
# Upstream (reliable / ui-core) now feed Oracle a bootstrap action list so its
# plan-time preflight catches this, but the composed archive is driven from
# MANY caller paths (apply.sh / apply-with-outputs.sh / apply-plan.sh /
# plan-all.sh, all via setupCloudEnv). This script protects ALL of them from
# INSIDE the template: it runs BEFORE terraform creates anything and calls
# iam:SimulatePrincipalPolicy with the exact bootstrap action set, exiting
# non-zero with an actionable message when actions are denied.
#
# The action list below MIRRORS reliable's
# internal/agentapi/bootstrap_permissions.go :: bootstrapAWSIAMActions()
# (whose header cites this repo's tf/cloud-provision/aws-resources.tf.tmpl —
# this citation is the reciprocal). Keep the two lists in sync.
#
# s3:CreateBucket and iam:CreateRole are representative of the create actions a
# plan-only validation (#2243) would never exercise.
#
# ---------------------------------------------------------------------------
# Principal resolution — how the cloud-provision stage actually authenticates.
#
# tf/cloud-provision/providers-aws.tf.tmpl declares:
#
#   provider "aws" {
#     assume_role {
#       role_arn    = var.bootstrap_role
#       external_id = var.aws_external_id  (when non-empty)
#     }
#   }
#
# i.e. the ambient (IRSA / mars) credentials assume the customer's
# `bootstrap_role`, and THAT role is the principal that performs every create.
# So the faithful preflight is:
#
#   * bootstrap_role set  → `aws sts assume-role` it (with external id when
#     configured) using the ambient credentials, then run
#     `aws iam simulate-principal-policy --policy-source-arn <bootstrap_role>`
#     UNDER the assumed-role session credentials, so the customer account's IAM
#     answers. simulate takes the ROLE identity ARN as the policy source, which
#     is exactly what bootstrap_role already is.
#   * bootstrap_role empty → simulate against the ambient caller identity
#     (`aws sts get-caller-identity` .Arn), first mapping an assumed-role
#     SESSION arn back to the role IDENTITY arn simulate requires (the classic
#     gotcha: arn:aws:sts::ACCT:assumed-role/Name/session →
#     arn:aws:iam::ACCT:role/Name).
#
# Owner-parity note: unlike the GCP side, the AWS bootstrap stage does not grant
# a superuser role to another principal, so there is no AWS analogue of the GCP
# Owner-grant caveat — a clean simulate verdict is a complete verdict here.
#
# ---------------------------------------------------------------------------
# Semantics (mirrors ui-core aws_iam_preflight.go / aws_bootstrap_iam_preflight.go):
#   * FAIL CLOSED (exit 1):
#       - a SUCCESSFUL simulate that returns one or more non-"allowed" actions;
#       - an explicit AccessDenied on the ASSUME-ROLE itself (a trust-policy /
#         external-id problem that WILL fail the deploy — actionable, distinct
#         message).
#   * FAIL OPEN  (exit 0 + warning): any infrastructure / transport / "cannot
#     verify" condition — aws CLI absent, a TRANSIENT assume-role failure
#     (throttling / 5xx / network / expired ambient creds), any error from the
#     simulate call itself (including the caller lacking
#     iam:SimulatePrincipalPolicy — inability to verify is NOT proof of
#     insufficiency, reliable#2243), an unparseable body. The preflight must
#     NEVER block a deploy on its own flakiness.
#   * SKIP (exit 0 + notice): SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 operator override.
#
# Deliberately does NOT `set -e` (same rationale as gcp-preflight.sh): fail-open
# depends on catching non-zero exits inline, and an unexpected `set -e` abort
# would surface as a non-zero exit — which setupCloudEnv treats as fatal — i.e.
# the exact opposite of fail-open.
#
# Never echoes credentials/tokens: assumed-role session secrets are extracted
# into locals and passed into the simulate call's OWN environment only, never
# logged.
#
# Usage: bash aws-preflight.sh [<bootstrap_role_arn>]
#   bootstrap role arn resolves from: $1 -> $AWS_BOOTSTRAP_ROLE (empty ⇒
#     ambient-caller mode)
#   external id: $AWS_EXTERNAL_ID (optional; confused-deputy protection)
set -uo pipefail

# ----------------------------------------------------------------------------
# Required bootstrap actions — mirror of reliable
# bootstrap_permissions.go::bootstrapAWSIAMActions(). Grounded in
# tf/cloud-provision/aws-resources.tf.tmpl:
#   s3:CreateBucket / s3:PutBucket{Versioning,PublicAccessBlock,Policy} /
#   s3:PutEncryptionConfiguration / s3:GetBucketVersioning
#                                            module.bootstrap tfstate bucket
#   kms:CreateKey / kms:CreateAlias / kms:TagResource / kms:PutKeyPolicy /
#   kms:DescribeKey                          tfstate KMS key + alias
#   iam:CreateRole / iam:GetRole / iam:TagRole / iam:PutRolePolicy /
#   iam:AttachRolePolicy / iam:CreatePolicy / iam:PassRole
#                                            admin terraform role + inspector role
#   sts:AssumeRole                           admin role assumed by the terraform SA
#   sts:GetCallerIdentity                    AWS provider init
# ----------------------------------------------------------------------------
REQUIRED_ACTIONS=(
  iam:AttachRolePolicy
  iam:CreatePolicy
  iam:CreateRole
  iam:GetRole
  iam:PassRole
  iam:PutRolePolicy
  iam:TagRole
  kms:CreateAlias
  kms:CreateKey
  kms:DescribeKey
  kms:PutKeyPolicy
  kms:TagResource
  s3:CreateBucket
  s3:GetBucketVersioning
  s3:PutBucketPolicy
  s3:PutBucketPublicAccessBlock
  s3:PutBucketVersioning
  s3:PutEncryptionConfiguration
  sts:AssumeRole
  sts:GetCallerIdentity
)

# IAM/STS are global; us-east-1 is the always-reachable control-plane endpoint
# (matches ui-core's hardcoded us-east-1). Overridable for test flexibility.
PREFLIGHT_REGION="${AWS_PREFLIGHT_REGION:-us-east-1}"

log() { echo "[aws-preflight] $*"; }
err() { echo "[aws-preflight] $*" >&2; }

# fail_open <reason> — log a warning and exit 0. Never block a deploy on our
# own flakiness (tooling, network, throttling, inability to verify).
fail_open() {
  err "WARNING: $1"
  err "WARNING: preflight is advisory — continuing (deploy NOT blocked)."
  err "WARNING: set SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 to silence this check."
  exit 0
}

# Operator escape hatch.
if [[ "${SKIP_AWS_BOOTSTRAP_PREFLIGHT:-}" == "1" ]]; then
  log "SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 — skipping AWS bootstrap permission preflight."
  exit 0
fi

BOOTSTRAP_ROLE="${1:-${AWS_BOOTSTRAP_ROLE:-}}"
EXTERNAL_ID="${AWS_EXTERNAL_ID:-}"

# Test mode is active when either simulate output or an assume-role return code
# is injected. In test mode NO live aws binary is invoked, so the comparison /
# classification logic can be unit-tested with no cloud access or credentials.
#   AWS_PREFLIGHT_TEST_SIMULATE_FILE  path to a JSON file shaped like
#                                     `aws iam simulate-principal-policy` output
#                                     ({"EvaluationResults":[{EvalActionName,
#                                     EvalDecision},...]}).
#   AWS_PREFLIGHT_TEST_SIMULATE_RC    (default 0) non-zero ⇒ simulate call
#                                     "errored" ⇒ fail-open.
#   AWS_PREFLIGHT_TEST_ASSUME_RC      (default 0) non-zero ⇒ assume-role
#                                     "failed"; classified via ASSUME_ERR.
#   AWS_PREFLIGHT_TEST_ASSUME_ERR     stderr text the failed assume "returned".
TEST_MODE=0
if [[ -n "${AWS_PREFLIGHT_TEST_SIMULATE_FILE:-}" || -n "${AWS_PREFLIGHT_TEST_ASSUME_RC:-}" ]]; then
  TEST_MODE=1
fi

# classify_assume_failure <stderr-text> — decide fail-closed vs fail-open for a
# failed sts:assume-role, mirroring ui-core's semantics: an explicit AccessDenied
# (wrong trust policy or external id) WILL fail the deploy → fail CLOSED with a
# distinct, actionable message; anything else (throttling, 5xx, network, expired
# ambient creds) is not evidence of insufficiency → fail OPEN.
classify_assume_failure() {
  local errtext="$1"
  if grep -qiE 'AccessDenied|not authorized to perform:? *sts:assumerole' <<<"$errtext"; then
    err ""
    err "================================================================"
    err "AWS BOOTSTRAP PREFLIGHT FAILED — could not assume bootstrap role"
    err "${BOOTSTRAP_ROLE}: the assume-role call was explicitly DENIED (AccessDenied)."
    err ""
    err "This is a TRUST-POLICY or EXTERNAL-ID problem, not a missing deploy"
    err "permission. Fix on the customer side:"
    err "  - the role's trust policy must allow the connecting deployer principal"
    err "    to sts:AssumeRole it, and"
    err "  - the external id must match the one configured for this deployment"
    err "    (aws_external_id)."
    err "${errtext}"
    err ""
    err "Escape hatch: set SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 to bypass this check."
    err "Ref: luthersystems/reliable#2243."
    err "================================================================"
    exit 1
  fi
  fail_open "could not assume bootstrap role ${BOOTSTRAP_ROLE} (transient — throttling/5xx/network/expired creds): ${errtext:-<no detail>}"
}

# ----------------------------------------------------------------------------
# Phase 1 — resolve the policy-source ARN to simulate, assuming the bootstrap
# role when one is configured. Populates:
#   policy_source_arn  the IAM role/user identity ARN simulate evaluates
#   _AK / _SK / _ST    assumed-role session creds (role mode only; empty in
#                      ambient mode so simulate uses the ambient env creds)
# ----------------------------------------------------------------------------
policy_source_arn=""
_AK="" _SK="" _ST=""

if [[ -n "$BOOTSTRAP_ROLE" ]]; then
  # ---- role mode: assume the customer bootstrap role ----
  policy_source_arn="$BOOTSTRAP_ROLE"
  log "checking bootstrap actions against role ${BOOTSTRAP_ROLE} (assume-role${EXTERNAL_ID:+ +external-id})"

  if [[ "$TEST_MODE" -eq 1 ]]; then
    assume_rc="${AWS_PREFLIGHT_TEST_ASSUME_RC:-0}"
    if [[ "$assume_rc" != "0" ]]; then
      classify_assume_failure "${AWS_PREFLIGHT_TEST_ASSUME_ERR:-}"
    fi
    # else: assume "succeeded"; the simulate seam supplies the verdict below.
  else
    if ! command -v aws >/dev/null 2>&1; then
      fail_open "aws CLI not found on PATH — cannot run the permission simulation."
    fi
    assume_err_file="$(mktemp /tmp/aws-preflight-assume-err-XXXXXX 2>/dev/null || echo "")"
    assume_args=(sts assume-role
      --role-arn "$BOOTSTRAP_ROLE"
      --role-session-name "insideout-bootstrap-preflight"
      --duration-seconds 900
      --region "$PREFLIGHT_REGION"
      --output json)
    if [[ -n "$EXTERNAL_ID" ]]; then
      assume_args+=(--external-id "$EXTERNAL_ID")
    fi
    if ! assume_json="$(aws "${assume_args[@]}" 2>"${assume_err_file:-/dev/null}")"; then
      assume_err=""
      if [[ -n "$assume_err_file" && -f "$assume_err_file" ]]; then
        assume_err="$(cat "$assume_err_file" 2>/dev/null || echo "")"
      fi
      rm -f "${assume_err_file:-}" 2>/dev/null || true
      classify_assume_failure "$assume_err"
    fi
    rm -f "${assume_err_file:-}" 2>/dev/null || true
    # Extract session creds into locals only — never logged.
    _AK="$(jq -r '.Credentials.AccessKeyId // ""' <<<"$assume_json" 2>/dev/null || echo "")"
    _SK="$(jq -r '.Credentials.SecretAccessKey // ""' <<<"$assume_json" 2>/dev/null || echo "")"
    _ST="$(jq -r '.Credentials.SessionToken // ""' <<<"$assume_json" 2>/dev/null || echo "")"
    if [[ -z "$_AK" || -z "$_SK" || -z "$_ST" ]]; then
      fail_open "assume-role for ${BOOTSTRAP_ROLE} returned an incomplete credential set (treating as infra/transient)."
    fi
  fi
else
  # ---- ambient mode: simulate against the caller identity ----
  if [[ "$TEST_MODE" -eq 1 ]]; then
    policy_source_arn="arn:aws:iam::000000000000:role/test-ambient-principal"
  else
    if ! command -v aws >/dev/null 2>&1; then
      fail_open "aws CLI not found on PATH — cannot run the permission simulation."
    fi
    if ! caller_json="$(aws sts get-caller-identity --region "$PREFLIGHT_REGION" --output json 2>/dev/null)"; then
      fail_open "sts:GetCallerIdentity failed (no usable ambient credentials / transient)."
    fi
    caller_arn="$(jq -r '.Arn // ""' <<<"$caller_json" 2>/dev/null || echo "")"
    if [[ -z "$caller_arn" ]]; then
      fail_open "sts:GetCallerIdentity returned an empty ARN (treating as infra/transient)."
    fi
    # Map an assumed-role SESSION arn back to the role IDENTITY arn simulate
    # requires (path-less roles; assumed-role arns carry no role path). IAM
    # user / role identity arns pass through unchanged.
    if [[ "$caller_arn" =~ ^arn:([a-z-]+):sts::([0-9]+):assumed-role/([^/]+)/ ]]; then
      policy_source_arn="arn:${BASH_REMATCH[1]}:iam::${BASH_REMATCH[2]}:role/${BASH_REMATCH[3]}"
    elif [[ "$caller_arn" =~ ^arn:[a-z-]+:iam::[0-9]+:(user|role)/ ]]; then
      policy_source_arn="$caller_arn"
    else
      fail_open "caller identity ${caller_arn} is not an IAM user/role (federated/root?) — cannot resolve a simulate policy source."
    fi
    log "checking bootstrap actions against ambient caller identity ${policy_source_arn}"
  fi
fi

# ----------------------------------------------------------------------------
# Phase 2 — run iam:SimulatePrincipalPolicy (or the test seam) and capture the
# result body + return code. Any non-zero return from the simulate call itself
# is fail-open (inability to verify is not proof of insufficiency).
# ----------------------------------------------------------------------------
sim_json=""
sim_rc=0
sim_err=""

if [[ "$TEST_MODE" -eq 1 ]]; then
  sim_rc="${AWS_PREFLIGHT_TEST_SIMULATE_RC:-0}"
  if [[ "$sim_rc" == "0" && -n "${AWS_PREFLIGHT_TEST_SIMULATE_FILE:-}" && -f "$AWS_PREFLIGHT_TEST_SIMULATE_FILE" ]]; then
    sim_json="$(cat "$AWS_PREFLIGHT_TEST_SIMULATE_FILE")"
  fi
  sim_err="injected simulate rc=${sim_rc}"
  log "test seam active (AWS_PREFLIGHT_TEST_SIMULATE_FILE) simulate_rc=${sim_rc}"
else
  sim_err_file="$(mktemp /tmp/aws-preflight-sim-err-XXXXXX 2>/dev/null || echo "")"
  # Assumed-role session creds (role mode) are injected into the simulate
  # call's OWN environment only. In ambient mode _AK is empty and the call
  # inherits the process's ambient credentials.
  if [[ -n "$_AK" ]]; then
    sim_json="$(env \
      AWS_ACCESS_KEY_ID="$_AK" \
      AWS_SECRET_ACCESS_KEY="$_SK" \
      AWS_SESSION_TOKEN="$_ST" \
      aws iam simulate-principal-policy \
      --region "$PREFLIGHT_REGION" \
      --policy-source-arn "$policy_source_arn" \
      --action-names "${REQUIRED_ACTIONS[@]}" \
      --output json 2>"${sim_err_file:-/dev/null}")" || sim_rc=$?
  else
    sim_json="$(aws iam simulate-principal-policy \
      --region "$PREFLIGHT_REGION" \
      --policy-source-arn "$policy_source_arn" \
      --action-names "${REQUIRED_ACTIONS[@]}" \
      --output json 2>"${sim_err_file:-/dev/null}")" || sim_rc=$?
  fi
  if [[ -n "$sim_err_file" && -f "$sim_err_file" ]]; then
    sim_err="$(cat "$sim_err_file" 2>/dev/null || echo "")"
    rm -f "$sim_err_file"
  fi
fi

if [[ "$sim_rc" != "0" ]]; then
  # Any simulate error → fail open. Most likely the principal simply lacks
  # iam:SimulatePrincipalPolicy (reliable#2243: an otherwise-valid restricted
  # role would 403 here), or AWS was transiently unavailable. Not evidence of
  # insufficient deploy permissions.
  fail_open "iam:SimulatePrincipalPolicy call failed (cannot verify — the principal may lack iam:SimulatePrincipalPolicy, or a transient AWS error): ${sim_err:-<no detail>}"
fi

# ----------------------------------------------------------------------------
# Phase 3 — interpret the simulate result. Only a parseable body is a verdict.
# ----------------------------------------------------------------------------
if ! jq -e . >/dev/null 2>&1 <<<"$sim_json"; then
  fail_open "simulate returned an unparseable body (treating as infra/transient)."
fi

# Actions that came back exactly "allowed". Anything required but absent from
# this set (explicitDeny / implicitDeny / missing) is treated as denied.
allowed="$(jq -r '.EvaluationResults[]? | select(.EvalDecision=="allowed") | .EvalActionName' <<<"$sim_json" 2>/dev/null || echo "")"

denied=()
for action in "${REQUIRED_ACTIONS[@]}"; do
  if ! grep -qxF "$action" <<<"$allowed"; then
    denied+=("$action")
  fi
done

if [[ ${#denied[@]} -eq 0 ]]; then
  log "OK — principal ${policy_source_arn} is allowed all ${#REQUIRED_ACTIONS[@]} bootstrap actions."
  exit 0
fi

# --- fail closed: definitive denied-action verdict ---
err ""
err "================================================================"
err "AWS BOOTSTRAP PREFLIGHT FAILED — the principal"
err "${policy_source_arn} is missing ${#denied[@]} required IAM action(s):"
for action in "${denied[@]}"; do
  err "  - ${action}"
done
err ""
err "Attach the AdministratorAccess managed policy to this principal, or a"
err "policy granting at minimum the ${#REQUIRED_ACTIONS[@]} bootstrap actions the"
err "cloud-provision stage needs (the denied ones are listed above), then re-run"
err "the deploy."
err ""
err "Escape hatch: set SKIP_AWS_BOOTSTRAP_PREFLIGHT=1 to bypass this check."
err "Ref: luthersystems/reliable#2243."
err "================================================================"
exit 1
