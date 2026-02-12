# shellcheck shell=bash
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
  mkdir -p "${workspace}"
  if [ -d "auto-vars" ]; then
    cp -rf auto-vars/* "${workspace}/" 2>/dev/null || true
  fi
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
