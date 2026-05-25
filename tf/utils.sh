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
  # Bump parallelism above terraform's default of 10 to speed up state
  # refresh on customer stacks with many resources. AWS Describe* APIs
  # tolerate 20 concurrent requests comfortably; reads are not throttle-
  # sensitive the way writes are. Override via TF_PARALLELISM if needed.
  $MARS ${tf_workspace} plan -parallelism="${TF_PARALLELISM:-20}"
}

tfApply() {
  # Apply hits write APIs which are more rate-limit sensitive than the
  # plan-time Describe* calls, so we keep apply at terraform's default
  # parallelism unless explicitly overridden via TF_APPLY_PARALLELISM.
  if [[ -n "${TF_APPLY_PARALLELISM:-}" ]]; then
    $MARS ${tf_workspace} apply -parallelism="${TF_APPLY_PARALLELISM}" --approve
  else
    $MARS ${tf_workspace} apply --approve
  fi
}

tfDestroy() {
  tfInit
  $MARS ${tf_workspace} destroy --approve
}
