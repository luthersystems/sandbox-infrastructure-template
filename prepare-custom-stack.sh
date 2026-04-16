#!/usr/bin/env bash
set -euo pipefail

umask 022

# --- Resolve project root and helpers ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR" && pwd)}"

# shell_utils provides: getTfVar, mustGetTfVar, log helpers, etc.
. "$MARS_PROJECT_ROOT/shell_utils.sh"
logTemplateVersion

log() { echo "[prepare-custom-stack] $*" >&2; }

# --- Target directory for customer TF ------------------------------------------------------------
TARGET_DIR="tf/custom-stack-provision"

# --- Inputs --------------------------------------------------------------------------------------
# Prefer explicit env vars; otherwise look up from Terraform auto-vars (tf/auto-vars/*.json).
# Defaults (when repo path is used):
#   - CUSTOM_REF: "main"
#   - CUSTOM_AUTH: "token"
env_or_tf() {
  local v="${!1:-}"
  [[ -n "$v" ]] && {
    echo "$v"
    return 0
  }
  getTfVar "$2"
}

# Repo-mode inputs (fallback)
CUSTOM_REPO_URL="$(env_or_tf CUSTOM_REPO_URL custom_repo_url)"
CUSTOM_REF="$(env_or_tf CUSTOM_REF custom_ref)"
CUSTOM_AUTH="$(env_or_tf CUSTOM_AUTH custom_auth)"

# Archive-mode input (preferred if present)
CUSTOM_ARCHIVE_TGZ="$(env_or_tf CUSTOM_ARCHIVE_TGZ custom_archive_tgz)"

# sane fallbacks for repo mode
CUSTOM_REF="${CUSTOM_REF:-main}"
CUSTOM_AUTH="${CUSTOM_AUTH:-token}"

# --- Preserve key files in TARGET_DIR ------------------------------------------------------------
PRESERVE_PATTERNS=(
  "backend.tf"
  "providers.tf"
  "providers-aws.tf.tmpl"
  "providers-gcp.tf.tmpl"
  "aws-resources.tf.tmpl"
  "gcp-resources.tf.tmpl"
  "__customer_*.tf"
)

tmp_preserve="$(mktemp -d)"
mkdir -p "${TARGET_DIR}"

# copy matches of each pattern if present
shopt -s nullglob
for pat in "${PRESERVE_PATTERNS[@]}"; do
  for f in "${TARGET_DIR}"/$pat; do
    [[ -e "$f" ]] && cp -f "$f" "${tmp_preserve}/"
  done
done
shopt -u nullglob

# ensure rsync excludes include preserved files and TF internals
RSYNC_EXCLUDES=()
for pat in "${PRESERVE_PATTERNS[@]}"; do
  RSYNC_EXCLUDES+=(--exclude "$pat")
done
RSYNC_EXCLUDES+=(--exclude '.git' --exclude '.terraform' --exclude '.terraform.lock.hcl')

# --- Re-deploy: initialize git from infra repo if needed ----------------------------------------
# On re-deploy the working directory is an extracted archive (no .git/).
# Clone the infra repo so that apply.sh's gitCommit/gitPushInfra will work.
ensure_git_from_infra() {
  if [[ -e "$MARS_PROJECT_ROOT/.git" ]]; then
    log "Git repo already exists; skipping infra clone"
    return 0
  fi

  local infra_url
  infra_url="$(getTfVar repo_clone_ssh_url)"
  if [[ -z "$infra_url" || "$infra_url" == "null" ]]; then
    log "No repo_clone_ssh_url set; skipping infra clone"
    return 0
  fi

  local deploy_key="$MARS_PROJECT_ROOT/secrets/infra_deploy_key.pem"
  local git_ssh_cmd="ssh -o StrictHostKeyChecking=no"
  if [[ -f "$deploy_key" ]]; then
    chmod 600 "$deploy_key"
    git_ssh_cmd="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
  fi

  log "Cloning infra repo to initialize git state: $infra_url"
  local tmp_clone
  tmp_clone="$(mktemp -d)"
  if ! GIT_SSH_COMMAND="$git_ssh_cmd" git clone "$infra_url" "$tmp_clone/repo"; then
    log "WARNING: failed to clone infra repo; git commit/push will be skipped"
    rm -rf "$tmp_clone"
    return 0
  fi

  # Move .git into working directory so apply.sh's git helpers work
  mv "$tmp_clone/repo/.git" "$MARS_PROJECT_ROOT/.git"
  rm -rf "$tmp_clone"

  # Rename origin → infra (ensure_infra_remote expects "infra" remote)
  pushd "$MARS_PROJECT_ROOT" >/dev/null
  if git remote get-url origin >/dev/null 2>&1; then
    git remote rename origin infra
  fi
  popd >/dev/null

  log "Git state initialized from infra repo"
}

