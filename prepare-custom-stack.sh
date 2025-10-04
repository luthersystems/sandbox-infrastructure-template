#!/usr/bin/env bash
set -euo pipefail

# --- Resolve project root and helpers ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

# shell_utils provides: getTfVar, mustGetTfVar, log helpers, etc.
. "$MARS_PROJECT_ROOT/shell_utils.sh"

log() { echo "[prepare-custom-stack] $*" >&2; }

# --- Target directory for customer TF ------------------------------------------------------------
TARGET_DIR="tf/custom-stack-provision"

# --- Inputs --------------------------------------------------------------------------------------
# Prefer explicit env vars; otherwise look up from Terraform auto-vars (tf/auto-vars/*.json).
# Defaults:
#   - CUSTOM_REF: "main" (if still empty)
#   - CUSTOM_AUTH: "token" (if still empty)
#   - CUSTOM_REPO_URL: REQUIRED (error if empty after env+auto-vars)
env_or_tf() {
  local v="${!1:-}"
  [[ -n "$v" ]] && {
    echo "$v"
    return 0
  }
  getTfVar "$2"
}

CUSTOM_REPO_URL="$(env_or_tf CUSTOM_REPO_URL custom_repo_url)"
CUSTOM_REF="$(env_or_tf CUSTOM_REF custom_ref)"
CUSTOM_PATH="$(env_or_tf CUSTOM_PATH custom_path)"
CUSTOM_TFVARS_JSON="$(env_or_tf CUSTOM_TFVARS_JSON custom_tfvars_json)"
CUSTOM_AUTH="$(env_or_tf CUSTOM_AUTH custom_auth)"

# sane fallbacks
CUSTOM_REF="${CUSTOM_REF:-main}"
CUSTOM_AUTH="${CUSTOM_AUTH:-token}"

if [[ -z "$CUSTOM_REPO_URL" || "$CUSTOM_REPO_URL" == "null" ]]; then
  log "ERROR: missing CUSTOM_REPO_URL. Set env CUSTOM_REPO_URL or provide 'custom_repo_url' in tf/auto-vars/*.json"
  exit 2
fi

# --- Preserve key files in TARGET_DIR ------------------------------------------------------------
# These files are produced locally and must not be overwritten by the customer repo.
PRESERVE_PATTERNS=(
  "backend.tf"
  "providers.tf"
  "__customer_*.tf"
  ".terraform-version"
)

tmp_preserve="$(mktemp -d)"
mkdir -p "${TARGET_DIR}"

# copy matches of each pattern if present
for pat in "${PRESERVE_PATTERNS[@]}"; do
  for f in "${TARGET_DIR}"/$pat; do
    [[ -e "$f" ]] && cp -f "$f" "${tmp_preserve}/"
  done
done

# Clean but leave dir
rm -rf "${TARGET_DIR:?}/"* || true
mkdir -p "${TARGET_DIR}"

# restore preserved
for f in "${tmp_preserve}"/*; do
  [[ -e "$f" ]] && mv -f "$f" "${TARGET_DIR}/"
done

# --- Git helpers ---------------------------------------------------------------------------------
git config --global advice.detachedHead false || true

git_clone_with_token() {
  local url="$1" ref="$2" dest="$3"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "ERROR: CUSTOM_AUTH=token but GITHUB_TOKEN is not set"
    exit 2
  fi
  local token_url="$url"
  # inject token into https url if applicable
  if [[ "$token_url" =~ ^https:// ]]; then
    token_url="${url/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
  fi
  git clone --depth 1 --no-tags --branch "$ref" "$token_url" "$dest"
}

git_clone_with_ssh() {
  local url="$1" ref="$2" dest="$3"
  # assumes /root/.ssh is mounted and StrictHostKeyChecking disabled
  GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' git clone --depth 1 --no-tags --branch "$ref" "$url" "$dest"
}

# --- Clone the customer repo ---------------------------------------------------------------------
tmp_dir="$(mktemp -d)"
case "$CUSTOM_AUTH" in
token) git_clone_with_token "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
ssh) git_clone_with_ssh "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
*)
  log "ERROR: unknown CUSTOM_AUTH='$CUSTOM_AUTH' (expected 'token' or 'ssh')"
  exit 2
  ;;
esac

# Optional subdir inside the repo
src_path="$tmp_dir"
if [[ -n "$CUSTOM_PATH" && "$CUSTOM_PATH" != "null" ]]; then
  src_path="$tmp_dir/$CUSTOM_PATH"
  [[ -d "$src_path" ]] || {
    log "ERROR: CUSTOM_PATH '$CUSTOM_PATH' not found in repo"
    exit 2
  }
fi

# --- Copy into TARGET_DIR, respecting preserved files --------------------------------------------
# Build rsync excludes from PRESERVE_PATTERNS and repo internals
RSYNC_EXCLUDES=()
for pat in "${PRESERVE_PATTERNS[@]}"; do
  RSYNC_EXCLUDES+=(--exclude "$pat")
done
RSYNC_EXCLUDES+=(--exclude '.git' --exclude '.terraform' --exclude '.terraform.lock.hcl')

rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$src_path"/ "$TARGET_DIR"/

# --- Optional: write additional auto-vars for this step ------------------------------------------
if [[ -n "$CUSTOM_TFVARS_JSON" && "$CUSTOM_TFVARS_JSON" != "null" ]]; then
  mkdir -p tf/auto-vars
  echo "$CUSTOM_TFVARS_JSON" >tf/auto-vars/custom-stack.auto.tfvars.json
  log "Wrote tf/auto-vars/custom-stack.auto.tfvars.json"
fi

log "Prepared ${TARGET_DIR} from ${CUSTOM_REPO_URL}@${CUSTOM_REF}${CUSTOM_PATH:+ path=$CUSTOM_PATH}"
