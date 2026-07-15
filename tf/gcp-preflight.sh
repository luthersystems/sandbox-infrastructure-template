#!/usr/bin/env bash
# shellcheck shell=bash
#
# gcp-preflight.sh — Fail-fast GCP bootstrap-permission preflight.
#
# Defense-in-depth guard for luthersystems/reliable#2243 (the Beatloom
# incident): a customer's under-privileged GCP service account passed
# credential validation and reached the `cloud-provision` Terraform apply,
# then 403'd mid-apply on storage.buckets.create / iam.serviceAccounts.create
# — AFTER the GitHub half of that apply (tf/cloud-provision/repo.tf) had
# already created a repo, deploy key, and Actions variables, leaving orphaned
# partial state.
#
# Upstream (reliable / ui-core) now feed Oracle a bootstrap permission list so
# its plan-time preflight catches this, but the composed archive is driven
# from MANY caller paths (apply.sh / apply-with-outputs.sh / apply-plan.sh /
# plan-all.sh, all via setupCloudEnv). This script protects ALL of them from
# INSIDE the template: it runs BEFORE terraform creates anything and calls GCP
# projects.testIamPermissions with the exact bootstrap permission set, exiting
# non-zero with an actionable message when permissions are missing.
#
# The permission list below MIRRORS reliable's
# internal/agentapi/bootstrap_permissions.go :: bootstrapGCPIAMPermissions()
# (whose header cites this repo's tf/cloud-provision/gcp-resources.tf.tmpl —
# this citation is the reciprocal). Keep the two lists in sync.
#
# storage.buckets.create and iam.serviceAccounts.create are the two exact
# denials from the #2243 incident.
#
# Owner-grant caveat: the cloud-provision stage grants roles/owner to the
# InsideOut management service account
# (google_project_iam_member.management_owner). GCP only permits a caller to
# grant Owner if the caller itself holds Owner, and testIamPermissions CANNOT
# verify that constraint (it reports the caller's own allowed permissions, not
# whether a given role grant will be permitted). So PASSING this preflight
# does NOT by itself guarantee the Owner grant will succeed — the remediation
# message says so and recommends roles/owner.
#
# Semantics:
#   * FAIL CLOSED (exit 1): a definitive 200 verdict with missing permissions,
#     or a definitive bad-credential rejection at token exchange.
#   * FAIL OPEN  (exit 0 + warning): any infrastructure/transport error
#     (gcloud absent, network blip, HTTP 5xx, non-200, unparseable body) —
#     the preflight must NEVER block a deploy on its own flakiness.
#   * SKIP (exit 0 + notice): SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 operator override.
#
# Deliberately does NOT `set -e`: fail-open depends on catching non-zero exits
# inline, and an unexpected `set -e` abort would surface as a non-zero exit —
# which setupCloudEnv treats as fatal — i.e. the exact opposite of fail-open.
#
# Usage: bash gcp-preflight.sh [<gcp_project_id>]
#   project id resolves from: $1 -> $GOOGLE_PROJECT -> $GCP_PROJECT_ID
#   service-account key path: $GOOGLE_APPLICATION_CREDENTIALS
set -uo pipefail

# ----------------------------------------------------------------------------
# Required bootstrap permissions — mirror of reliable
# bootstrap_permissions.go::bootstrapGCPIAMPermissions(). Grounded in
# tf/cloud-provision/gcp-resources.tf.tmpl:
#   storage.buckets.{create,get,update}      google_storage_bucket.tfstate
#   iam.serviceAccounts.{create,get}         inspector + management SAs
#   iam.serviceAccounts.{get,set}IamPolicy   the two SA token-creator bindings
#   resourcemanager.projects.get             provider project read
#   resourcemanager.projects.{get,set}IamPolicy  the five project IAM bindings
# ----------------------------------------------------------------------------
REQUIRED_PERMISSIONS=(
  iam.serviceAccounts.create
  iam.serviceAccounts.get
  iam.serviceAccounts.getIamPolicy
  iam.serviceAccounts.setIamPolicy
  resourcemanager.projects.get
  resourcemanager.projects.getIamPolicy
  resourcemanager.projects.setIamPolicy
  storage.buckets.create
  storage.buckets.get
  storage.buckets.update
)

