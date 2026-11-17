#!/usr/bin/env bash
set -euo pipefail

# Determine project root: use $MARS_PROJECT_ROOT if set, otherwise resolve relative to this script or fallback to $PWD
if [ -z "${MARS_PROJECT_ROOT:-}" ]; then
  # Try to find project root as the parent of the directory containing this script
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  MARS_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
export MARS_PROJECT_ROOT

ANSIBLE_ENV_FILE="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/env.yaml"

echo_error() {
  echo "$1" >&2
}

resolveMarsBinary() {
  local mars_root="${MARS_CONTAINER_ROOT:-/opt/mars}"
  if [[ -x "$mars_root/mars" ]]; then
    echo "$mars_root/mars"
    return 0
  fi
  echo "$mars_root/run.sh"
}

# getAnsibleField <key>
getAnsibleField() {
  key="$1"
  if [ ! -f "$ANSIBLE_ENV_FILE" ]; then
    echo_error "ERROR: cannot find $ANSIBLE_ENV_FILE"
    exit 1
  fi
  grep -E "^[[:space:]]*$key:" "$ANSIBLE_ENV_FILE" | head -n1 | sed 's/^[[:space:]]*'"$key"':[[:space:]]*//'
}

# mustGetAnsibleField <key>
mustGetAnsibleField() {
  key="$1"
  val="$(getAnsibleField "$key")"
  if [ -z "$val" ]; then
    echo_error "ERROR: required ansible field '$key' is missing or empty in $ANSIBLE_ENV_FILE"
    exit 1
  fi
  echo "$val"
}

AUTO_VARS_DIR="${MARS_PROJECT_ROOT}/tf/auto-vars"

