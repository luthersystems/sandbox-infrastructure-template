# figure out where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -euo pipefail

# if you’ve not already exported MARS, point it at our wrapper
export MARS="${SCRIPT_DIR}/run-with-creds.sh"
# make sure it’s executable
chmod +x "${MARS}" 2>/dev/null || :

TF_LOG=${TF_LOG:-""}

if [ -n "${TF_LOG}" ]; then
  set -x
fi

workspace=$1

tf_workspace=default # TODO make variable

export TF_PLUGIN_CACHE_DIR="$HOME/.tf-plugin-cache"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

tfBootstrap() {
  if [ -f "bootstrap.sh" ]; then
    # source so that any exports (e.g. JUMP_ROLE_ARN) stick around
    . bootstrap.sh
  fi
}

tfSetup() {
  cp -rf auto-vars/* "${workspace}/"
}

tfSetup
cd "$workspace"
tfBootstrap

tfInit() {
  $MARS ${tf_workspace} init --reconfigure
}

tfPlan() {
  $MARS ${tf_workspace} plan
}

tfApply() {
  $MARS ${tf_workspace} apply --approve
}

tfDestroy() {
  $MARS ${tf_workspace} destroy --approve
}

gitCommit() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipping git commit: not inside a git repo."
    return 0
  fi

  local msg="${1:-"terraform: auto-commit after apply [ci skip]"}"
  git add . # Stages all new and modified files (respects .gitignore)

  if ! git diff --cached --quiet; then
    git commit -m "$msg"
    echo "✅ Git commit created."
  else
    echo "No changes to commit."
  fi
}