log() { echo "[gcp-preflight] $*"; }
err() { echo "[gcp-preflight] $*" >&2; }

# fail_open <reason> — log a warning and exit 0. Never block a deploy on our
# own flakiness (network, tooling, unexpected HTTP status).
fail_open() {
  err "WARNING: $1"
  err "WARNING: preflight is advisory — continuing (deploy NOT blocked)."
  err "WARNING: set SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 to silence this check."
  exit 0
}

# Operator escape hatch.
if [[ "${SKIP_GCP_BOOTSTRAP_PREFLIGHT:-}" == "1" ]]; then
  log "SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 — skipping GCP bootstrap permission preflight."
  exit 0
fi

PROJECT_ID="${1:-${GOOGLE_PROJECT:-${GCP_PROJECT_ID:-}}}"
CREDS_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-}"

if [[ -z "$PROJECT_ID" ]]; then
  fail_open "no GCP project id (arg / GOOGLE_PROJECT / GCP_PROJECT_ID all empty)."
fi

# Service-account email — best-effort, only used to make the message actionable.
sa_email="unknown"
if [[ -n "$CREDS_FILE" && -f "$CREDS_FILE" ]]; then
  sa_email="$(jq -r '.client_email // "unknown"' "$CREDS_FILE" 2>/dev/null || echo unknown)"
fi

log "checking bootstrap permissions for service account ${sa_email} on project ${PROJECT_ID}"

# ----------------------------------------------------------------------------
# Obtain the testIamPermissions response body + HTTP status.
#
# Test seam: GCP_PREFLIGHT_TEST_RESPONSE_FILE short-circuits the live GCP call
# so the comparison logic can be unit-tested with no cloud access. When set,
# GCP_PREFLIGHT_TEST_HTTP_CODE (default 200) selects the simulated status.
# ----------------------------------------------------------------------------
response=""
http_code=""

if [[ -n "${GCP_PREFLIGHT_TEST_RESPONSE_FILE:-}" ]]; then
  http_code="${GCP_PREFLIGHT_TEST_HTTP_CODE:-200}"
  if [[ -f "$GCP_PREFLIGHT_TEST_RESPONSE_FILE" ]]; then
    response="$(cat "$GCP_PREFLIGHT_TEST_RESPONSE_FILE")"
  fi
  log "test seam active (GCP_PREFLIGHT_TEST_RESPONSE_FILE) http_code=${http_code}"