ensure_git_from_infra

# --- Archive-mode (preferred) --------------------------------------------------------------------
if [[ -n "${CUSTOM_ARCHIVE_TGZ:-}" && "${CUSTOM_ARCHIVE_TGZ}" != "null" ]]; then
  log "Inline archive provided; extracting into ${TARGET_DIR}"

  tmp_ar="$(mktemp -d)"
  ar_file="${tmp_ar}/payload.tgz"
  # base64 decode archive
  printf '%s' "$CUSTOM_ARCHIVE_TGZ" | base64 -d >"$ar_file"

  # Safety: reject absolute paths or parent escapes ("tartbomb" protection)
  while IFS= read -r entry; do
    case "$entry" in
    /*)
      log "ERROR: archive contains absolute path: $entry"
      exit 2
      ;;
    *"../"*)
      log "ERROR: archive contains parent path escape: $entry"
      exit 2
      ;;
    "") ;;
    *) ;;
    esac
  done < <(tar -tzf "$ar_file" --warning=no-unknown-keyword)

  # Clean target and restore preserved files after extraction
  rm -rf "${TARGET_DIR:?}/"* "${TARGET_DIR:?}"/.[!.]* || true
  mkdir -p "${TARGET_DIR}"

  mkdir -p "$tmp_ar/extract"
  # Avoid restoring owners from the archive even if present
  tar --no-same-owner -xzf "$ar_file" -C "$tmp_ar/extract" --warning=no-unknown-keyword

  src_path="$tmp_ar/extract" # ALWAYS use archive root

  # restore preserved + rsync
  shopt -s dotglob nullglob
  for f in "${tmp_preserve}"/*; do
    [[ -e "$f" ]] && mv -f "$f" "${TARGET_DIR}/"
  done
  shopt -u dotglob nullglob

  rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$src_path"/ "$TARGET_DIR"/

  log "Prepared ${TARGET_DIR} from inline archive (tar.gz)"
  exit 0
fi

# --- Repo-mode (fallback) ------------------------------------------------------------------------
if [[ -z "$CUSTOM_REPO_URL" || "$CUSTOM_REPO_URL" == "null" ]]; then
  log "ERROR: missing CUSTOM_REPO_URL. Provide inline archive or set 'custom_repo_url'."
  exit 2
fi

git config --global advice.detachedHead false || true

# Detect 40-char hex commit SHAs (git clone --branch doesn't support them)
is_commit_sha() { [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]; }

git_clone_with_token() {
  local url="$1" ref="$2" dest="$3"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log "ERROR: CUSTOM_AUTH=token but GITHUB_TOKEN is not set"
    exit 2
  fi
  local token_url="$url"
  if [[ "$token_url" =~ ^https:// ]]; then
    token_url="${url/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
  fi
  if is_commit_sha "$ref"; then
    git clone --no-tags "$token_url" "$dest"
    git -C "$dest" checkout "$ref"
  else
    git clone --depth 1 --no-tags --branch "$ref" "$token_url" "$dest"
  fi
}

git_clone_with_ssh() {
  local url="$1" ref="$2" dest="$3"
  if is_commit_sha "$ref"; then
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' git clone --no-tags "$url" "$dest"
    git -C "$dest" checkout "$ref"
  else
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no' git clone --depth 1 --no-tags --branch "$ref" "$url" "$dest"
  fi
}

tmp_dir="$(mktemp -d)"
case "$CUSTOM_AUTH" in
token) git_clone_with_token "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
ssh) git_clone_with_ssh "$CUSTOM_REPO_URL" "$CUSTOM_REF" "$tmp_dir" ;;
*)
  log "ERROR: unknown CUSTOM_AUTH='$CUSTOM_AUTH' (expected 'token' or 'ssh')"
  exit 2
  ;;
esac

# Clean target and restore preserved files, then rsync repo root
rm -rf "${TARGET_DIR:?}/"* "${TARGET_DIR:?}"/.[!.]* || true
mkdir -p "${TARGET_DIR}"
shopt -s dotglob nullglob
for f in "${tmp_preserve}"/*; do
  [[ -e "$f" ]] && mv -f "$f" "${TARGET_DIR}/"
done
shopt -u dotglob nullglob

src_path="$tmp_dir" # repo root only
rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$src_path"/ "$TARGET_DIR"/

log "Prepared ${TARGET_DIR} from ${CUSTOM_REPO_URL}@${CUSTOM_REF}"
