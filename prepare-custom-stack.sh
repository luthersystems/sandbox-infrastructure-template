#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="tf/custom-stack-provision"

# Inputs (override via env in the workflow step)
CUSTOM_REPO_URL="${CUSTOM_REPO_URL:-https://github.com/luthersystems/reliable-custom-tf-test}"
CUSTOM_REF="${CUSTOM_REF:-main}"
CUSTOM_PATH="${CUSTOM_PATH:-}"               # optional subdir inside repo
CUSTOM_TFVARS_JSON="${CUSTOM_TFVARS_JSON:-}" # optional raw JSON for auto-vars
CUSTOM_AUTH="${CUSTOM_AUTH:-token}"          # token|ssh

log() { echo "[prepare-custom-stack] $*" >&2; }

# Files/patterns we MUST NOT clobber (created/owned locally)
PRESERVE_PATTERNS=(
  "backend.tf"
  "providers.tf"
  "__customer_*.tf"
  ".terraform-version"
)

# Stash preserved files, clean target, then restore them
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

# --- Git auth & clone helpers ---
git config --global advice.detachedHead false || true

git_clone_with_token() {
  local url="$1" ref="$2" dest="$3"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "ERROR: CUSTOM_AUTH=token but GITHUB_TOKEN is not set"
    exit 2
  fi
  local token_url="$url"
  [[ "$token_url" =~ ^https:// ]] && token_url="${url/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
  git clone --depth 1 --no-tags --branch "$ref" "$token_url" "$dest"
}

git_clone_with_ssh() {
  local url="$1" ref="$2" dest="$3"
  GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' git clone --depth 1 --no-tags --branch "$ref" "$url" "$dest"
}

# Clone customer repo
tmp_dir="$(mktemp -d)"
case "$CUSTOM_AUTH" in
token) git_clone_with_token "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
ssh) git_clone_with_ssh "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
*)
  log "ERROR: unknown CUSTOM_AUTH=$CUSTOM_AUTH"
  exit 2
  ;;
esac

# Optional subdir
src_path="$tmp_dir"
if [[ -n "$CUSTOM_PATH" ]]; then
  src_path="$tmp_dir/$CUSTOM_PATH"
  [[ -d "$src_path" ]] || {
    log "ERROR: CUSTOM_PATH '$CUSTOM_PATH' not found in repo"
    exit 2
  }
fi

# Build rsync excludes from PRESERVE_PATTERNS
RSYNC_EXCLUDES=()
for pat in "${PRESERVE_PATTERNS[@]}"; do
  RSYNC_EXCLUDES+=(--exclude "$pat")
done
# Always ignore repo internals
RSYNC_EXCLUDES+=(--exclude '.git' --exclude '.terraform' --exclude '.terraform.lock.hcl')

# Copy customer code into target, but do NOT touch preserved files
rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$src_path"/ "$TARGET_DIR"/

# Optional: write additional autovars for this step
if [[ -n "$CUSTOM_TFVARS_JSON" ]]; then
  mkdir -p tf/auto-vars
  echo "$CUSTOM_TFVARS_JSON" >tf/auto-vars/custom-stack.auto.tfvars.json
  log "Wrote tf/auto-vars/custom-stack.auto.tfvars.json"
fi

log "Prepared ${TARGET_DIR} from ${CUSTOM_REPO_URL}@${CUSTOM_REF}${CUSTOM_PATH:+ path=$CUSTOM_PATH}"