else
  # --- live path: mint a token with gcloud, POST testIamPermissions ---
  if ! command -v gcloud >/dev/null 2>&1; then
    fail_open "gcloud not found on PATH — cannot mint an access token."
  fi
  if [[ -z "$CREDS_FILE" || ! -f "$CREDS_FILE" ]]; then
    fail_open "GOOGLE_APPLICATION_CREDENTIALS unset or file missing — cannot mint a token."
  fi

  # Only service_account keys can be activated. setupGCPCredentials already
  # rejects non-service_account (e.g. WIF external_account) JSONs upstream, but
  # guard defensively and fail open rather than block if one ever reaches here.
  cred_type="$(jq -r '.type // ""' "$CREDS_FILE" 2>/dev/null || echo "")"
  if [[ "$cred_type" != "service_account" ]]; then
    fail_open "credential type '${cred_type}' is not 'service_account' (WIF/external_account?) — skipping token mint."
  fi

  # Isolate gcloud state in a throwaway config dir so we never mutate the
  # container's gcloud configuration (this runs as its own process, so the
  # export cannot leak into terraform).
  tmp_cfg="$(mktemp -d /tmp/gcp-preflight-cfg-XXXXXX 2>/dev/null || echo "")"
  if [[ -z "$tmp_cfg" ]]; then
    fail_open "could not create a temp gcloud config dir."
  fi
  trap 'rm -rf "$tmp_cfg"' EXIT
  export CLOUDSDK_CONFIG="$tmp_cfg"

  # A key gcloud cannot even load is a definitive bad-credential verdict.
  if ! activate_out="$(gcloud auth activate-service-account --key-file="$CREDS_FILE" --quiet 2>&1)"; then
    err ""
    err "GCP BOOTSTRAP PREFLIGHT FAILED — could not load the service account key"
    err "for ${sa_email}: the key is malformed, revoked, or invalid."
    err "${activate_out}"
    err "Ref: luthersystems/reliable#2243."
    exit 1
  fi

  # Token exchange: distinguish an auth rejection (bad key -> fail closed) from
  # a transient network/oauth error (fail open).
  token_stderr="$(mktemp /tmp/gcp-preflight-err-XXXXXX 2>/dev/null || echo "")"
  token="$(gcloud auth print-access-token --quiet 2>"${token_stderr:-/dev/null}")" || token=""
  token_err=""
  if [[ -n "$token_stderr" && -f "$token_stderr" ]]; then
    token_err="$(cat "$token_stderr" 2>/dev/null || echo "")"
    rm -f "$token_stderr"
  fi

  if [[ -z "$token" ]]; then
    if grep -qiE 'invalid_grant|invalid_client|unauthorized_client|invalid_scope|PERMISSION_DENIED|UNAUTHENTICATED|\b401\b|\b403\b' <<<"$token_err"; then
      err ""
      err "GCP BOOTSTRAP PREFLIGHT FAILED — token exchange was REJECTED for"
      err "${sa_email} (bad / revoked service account key):"
      err "${token_err}"
      err "Ref: luthersystems/reliable#2243."
      exit 1
    fi
    fail_open "could not mint an access token (transient/network): ${token_err:-<no detail>}"
  fi

  url="https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions"
  body="$(jq -cn '{permissions: $ARGS.positional}' --args "${REQUIRED_PERMISSIONS[@]}")"

  # No `curl -f`: we WANT the HTTP body+code on a 4xx to reason about it. curl
  # returns non-zero only on transport errors, which we treat as fail-open.
  if ! curl_out="$(curl -sS -m 30 -X POST "$url" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    -w $'\n%{http_code}' 2>/dev/null)"; then
    fail_open "curl to testIamPermissions failed (network/transport error)."
  fi

  http_code="${curl_out##*$'\n'}"
  response="${curl_out%$'\n'*}"
fi

# ----------------------------------------------------------------------------
# Interpret the result. Only a clean 200 with a parseable body is a verdict.
# ----------------------------------------------------------------------------
if [[ "$http_code" != "200" ]]; then
  fail_open "testIamPermissions returned HTTP ${http_code} (not a permission verdict; treating as infra/transient)."
fi

if ! jq -e . >/dev/null 2>&1 <<<"$response"; then
  fail_open "testIamPermissions returned an unparseable 200 body (treating as infra/transient)."
fi

granted="$(jq -r '.permissions[]? // empty' <<<"$response" 2>/dev/null || echo "")"

missing=()
for perm in "${REQUIRED_PERMISSIONS[@]}"; do
  if ! grep -qxF "$perm" <<<"$granted"; then
    missing+=("$perm")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  log "OK — service account ${sa_email} holds all ${#REQUIRED_PERMISSIONS[@]} bootstrap permissions on project ${PROJECT_ID}."
  exit 0
fi

# --- fail closed: definitive missing-permission verdict ---
err ""
err "================================================================"
err "GCP BOOTSTRAP PREFLIGHT FAILED — the provided service account"
err "${sa_email} is missing ${#missing[@]} required permission(s) on project ${PROJECT_ID}:"
for perm in "${missing[@]}"; do
  err "  - ${perm}"
done
err ""
err "Grant the service account roles/owner on the project (required anyway:"
err "this bootstrap stage grants Owner to the InsideOut management service"
err "account, which GCP only permits from a caller that itself holds Owner;"
err "testIamPermissions cannot verify that, so passing this preflight does not"
err "by itself guarantee the Owner grant will succeed)."
err ""
err "At minimum grant: roles/storage.admin + roles/iam.serviceAccountAdmin +"
err "roles/resourcemanager.projectIamAdmin — then re-run the deploy."
err ""
err "Escape hatch: set SKIP_GCP_BOOTSTRAP_PREFLIGHT=1 to bypass this check."
err "Ref: luthersystems/reliable#2243."
err "================================================================"
exit 1