# getTfVar VAR_NAME
#   Print the value of VAR_NAME from any JSON file in auto-vars/ (or, as a
#   fallback, the gitignored secrets/*.auto.tfvars.json credential drop) or
#   empty string if not found.
getTfVar() {
  local key="$1"

  if [[ ! -d "$AUTO_VARS_DIR" ]]; then
    echo "ERROR: Terraform auto vars directory '$AUTO_VARS_DIR' not found" >&2
    echo ""
    exit 1
  fi

  # jq filter to get the variable from any JSON file, first match wins.
  #
  # Scan order matters (#160): tf/auto-vars/*.json FIRST, so behavior is
  # unchanged while ui-core still writes credentials into
  # tf/auto-vars/common.auto.tfvars.json; THEN fall back to the gitignored
  # secrets/*.auto.tfvars.json credential drop. secrets/ is excluded from the
  # persistInfraRepo `git add -A` push, so credentials placed there never leak
  # into the per-project -infra repo (unlike common.auto.tfvars.json). Absent or
  # empty secrets/ is a silent no-op: the `[[ -e ]]` guard (existing style, no
  # nullglob) skips the unexpanded glob, so nothing errors under callers' `set
  # -euo pipefail` when secrets/ has no *.auto.tfvars.json (today's state).
  local result=""
  local file val
  for file in "$AUTO_VARS_DIR"/*.json "$MARS_PROJECT_ROOT"/secrets/*.auto.tfvars.json; do
    # skip if no matching files
    [[ -e "$file" ]] || continue

    val=$(jq -r --arg k "$key" 'if has($k) then .[$k] else empty end' "$file" 2>/dev/null || echo "")
    if [[ -n "$val" && "$val" != "null" ]]; then
      result="$val"
      break
    fi
  done

  echo "${result:-}"
}

# mustGetTfVar VAR_NAME
#   Print the value of VAR_NAME from auto-vars or exit if not set/empty
mustGetTfVar() {
  local val
  val="$(getTfVar "$1")"
  if [[ -z "$val" || "$val" == "null" ]]; then
    echo "ERROR: required terraform variable '$1' missing or empty in $AUTO_VARS_DIR" >&2
    exit 1
  fi
  echo "$val"
}

has_git_repo() {
  [ -e "$MARS_PROJECT_ROOT/.git" ]
}

ensure_git_identity() {
  git config --local user.email >/dev/null 2>&1 ||
    git config --local user.email "devbot@luthersystems.com"
  git config --local user.name >/dev/null 2>&1 ||
    git config --local user.name "Luther DevBot"
}

disable_filemode() {
  git config --local core.fileMode false
}

configure_deploy_ssh() {
  local KEY="$MARS_PROJECT_ROOT/secrets/infra_deploy_key.pem"
  if [ ! -f "$KEY" ]; then
    echo "Skipping SSH config: no deploy key at $KEY"
    return 0
  fi

  git config --local core.sshCommand "ssh -i $KEY -o IdentitiesOnly=yes"
}

# ---------------------------------------------------------------------------
# Git access to the -infra repo with ui-core's GitHub App
# (luthersystems/ui-infrastructure#442).
#
# With the App on, ui-core gives a step a one-hour installation token for the
# project's -infra repo only, in a file: GITHUB_GIT_TOKEN_FILE (git access
# only, for the custom-stack apply) or GITHUB_TOKEN_FILE (the stages with the
# github provider). The repo then lives in an org of its own, where deploy
# keys are off (a new org cannot turn them on without Enterprise Cloud), so
# Terraform makes no deploy key (create_infra_deploy_key = false) and git
# clones, fetches and pushes over HTTPS with that token. Without a token
# file, git uses the deploy key over SSH as before.
#
# The token never goes into .git/config, which travels in the project
# archive: the credential helper there reads the file when git asks.
# ---------------------------------------------------------------------------

# infra_git_token_file prints the token file of this step, if it has one.
infra_git_token_file() {
  local f
  for f in "${GITHUB_GIT_TOKEN_FILE:-}" "${GITHUB_TOKEN_FILE:-}"; do
    if [[ -n "$f" && -r "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# infra_https_url URL prints the HTTPS form of a git@github.com: URL, and any
# other URL as it is.
infra_https_url() {
  local url="$1"
  if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
    echo "https://github.com/${BASH_REMATCH[1]}"
  else
    echo "$url"
  fi
}

# infra_git_credential_helper FILE prints a git credential helper that gives
# the token in FILE for each request.
infra_git_credential_helper() {
  local q
  q=$(printf '%q' "$1")
  echo "!f() { test \"\$1\" = get || return 0; echo username=x-access-token; echo \"password=\$(tr -d '\\n' < ${q})\"; }; f"
}

# infra_git_auth_args prints, one per line, the "-c" options that give one
# git command the token of this step (nothing without a token file). The
# empty helper first drops any helper from another config file.
infra_git_auth_args() {
  local tok
  tok=$(infra_git_token_file) || return 0
  printf '%s\n' -c "credential.https://github.com.helper=" \
    -c "credential.https://github.com.helper=$(infra_git_credential_helper "$tok")"
}

# configure_infra_git_auth sets the repo's git access: the token over HTTPS
# when the step has one, else the deploy key over SSH.
configure_infra_git_auth() {
  local tok
  if tok=$(infra_git_token_file); then
    git config --local --unset-all credential.https://github.com.helper 2>/dev/null || true
    git config --local --add credential.https://github.com.helper ''
    git config --local --add credential.https://github.com.helper "$(infra_git_credential_helper "$tok")"
    # A deploy key from an earlier run must not take over.
    git config --local --unset core.sshCommand 2>/dev/null || true
    echo "🔑 [git-infra] using the GitHub App token over HTTPS"
    return 0
  fi
  configure_deploy_ssh
}

# infra_remote_url prints the URL of the -infra repo for this step: HTTPS
# when the step has a token, else the recorded SSH URL.
infra_remote_url() {
  local url
  url=$(getTfVar "repo_clone_ssh_url")
  if [[ -z "$url" || "$url" == "null" ]]; then
    return 0
  fi
  if infra_git_token_file >/dev/null; then
    infra_https_url "$url"
  else
    echo "$url"
  fi
}

# cloneInfraRepo gives a working tree without .git (an extracted project
# archive) the git state of the -infra repo, so that gitCommit and
# gitPushInfra work. Non-fatal: on any problem it warns and returns 0.
cloneInfraRepo() {
  if has_git_repo; then
    return 0
  fi

  local infra_url
  infra_url=$(infra_remote_url)
  if [[ -z "$infra_url" ]]; then
    echo "[git-infra] No repo_clone_ssh_url set; skipping infra clone" >&2
    return 0
  fi

  local deploy_key="$MARS_PROJECT_ROOT/secrets/infra_deploy_key.pem"
  local git_ssh_cmd="ssh -o StrictHostKeyChecking=no"
  local auth_args=()
  mapfile -t auth_args < <(infra_git_auth_args)
  if ((${#auth_args[@]} == 0)); then
    if [[ -f "$deploy_key" ]]; then
      chmod 600 "$deploy_key"
      git_ssh_cmd="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
    elif [[ "$infra_url" == git@* ]]; then
      # SSH with no deploy key and no token: the clone can only fail. A
      # later step that has the token clones the repo (persistInfraRepo).
      echo "[git-infra] No GitHub token or deploy key in this step; skipping infra clone" >&2
      return 0
    fi
  fi

  echo "[git-infra] Cloning infra repo to initialize git state: $infra_url" >&2
  local tmp_clone
  tmp_clone="$(mktemp -d)"
  if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$git_ssh_cmd" git "${auth_args[@]}" clone "$infra_url" "$tmp_clone/repo"; then
    echo "⚠️  [git-infra] WARNING: failed to clone infra repo; git commit/push will be skipped" >&2
    rm -rf "$tmp_clone"
    return 0
  fi

  # Move .git into the working directory so the git helpers work.
  mv "$tmp_clone/repo/.git" "$MARS_PROJECT_ROOT/.git"
  rm -rf "$tmp_clone"

  # Rename origin → infra (ensure_infra_remote expects "infra" remote)
  pushd "$MARS_PROJECT_ROOT" >/dev/null
  if git remote get-url origin >/dev/null 2>&1; then
    git remote rename origin infra
  fi
  # The deploy archive now lies over an old infra/main commit and is the
  # source of truth. Mark the checkout so gitMergeInfraMain never merges
  # infra/main content into it; the snapshot commit replaces infra/main.
  git config luther.infraSnapshotTree true
  popd >/dev/null

  echo "[git-infra] Git state initialized from infra repo" >&2
}

ensure_infra_remote() {
  # repo_clone_ssh_url should be set via terraform auto-vars
  url=$(infra_remote_url)
  if [ -n "$url" ]; then
    if git remote get-url infra >/dev/null 2>&1; then
      git remote set-url infra "$url"
    else
      git remote add infra "$url"
    fi
    echo "🔧 [git-infra] infra remote configured → $url"
  else
    # LOUD, greppable signal for hypothesis (1) in
    # sandbox-infrastructure-template#143: cloud-provision writes
    # tf/auto-vars/git_repo.auto.tfvars.json with repo_clone_ssh_url, but if
    # that auto-var did not reach this working tree the infra remote is never
    # wired and the per-project -infra repo stays empty. Non-fatal: may be
    # benign on early stages (before cloud-provision) but is a real problem on
    # custom-stack-provision.
    echo "⚠️  [git-infra] WARNING: repo_clone_ssh_url is empty in ${AUTO_VARS_DIR} — 'infra' remote NOT configured; the per-project -infra repo will NOT be populated. [sandbox-infrastructure-template#143]" >&2
  fi
}

configure_git() {
  if ! has_git_repo; then
    # LOUD, greppable signal for hypothesis (2) in #143: no .git at the project
    # root means cloneInfraRepo never ran (or its
    # clone failed), so nothing can be committed or pushed to the -infra repo.
    echo "⚠️  [git-infra] WARNING: configure_git: no .git at ${MARS_PROJECT_ROOT} — commit/push to the -infra repo will be SKIPPED. [sandbox-infrastructure-template#143]" >&2
    return 1
  fi
  pushd "$MARS_PROJECT_ROOT" >/dev/null
  ensure_git_identity
  disable_filemode
  configure_infra_git_auth
  ensure_infra_remote
  popd >/dev/null
}

# untrackIgnoredFiles stages the removal from git of every tracked file that
# the repo's .gitignore files ignore. The files stay on disk. gitCommit calls it
# just before `git add -A`, so the removal goes into that same commit.
#
# Why it exists (sandbox-infrastructure-template#160): .gitignore only stops
# git from ADDING an untracked file. A file that is already tracked stays
# tracked, and `git add -A` commits each new version of it. The template once
# tracked tf/auto-vars/common.auto.tfvars.json as a `{}` seed, so every project
# tree cloned from it (and every -infra repo built from that tree) still tracks
# the file. At deploy time ui-core writes the cloud credentials into it, and
# gitCommit committed them and gitPushInfra pushed them to the -infra repo.
#
# Why all ignored files and not one name: .gitignore is the one list of what
# must not reach an -infra repo. Untracking every tracked file it matches makes
# that list true for files committed before a rule was added (for example
# outputs/ from before #160), with no second list to keep in step.
#
# Why only the repo's .gitignore files: --exclude-per-directory reads them and
# not core.excludesFile or .git/info/exclude, so a developer's global ignore
# (such as .idea/) never untracks a repo file from commit.sh.
#
# Why only in gitCommit and not before the merges: a commit of the removal
# before `git merge infra/main` turns an infra/main edit of the same file into a
# modify/delete conflict, and git then writes infra's old copy over the current
# credentials on disk. Left alone, the merges behave as before.
#
# Non-fatal: it warns and returns 0, so a git problem never fails a deploy that
# already applied. The old versions stay in the -infra repo history; this
# function does not rewrite history.
untrackIgnoredFiles() {
  local files
  files="$(git ls-files --cached --ignored --exclude-per-directory=.gitignore)"
  if [[ -z "$files" ]]; then
    return 0
  fi

  echo "🔒 [git-infra] Untracking file(s) that .gitignore ignores (#160):" >&2
  sed 's/^/    /' <<<"$files" >&2
  # -z with xargs keeps odd names intact and splits a long list. Literal
  # pathspecs, so a name with * or [ ] untracks only itself.
  if ! git ls-files -z --cached --ignored --exclude-per-directory=.gitignore |
    xargs -0 -r git --literal-pathspecs rm --cached --quiet --ignore-unmatch --; then
    echo "⚠️  [git-infra] WARNING: git rm --cached failed; ignored files may still be committed. [sandbox-infrastructure-template#160]" >&2
  fi
  return 0
}

# Paths that belong to the template repo only and never go into a project
# tree's commits, so they never reach an -infra repo. .github/dependabot.yml
# configures Dependabot for the template; in an -infra repo it would open
# weekly PRs that the next deploy reverts. (The workflows ride along but
# guard themselves with `if: github.repository == ...`.) The files stay on
# disk.
# Known edge: a template clone used as a project tree may see a modify/delete
# conflict on these paths when it merges infra/main after a snapshot; resolve
# it with `git rm`.
SNAPSHOT_TEMPLATE_ONLY_PATHS=(
  .github/dependabot.yml
)

# mergeInProgress succeeds when a merge is unfinished: MERGE_HEAD exists or
# the index has unmerged entries. Run it in the project root.
mergeInProgress() {
  git rev-parse -q --verify MERGE_HEAD >/dev/null || [[ -n "$(git ls-files -u)" ]]
}

# markScriptsExecutable <base> [path...] sets the exec bit in the index on:
#   - each path that is new against <base> (every staged path when <base> is
#     empty), executable on disk, and starts with "#!"; core.fileMode is off
#     (configure_git), so `git add` would record a new 0755 script as 100644;
#   - each given path that is staged as 100644: the snapshot passes the paths
#     the project tree had at 100755 before it reset onto infra/main, so its
#     own modes win over infra/main's.
# Other existing paths keep their index mode, and the bit is never removed:
# an archive or a mount can extract every file as 0777 (or drop the bit),
# and that must not churn modes. The cost: a 644->755 change of an existing
# script on disk alone is not carried (set it with `git update-index
# --chmod=+x`). The "#!" test keeps a new data file (.tf, .json) at 100644
# on such a filesystem. One batched update-index call, not a process per
# file. Run it in the project root.
markScriptsExecutable() {
  local base="$1" path head line
  shift
  local -a paths=()
  local -A staged_644=()
  while IFS= read -r -d '' line; do
    [[ "${line%% *}" == 100644 ]] && staged_644["${line#*$'\t'}"]=1
  done < <(git ls-files -s -z)
  for path in "$@"; do
    [[ -n "${staged_644[$path]:-}" ]] && paths+=("$path")
  done
  while IFS= read -r -d '' path; do
    [[ -n "${staged_644[$path]:-}" ]] || continue
    [[ -f "$path" && ! -L "$path" && -x "$path" ]] || continue
    head=""
    IFS= read -r -n 2 head <"$path" || true
    [[ "$head" == '#!' ]] && paths+=("$path")
  done < <(
    if [[ -n "$base" ]]; then
      git diff --cached --name-only -z --no-renames --diff-filter=A "$base"
    else
      git ls-files -z
    fi
  )
  if ((${#paths[@]})); then
    printf '%s\0' "${paths[@]}" | xargs -0 git update-index --chmod=+x --
  fi
}

# gitStageTree <base> <drop_template_only> [exec path...] stages the worktree
# for a commit, with the rules every commit of a project tree follows.
# gitCommit (commit.sh, destroy.sh) and gitSnapshotCommit (persistInfraRepo,
# apply.sh) both use it, so the rules live in one place. <base> is the commit
# the index starts from (infra/main for a snapshot); empty means HEAD, or
# none on an unborn branch. Returns 1, staging nothing:
#   0. when a merge is in progress, so conflict markers are never committed.
# Otherwise:
#   1. untrackIgnoredFiles, before `git add -A`: add -A commits new versions
#      of TRACKED files even when .gitignore matches them (#160).
#   2. `git add -A` with core.fileMode as configure_git set it (off), then
#      markScriptsExecutable with <base> and the exec paths.
#   3. With <drop_template_only>=1 (only gitSnapshotCommit), drop
#      SNAPSHOT_TEMPLATE_ONLY_PATHS from the index.
# Run it in the project root.
gitStageTree() {
  local base="$1" drop_template_only="$2"
  shift 2
  if mergeInProgress; then
    echo_error "⚠️  A merge is in progress; finish or abort it first. Nothing staged."
    return 1
  fi
  if [[ -z "$base" ]]; then
    base="$(git rev-parse -q --verify HEAD || true)"
  fi
  untrackIgnoredFiles
  git add -A
  markScriptsExecutable "$base" "$@"
  if [[ "$drop_template_only" == 1 ]]; then
    git rm --cached -q --ignore-unmatch -- "${SNAPSHOT_TEMPLATE_ONLY_PATHS[@]}"
  fi
}

gitCommit() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping commit."
    popd >/dev/null
    return 0
  fi

  msg="${1:-auto-commit: infrastructure changes [ci skip]}"
  # gitCommit keeps the template-only paths; only the snapshot drops them.
  if ! gitStageTree "" 0; then
    popd >/dev/null
    return 1
  fi

  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -m "$msg"
    echo "✅ Git commit created."
  fi

  popd >/dev/null
}

gitMergeOriginMain() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping git merge."
    popd >/dev/null
    return 0
  fi

  echo "🔄 Fetching origin/main…"
  # The full ref: `git fetch origin main` takes a tag named main over the
  # branch.
  git fetch origin +refs/heads/main:refs/remotes/origin/main

  echo "🔀 Merging (no‐ff, auto‐edit) origin/main…"
  if git merge origin/main --no-ff --no-edit; then
    echo "✅ Merge commit created."
  else
    echo_error "⚠️  Merge failed or conflicts detected."
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
}

gitPushInfra() {
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! git remote get-url infra >/dev/null 2>&1; then
    # Previously this returned 0 silently ("Skipping gitPushInfra: no infra
    # remote configured"), which is exactly how #143 went unnoticed: a
    # successful apply left the -infra repo empty and reported SUCCESS. Warn
    # LOUDLY (greppable) instead. Still non-fatal — a push problem must never
    # turn an already-successful deploy into a failure.
    echo "⚠️  [git-infra] WARNING: no 'infra' remote configured — NOT pushing; the per-project -infra repo will stay EMPTY. [sandbox-infrastructure-template#143]" >&2
    popd >/dev/null
    return 0
  fi

  # A freshly-cloned empty infra repo has no HEAD until gitCommit runs. If there
  # is still nothing to push, say so loudly rather than pushing nothing.
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    echo "⚠️  [git-infra] WARNING: no HEAD/commit to push (nothing was committed) — the per-project -infra repo will stay EMPTY. [sandbox-infrastructure-template#143]" >&2
    popd >/dev/null
    return 0
  fi

  echo "🚀 [git-infra] Pushing HEAD to infra remote…"
  if git push infra HEAD; then
    echo "✅ [git-infra] Pushed to infra remote — per-project -infra repo populated."
  else
    echo "⚠️  [git-infra] WARNING: 'git push infra HEAD' FAILED — the per-project -infra repo may stay EMPTY. Deploy is NOT failed (apply already succeeded); investigate the GitHub token or deploy key and the remote URL. [sandbox-infrastructure-template#143]" >&2
  fi

  popd >/dev/null
}

# persistInfraRepo commits the applied working tree and pushes it to the
# per-project -infra GitHub repo. It is the durable-persistence entry point for
# the apply code paths that ACTUALLY run in production — apply-with-outputs.sh
# (--check-drift) and apply-plan.sh — which, unlike apply.sh, never otherwise
# reach gitPushInfra. That gap is the root cause of #143: ui-core always sets
# checkDrift=true on custom-stack applies, so the git merge/commit/push in
# apply.sh was dead code and 89/89 -infra repos were left empty.
#
# Contract: NON-FATAL and LOUD. A deploy that already applied must never be
# turned into a failure by a git/push problem, and every skip/failure is logged
# with a greppable "[git-infra] WARNING:" prefix so a silent no-op can never
# regress unnoticed again. Always returns 0.
persistInfraRepo() {
  echo "📦 [git-infra] Persisting applied stack to the per-project -infra repo…"

  # Up-front LOUD signals for the two silent-failure hypotheses in #143. These
  # are pure diagnostics; the helper calls below also degrade gracefully.
  # prepare-custom-stack clones the -infra repo when it can. With the GitHub
  # App it cannot (that step gets no token), so clone it here, in the step
  # that has one.
  cloneInfraRepo || true
  if ! has_git_repo; then
    echo "⚠️  [git-infra] WARNING: no .git at ${MARS_PROJECT_ROOT} at persist time — cloneInfraRepo (prepare-custom-stack, or this step) could not clone the -infra repo. Stack will NOT be pushed. [sandbox-infrastructure-template#143]" >&2
  fi
  if [ -z "$(getTfVar repo_clone_ssh_url)" ]; then
    echo "⚠️  [git-infra] WARNING: repo_clone_ssh_url is empty at persist time — cloud-provision's git_repo.auto.tfvars.json did not reach the apply working tree. [sandbox-infrastructure-template#143]" >&2
  fi

  # Each helper is individually guarded with `|| echo` so persistInfraRepo
  # honors its "Always returns 0" contract in EVERY caller context — not only
  # when the call site adds its own `|| …` (which suspends `set -e` across the
  # whole body). Without these guards a hard git failure (gitSnapshotCommit's
  # fetch or reset `return 1`, or a commit/gitPushInfra that aborts mid-body
  # under an active `set -e`, e.g. a rejecting pre-commit hook) could brick an
  # already-applied deploy if a future caller ever invoked persistInfraRepo bare.
  # Belt-and-suspenders on the exact #143 brick path.
  gitSnapshotCommit "auto-commit: deployed infrastructure [ci skip]" || echo "⚠️  [git-infra] WARNING: gitSnapshotCommit returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
  gitPushInfra || echo "⚠️  [git-infra] WARNING: gitPushInfra returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#143]" >&2

  return 0
}

# fetchInfraMain fetches infra/main into FETCH_HEAD and refs/remotes/infra/main.
# It prints one word: "fetched", "absent" (the remote has no main yet: a new,
# empty -infra repo) or "error" (the remote could not be listed or fetched).
# It names refs/heads/main in full both times: `git ls-remote --heads infra
# main` also matches a branch such as feature/main, and `git fetch infra main`
# takes a tag named main over the branch (refs/tags comes first), so the
# snapshot would sit on the wrong commit and its push be rejected. Run it in
# the project root, with an infra remote.
fetchInfraMain() {
  local rc=0
  git ls-remote --exit-code infra refs/heads/main >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0)
      if git fetch infra +refs/heads/main:refs/remotes/infra/main >&2; then
        echo fetched
      else
        echo error
      fi
      ;;
    2) echo absent ;; # --exit-code: no matching ref
    *) echo error ;;
  esac
}

# gitMergeInfraMain [--abort-on-conflict] merges infra/main into the project
# tree: pull.sh, and apply.sh before it applies, so a developer's stale
# checkout gets teammates' edits before Terraform runs. It behaves as a plain
# `git merge` (git refuses only local changes that overlap the merge), with
# one addition. Returns:
#   0  merged, nothing new to merge, or no infra remote or infra/main yet;
#   1  a merge is already in progress (never aborted here), infra/main
#      could not be fetched, the shallow clone could not be deepened,
#      merge-base failed, or the merge failed. With --abort-on-conflict (apply.sh) the failed merge is
#      aborted, so no MERGE_HEAD or conflict markers stay on disk for the
#      snapshot to push; without it (pull.sh) the conflict stays to resolve,
#      as gitMergeOriginMain leaves it.
#   2  not merged: the checkout is marked luther.infraSnapshotTree
#      (cloneInfraRepo laid the deploy archive over it), or there is nothing
#      to merge into: HEAD is unborn (the repo was cloned
#      while infra was empty), or the histories are unrelated (ui-core
#      squashes the project tree's history on every dispatch, so its tree
#      never shares a commit with infra/main). Nothing is merged; apply.sh
#      goes on and its snapshot commit lands on top of infra/main (#160).
gitMergeInfraMain() {
  local abort_on_conflict=false
  if [[ "${1:-}" == --abort-on-conflict ]]; then abort_on_conflict=true; fi

  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping git merge."
    popd >/dev/null
    return 0
  fi

  if ! git remote get-url infra >/dev/null 2>&1; then
    echo "Skipping gitMergeInfraMain: no infra remote configured"
    popd >/dev/null
    return 0
  fi

  # Refuse a merge someone else started, and never abort it below.
  if mergeInProgress; then
    echo_error "⚠️  A merge is in progress; finish or abort the merge in progress first."
    popd >/dev/null
    return 1
  fi

  if [[ "$(git config --bool luther.infraSnapshotTree || true)" == true ]]; then
    echo "ℹ️  infra/main not merged: this checkout holds the deploy archive (cloneInfraRepo); the snapshot commit replaces infra/main."
    popd >/dev/null
    return 2
  fi

  if ! git rev-parse -q --verify HEAD >/dev/null; then
    echo "ℹ️  infra/main not merged: HEAD has no commit yet (cloned while infra was empty)."
    popd >/dev/null
    return 2
  fi

  echo "🔄 Fetching infra/main…"
  case "$(fetchInfraMain)" in
    absent)
      echo "ℹ️  infra/main does not exist yet (new repo) - skipping merge"
      popd >/dev/null
      return 0
      ;;
    error)
      echo_error "⚠️  Could not fetch infra/main."
      popd >/dev/null
      return 1
      ;;
  esac

  # In a shallow clone the common ancestor can sit below the cut, and
  # merge-base would report none for related histories. A failed deepen is
  # an error: rc 2 would deploy a stale tree whose snapshot reverts a
  # teammate's commit.
  if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
    echo "🔄 Deepening the shallow clone from infra…"
    if ! git fetch --unshallow infra +refs/heads/main:refs/remotes/infra/main >&2; then
      echo_error "⚠️  Could not deepen the shallow clone."
      popd >/dev/null
      return 1
    fi
  fi

  # merge-base exits 1 only for "no common ancestor"; anything else is an
  # error, not unrelated histories.
  local mb_rc=0
  git merge-base HEAD infra/main >/dev/null || mb_rc=$?
  case "$mb_rc" in
    0) ;;
    1)
      echo "ℹ️  infra/main not merged: the project history and infra/main share no commit (ui-core's squashed tree)."
      popd >/dev/null
      return 2
      ;;
    *)
      echo_error "⚠️  git merge-base HEAD infra/main failed (exit $mb_rc)."
      popd >/dev/null
      return 1
      ;;
  esac

  echo "🔀 Merging (no-ff, auto-edit) infra/main…"
  if git merge infra/main --no-ff --no-edit; then
    echo "✅ Merge commit created."
  else
    echo_error "⚠️  Merge failed or conflicts detected."
    if [[ "$abort_on_conflict" == true ]] && git rev-parse -q --verify MERGE_HEAD >/dev/null; then
      echo_error "   Aborting the merge, so no conflict is left for the snapshot to push."
      git merge --abort >&2 || true
    fi
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
}

# gitSnapshotCommit commits the deployed project tree as one snapshot commit
# on top of infra/main, so gitPushInfra fast-forwards
# (sandbox-infrastructure-template#160, Phase 5). persistInfraRepo and
# apply.sh call it after the apply.
#
# The -infra repo is an output copy of the deployed state; ui-core (its
# project archive) is the source of truth. So the snapshot is exactly the
# deployed tree: a file only infra/main has is removed (it stays in the
# history), and a file in both takes the deployed version. Keeping
# infra-only files would bring back what a deploy removes on purpose, such
# as a removed component's .tf, and the -infra repo would keep declaring
# destroyed resources. Every -infra repo's only collaborator is
# sam-at-luther, so no customer work lives only there.
#
# Why not a merge: ui-core squashes the project tree's git history on every
# dispatch, so from a project's second deploy on the local history and
# infra/main share no commit. `git merge` refuses unrelated histories, the
# push was rejected non-fast-forward, and every push after the first was lost
# (warn-only).
#
# How: `git reset --mixed` onto infra/main moves HEAD and the index and does
# not touch the worktree (the tree the apply just deployed); gitStageTree
# then stages that tree. Not the --soft of the issue's design: --soft keeps a
# local index that can track an ignored file (the squashed tree of a project
# built from the old template tracks tf/auto-vars/common.auto.tfvars.json).
# That entry then differs from HEAD and from disk, untrackIgnoredFiles'
# `git rm --cached` refuses it, and `git add -A` commits the deploy-time
# credentials in it (tests/test-infra-push.sh Case M). With --mixed the index
# is infra/main's tree, and infra/main's modes stand for the files it has.
#
# A missing infra/main (a new repo) skips the reset, and the first push
# creates main. Returns 1 when infra/main cannot be fetched or the reset
# fails; callers treat that as non-fatal.
gitSnapshotCommit() {
  local msg="${1:-auto-commit: infrastructure changes [ci skip]}"
  pushd "$MARS_PROJECT_ROOT" >/dev/null

  if ! configure_git; then
    echo "⚠️  configure_git failed, skipping the snapshot commit."
    popd >/dev/null
    return 0
  fi

  # Before the reset: reset --mixed would drop MERGE_HEAD and the conflict
  # entries, and the markers on disk would then be committed.
  if mergeInProgress; then
    echo_error "⚠️  [git-infra] WARNING: a merge is in progress; finish or abort it first. No snapshot. [sandbox-infrastructure-template#160]"
    popd >/dev/null
    return 1
  fi

  local base="" line
  local -a exec_paths=()
  if git remote get-url infra >/dev/null 2>&1; then
    echo "🔄 Fetching infra/main…"
    case "$(fetchInfraMain)" in
      fetched)
        base="$(git rev-parse FETCH_HEAD)"
        # The project tree's own 100755 paths, before the reset replaces
        # the index with infra/main's modes; gitStageTree sets them again.
        while IFS= read -r -d '' line; do
          [[ "${line%% *}" == 100755 ]] && exec_paths+=("${line#*$'\t'}")
        done < <(git ls-files -s -z)
        echo "📸 Re-parenting the deployed tree on infra/main (snapshot commit)…"
        if ! git reset --quiet --mixed "$base"; then
          echo_error "⚠️  [git-infra] WARNING: git reset --mixed onto infra/main failed. [sandbox-infrastructure-template#160]"
          popd >/dev/null
          return 1
        fi
        ;;
      absent)
        echo "ℹ️  infra/main does not exist yet (new repo) - the first push creates it"
        ;;
      *)
        echo_error "⚠️  [git-infra] WARNING: could not fetch infra/main. [sandbox-infrastructure-template#160]"
        popd >/dev/null
        return 1
        ;;
    esac
  fi
  if ! gitStageTree "$base" 1 "${exec_paths[@]+"${exec_paths[@]}"}"; then
    popd >/dev/null
    return 1
  fi

  if git diff --cached --quiet; then
    echo "No changes to commit."
  else
    git commit -q -m "$msg"
    echo "✅ Snapshot commit created."
  fi

  popd >/dev/null
}

# ============================================================================
# Cloud Provider Detection
# ============================================================================

# getCloudProvider returns the cloud provider from tfvars
# Returns: "aws" or "gcp" (defaults to "aws" for backward compatibility)
getCloudProvider() {
  local cloud
  cloud=$(getTfVar "cloud_provider")

  if [[ -z "$cloud" || "$cloud" == "null" ]]; then
    echo "aws"
  else
    echo "$cloud"
  fi
}

# isGCP returns true if deploying to GCP
isGCP() {
  [[ "$(getCloudProvider)" == "gcp" ]]
}

# isAWS returns true if deploying to AWS
isAWS() {
  [[ "$(getCloudProvider)" == "aws" ]]
}

# ============================================================================
# Cloud-Specific File Selection
# ============================================================================

# _selectCloudFiles copies all cloud-specific .tf.tmpl templates for the
# active cloud into the current directory.  Matches two naming conventions:
#   providers-<cloud>.tf.tmpl  (provider declarations)
#   <cloud>-resources.tf.tmpl  (cloud-only resources, outputs, locals)
#
# The generated .tf files are gitignored so they never get committed.
# Designed for future mix/match mode: call once per cloud or extend the list.
_selectCloudFiles() {
  local cloud
  cloud=$(getCloudProvider)

  local tmpl target
  for tmpl in "providers-${cloud}.tf.tmpl" "${cloud}-resources.tf.tmpl"; do
    [[ -e "$tmpl" ]] || continue
    target="${tmpl%.tmpl}"
    cp "$tmpl" "$target"
    echo "Activated: $target"
  done
}

# ============================================================================
# GCP Credential Management
# ============================================================================

# GCP credential file path (set by setupGCPCredentials)
_GCP_CREDENTIALS_FILE=""
# 1 when setupGCPCredentials exported the scoped AWS session as AWS_* env vars
# for a keyless deploy, so cleanupGCPCredentials unsets them again.
_GCP_EXPORTED_AWS_SESSION=0
# The AWS_* env vars (declare -p) that the export replaced, restored on cleanup.
_GCP_SAVED_AWS_ENV=""

# _gcpDeployServiceAccount prints gcp_deploy_service_account, empty for a key
# deploy. A non-empty value makes the deploy keyless (ui-core#153).
_gcpDeployServiceAccount() {
  local sa
  sa=$(getTfVar "gcp_deploy_service_account")
  [[ "$sa" == "null" ]] && sa=""
  printf '%s' "$sa"
}

# setupGCPCredentials decodes gcp_credentials_b64 and writes it to a
# temporary file with secure permissions. Sets GOOGLE_APPLICATION_CREDENTIALS.
#
# Two kinds of credential (ui-core#153):
#   - A key deploy: a service_account key. gcp_deploy_service_account is empty.
#   - A keyless deploy: gcp_deploy_service_account names the customer's
#     deploy service account, and the credential is an external_account
#     credential that impersonates it through the platform's deploy workload
#     identity pool. It holds no key: Google's client libraries sign an AWS
#     GetCallerIdentity request with the pod's scoped AWS session and trade it
#     at Google STS. They read that session only from AWS_ACCESS_KEY_ID,
#     AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN and AWS_REGION (or
#     AWS_DEFAULT_REGION), so the session is exported here from the shared
#     credentials file ui-core's scope-aws init container wrote
#     (AWS_SHARED_CREDENTIALS_FILE).
# Returns: 0 on success, 1 on failure
setupGCPCredentials() {
  local creds_b64 deploy_sa cred_type
  creds_b64=$(getTfVar "gcp_credentials_b64")
  deploy_sa=$(_gcpDeployServiceAccount)

  if [[ -z "$creds_b64" || "$creds_b64" == "null" ]]; then
    echo_error "ERROR: gcp_credentials_b64 not found in tfvars"
    return 1
  fi

  # Create unique temporary file with secure permissions
  _GCP_CREDENTIALS_FILE=$(mktemp /tmp/gcp-sa-XXXXXX.json)
  chmod 600 "$_GCP_CREDENTIALS_FILE"

  # Decode and write (avoid logging the content)
  if ! echo "$creds_b64" | base64 -d > "$_GCP_CREDENTIALS_FILE" 2>/dev/null; then
    echo_error "ERROR: Failed to decode gcp_credentials_b64"
    rm -f "$_GCP_CREDENTIALS_FILE"
    return 1
  fi

  cred_type=$(jq -r '.type // ""' "$_GCP_CREDENTIALS_FILE" 2>/dev/null || echo "")
  if [[ -z "$deploy_sa" ]]; then
    if [[ "$cred_type" != "service_account" ]]; then
      echo_error "ERROR: Invalid service account key format"
      rm -f "$_GCP_CREDENTIALS_FILE"
      return 1
    fi
  else
    if ! _checkGCPExternalAccount "$_GCP_CREDENTIALS_FILE" "$deploy_sa" || ! _exportScopedAWSSession; then
      rm -f "$_GCP_CREDENTIALS_FILE"
      _GCP_CREDENTIALS_FILE=""
      return 1
    fi
    echo "GCP keyless deploy: impersonating $deploy_sa through workload identity federation"
  fi

  export GOOGLE_APPLICATION_CREDENTIALS="$_GCP_CREDENTIALS_FILE"
  echo "GCP credentials configured: $GOOGLE_APPLICATION_CREDENTIALS"
  return 0
}

# _checkGCPExternalAccount checks that the credential file is the AWS
# external_account credential ui-core writes for a keyless deploy, and that it
# impersonates deploy_sa. A mismatch would make cloud-provision grant token
# creator to an account the deploy does not run as.
_checkGCPExternalAccount() {
  local file="$1" deploy_sa="$2" want_url
  want_url="https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${deploy_sa}:generateAccessToken"
  if ! jq -e --arg url "$want_url" '
      .type == "external_account"
      and .subject_token_type == "urn:ietf:params:aws:token-type:aws4_request"
      and (.credential_source.environment_id // "" | startswith("aws"))
      and .service_account_impersonation_url == $url' "$file" >/dev/null 2>&1; then
    echo_error "ERROR: gcp_deploy_service_account is set, but gcp_credentials_b64 is not an AWS external_account credential that impersonates ${deploy_sa} [ui-core#153]"
    return 1
  fi
  return 0
}

# _exportScopedAWSSession exports the pod's scoped AWS session as AWS_* env
# vars, for the external_account credential of a keyless GCP deploy. It reads
# the session from the shared credentials file the scope-aws init container
# wrote (AWS_SHARED_CREDENTIALS_FILE, profile AWS_PROFILE or default), ahead of
# any key pair already in the env: a nested run can inherit an unrelated one,
# and Google STS would refuse it with a 403 far from the cause. Only without
# that file is an env session used. The region comes from AWS_REGION or
# AWS_DEFAULT_REGION, which Google's AWS source both read.
_exportScopedAWSSession() {
  if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
    echo_error "ERROR: a keyless GCP deploy needs AWS_REGION (the region of the AWS session it signs with) [ui-core#153]"
    return 1
  fi
  if [[ -n "${JUMP_ROLE_ARN:-}" ]]; then
    echo_error "ERROR: a keyless GCP deploy signs with the scoped AWS session, which JUMP_ROLE_ARN would replace; unset it [ui-core#153]"
    return 1
  fi
  local file="${AWS_SHARED_CREDENTIALS_FILE:-}" profile="${AWS_PROFILE:-default}"
  if [[ -z "$file" ]]; then
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
      echo "GCP keyless deploy: signing with the AWS session in the environment"
      return 0
    fi
    echo_error "ERROR: a keyless GCP deploy needs the pod's scoped AWS session, but AWS_SHARED_CREDENTIALS_FILE is unset; it needs scoped terraform credentials [ui-core#153]"
    return 1
  fi
  local session key secret token
  if [[ ! -r "$file" ]] || ! session=$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
      aws configure export-credentials --profile "$profile" --format process 2>/dev/null); then
    echo_error "ERROR: cannot read the AWS session of profile ${profile} from ${file} [ui-core#153]"
    return 1
  fi
  key=$(jq -r '.AccessKeyId // ""' <<<"$session")
  secret=$(jq -r '.SecretAccessKey // ""' <<<"$session")
  token=$(jq -r '.SessionToken // ""' <<<"$session")
  if [[ -z "$key" || -z "$secret" ]]; then
    echo_error "ERROR: profile ${profile} in ${file} has no AWS access key [ui-core#153]"
    return 1
  fi
  _GCP_SAVED_AWS_ENV=$(declare -p AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true)
  export AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret"
  if [[ -n "$token" ]]; then
    export AWS_SESSION_TOKEN="$token"
  else
    unset AWS_SESSION_TOKEN
  fi
  _GCP_EXPORTED_AWS_SESSION=1
  echo "GCP keyless deploy: signing with the AWS session of profile ${profile}"
  return 0
}

# cleanupGCPCredentials removes the temporary credential file, and the AWS
# session env vars setupGCPCredentials exported for a keyless deploy.
cleanupGCPCredentials() {
  if [[ -n "$_GCP_CREDENTIALS_FILE" ]] && [[ -f "$_GCP_CREDENTIALS_FILE" ]]; then
    rm -f "$_GCP_CREDENTIALS_FILE"
    echo "Cleaned up GCP credentials file"
  fi
  _GCP_CREDENTIALS_FILE=""
  unset GOOGLE_APPLICATION_CREDENTIALS 2>/dev/null || true
  if [[ "$_GCP_EXPORTED_AWS_SESSION" == "1" ]]; then
    # Put back whatever AWS_* the env held before the export.
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    if [[ -n "$_GCP_SAVED_AWS_ENV" ]]; then
      eval "${_GCP_SAVED_AWS_ENV//declare /declare -g }"
    fi
    _GCP_SAVED_AWS_ENV=""
    _GCP_EXPORTED_AWS_SESSION=0
  fi
}

# ============================================================================
# AWS Jump Role
# ============================================================================

# assumeJumpRole assumes the role specified by JUMP_ROLE_ARN (if set).
# Exports temporary AWS credentials for the assumed role.
assumeJumpRole() {
  if [[ -z "${JUMP_ROLE_ARN:-}" ]]; then
    return 0
  fi

  echo "Assuming jump role: $JUMP_ROLE_ARN"
  local creds_json
  creds_json=$(aws sts assume-role \
    --role-arn "$JUMP_ROLE_ARN" \
    --role-session-name "mars-jump-session" \
    --output json)

  AWS_ACCESS_KEY_ID=$(echo "$creds_json" | jq -r .Credentials.AccessKeyId)
  AWS_SECRET_ACCESS_KEY=$(echo "$creds_json" | jq -r .Credentials.SecretAccessKey)
  AWS_SESSION_TOKEN=$(echo "$creds_json" | jq -r .Credentials.SessionToken)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "Now running under assumed jump role credentials"
}

# ============================================================================
# Cloud Environment Setup
# ============================================================================

# setupCloudEnv configures the environment for the target cloud provider.
# Call this before running terraform commands.
# Returns: 0 on success, 1 on failure
setupCloudEnv() {
  local cloud
  cloud=$(getCloudProvider)

  echo "Setting up environment for cloud provider: $cloud"

  # Activate cloud-specific templates (copies .tf.tmpl -> .tf)
  _selectCloudFiles

  case "$cloud" in
    gcp)
      # Setup GCP credentials
      if ! setupGCPCredentials; then
        return 1
      fi

      # Export GCP project and region
      local gcp_project gcp_region
      gcp_project=$(getTfVar "gcp_project_id")
      gcp_region=$(getTfVar "gcp_region")

      if [[ -z "$gcp_project" || "$gcp_project" == "null" ]]; then
        echo_error "ERROR: gcp_project_id not found in tfvars"
        return 1
      fi

      if [[ -z "$gcp_region" || "$gcp_region" == "null" ]]; then
        echo_error "ERROR: gcp_region not found in tfvars"
        return 1
      fi

      export GOOGLE_PROJECT="$gcp_project"
      export GOOGLE_REGION="$gcp_region"

      echo "GCP environment configured:"
      echo "  GOOGLE_PROJECT=$GOOGLE_PROJECT"
      echo "  GOOGLE_REGION=$GOOGLE_REGION"
      echo "  GOOGLE_APPLICATION_CREDENTIALS=$GOOGLE_APPLICATION_CREDENTIALS"

      # Fail-fast GCP bootstrap-permission preflight (luthersystems/reliable#2243).
      # Only the cloud-provision stage creates the GCS tfstate bucket + the two
      # service accounts + the Owner grant, so scope the check to that stage
      # dir — every other stage is left untouched. CWD is the stage dir here
      # (setupCloudEnv already assumes this via _selectCloudFiles), so gate on
      # its basename. The preflight runs BEFORE any terraform init/plan/apply
      # (this is the earliest hook where GOOGLE_APPLICATION_CREDENTIALS is set),
      # so a missing-permission failure aborts before repo.tf's GitHub side
      # creates the orphaned partial state #2243 was about. gcp-preflight.sh
      # fails OPEN on its own infra/transport errors and only fails CLOSED
      # (exit 1) on a definitive verdict.
      # A keyless deploy (gcp_deploy_service_account, ui-core#153) skips it:
      # the preflight can mint a token only from a service_account key, and
      # the oracle already ran the same permission checks as the federated
      # identity before it started the job.
      local gcp_deploy_sa
      gcp_deploy_sa=$(_gcpDeployServiceAccount)
      if [[ "$(basename "$PWD")" == "cloud-provision" && -n "$gcp_deploy_sa" ]]; then
        echo "GCP bootstrap preflight: skipped for a keyless deploy (the oracle checked ${gcp_deploy_sa})"
      elif [[ "$(basename "$PWD")" == "cloud-provision" ]]; then
        if ! bash "$MARS_PROJECT_ROOT/tf/gcp-preflight.sh" "$GOOGLE_PROJECT"; then
          echo_error "ERROR: GCP bootstrap permission preflight failed — aborting before terraform runs. [reliable#2243]"
          return 1
        fi
      fi
      ;;

    aws)
      # AWS uses IRSA (IAM Roles for Service Accounts) for AWS auth.
      # No GCP provider or credentials needed — all cloud-specific resources
      # and providers are isolated in .tf.tmpl template files.
      echo "AWS environment: using IRSA"

      # Fail-fast AWS bootstrap-permission preflight (luthersystems/reliable#2243).
      # Twin of the GCP preflight above. Only the cloud-provision stage creates
      # the S3 tfstate bucket + KMS key + the admin/inspector IAM roles, so scope
      # the check to that stage dir — every other stage is left untouched. CWD is
      # the stage dir here. The preflight runs BEFORE any terraform init/plan/apply
      # so a denied-action failure aborts before repo.tf's GitHub side creates the
      # orphaned partial state #2243 was about. providers-aws.tf.tmpl has the aws
      # provider assume the customer bootstrap_role (with aws_external_id), so pass
      # those from tfvars — the preflight assumes that role and simulates against
      # it (empty bootstrap_role ⇒ it simulates the ambient caller identity).
      # aws-preflight.sh fails OPEN on its own infra/transport errors (incl. an
      # inability to run the simulation) and only fails CLOSED on a definitive
      # denied-action verdict or an explicit AccessDenied on the assume-role.
      # NOTE: assumeJumpRole runs after this case; in the mars/Argo deploy path
      # JUMP_ROLE_ARN is unset, so the ambient (IRSA) creds the preflight uses to
      # assume bootstrap_role match those terraform will use.
      if [[ "$(basename "$PWD")" == "cloud-provision" ]]; then
        local aws_bootstrap_role aws_external_id aws_region_v aws_access_key_id
        aws_bootstrap_role=$(getTfVar "bootstrap_role")
        aws_external_id=$(getTfVar "aws_external_id")
        aws_region_v=$(getTfVar "aws_region")
        aws_access_key_id=$(getTfVar "aws_access_key_id")
        # Customer credentials are required (luthersystems/reliable#2461).
        # With neither a bootstrap_role nor access keys, the aws provider
        # falls back to the runner's own IRSA identity and builds the
        # customer's stack in the platform account. Refuse instead.
        if [[ -z "$aws_bootstrap_role" && -z "$aws_access_key_id" ]]; then
          echo_error "ERROR: no customer AWS credentials (bootstrap_role or aws_access_key_id) — refusing to run as the runner's own identity. [reliable#2461]"
          return 1
        fi
        # Access-key mode: ui-core already simulated the required actions
        # against these keys before dispatch. The preflight below only
        # knows role and ambient modes, and ambient would check the runner
        # instead of the customer, so skip it here.
        if [[ -n "$aws_access_key_id" && -z "$aws_bootstrap_role" ]]; then
          echo "AWS credentials: customer access keys (bootstrap preflight skipped)"
        elif ! AWS_BOOTSTRAP_ROLE="$aws_bootstrap_role" \
             AWS_EXTERNAL_ID="$aws_external_id" \
             AWS_PREFLIGHT_REGION="${aws_region_v:-us-east-1}" \
             bash "$MARS_PROJECT_ROOT/tf/aws-preflight.sh" "$aws_bootstrap_role"; then
          echo_error "ERROR: AWS bootstrap permission preflight failed — aborting before terraform runs. [reliable#2243]"
          return 1
        fi
      fi
      ;;

    *)
      echo_error "ERROR: Unknown cloud provider: $cloud"
      return 1
      ;;
  esac

  # Handle AWS jump role assumption (applies to all providers)
  assumeJumpRole

  return 0
}

# cleanupCloudEnv cleans up any cloud-specific resources (credential files, etc.)
# Call this on script exit (typically via trap)
cleanupCloudEnv() {
  local cloud
  cloud=$(getCloudProvider)

  case "$cloud" in
    gcp)
      cleanupGCPCredentials
      ;;
  esac
}

# logTemplateVersion logs the infrastructure template version.
# Reads template_ref from TF auto-vars (set by Oracle during template refresh).
logTemplateVersion() {
  local ver
  ver=$(getTfVar "template_ref")
  echo "template_version=${ver:-unknown}"
}

# exportTemplateVersion exports TEMPLATE_VERSION and logs template_version=<sha>.
# Use in scripts that invoke child processes (e.g. drift-check.sh) which read
# TEMPLATE_VERSION from env. For log-only use, prefer logTemplateVersion.
exportTemplateVersion() {
  export TEMPLATE_VERSION
  TEMPLATE_VERSION="$(getTfVar template_ref)"
  echo "template_version=${TEMPLATE_VERSION:-unknown}"
}

# logPresetsVersion logs the insideout-terraform-presets module version.
# Reads presets_ref from TF auto-vars (written alongside template_ref).
logPresetsVersion() {
  local ver
  ver=$(getTfVar "presets_ref")
  echo "presets_version=${ver:-unknown}"
}

# exportPresetsVersion exports PRESETS_VERSION and logs presets_version=<sha>.
# Use in scripts that invoke child processes (e.g. drift-check.sh) which read
# PRESETS_VERSION from env. For log-only use, prefer logPresetsVersion.
exportPresetsVersion() {
  export PRESETS_VERSION
  PRESETS_VERSION="$(getTfVar presets_ref)"
  echo "presets_version=${PRESETS_VERSION:-unknown}"
}
