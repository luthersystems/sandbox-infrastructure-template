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
  # Bump terraform's default plan parallelism (10) → 20 to halve the AWS
  # Describe* refresh funnel on customer stacks with 30-50 resources.
  # Override via TF_PARALLELISM if needed.
  #
  # IMPORTANT: must thread the flag through TF_CLI_ARGS_plan rather than
  # passing `-parallelism=…` directly to $MARS. The $MARS wrapper parses
  # unrecognized flags itself and errors with "unknown flag -p" before
  # the call ever reaches the terraform binary inside the container.
  # TF_CLI_ARGS_plan is read directly by terraform and prepended to its
  # actual command line, so the parallelism flag lands where it belongs.
  local parallelism="${TF_PARALLELISM:-20}"
  local args="-parallelism=${parallelism}"
  if [[ -n "${TF_CLI_ARGS_plan:-}" ]]; then
    args="${TF_CLI_ARGS_plan} ${args}"
  fi
  TF_CLI_ARGS_plan="${args}" $MARS ${tf_workspace} plan
}

tfApply() {
  # Apply hits write APIs which are more rate-limit sensitive than the
  # plan-time Describe* calls, so we keep apply at terraform's default
  # parallelism unless explicitly overridden via TF_APPLY_PARALLELISM.
  # Same wrapper-flag-parsing gotcha as tfPlan: thread through
  # TF_CLI_ARGS_apply rather than the direct CLI.
  if [[ -n "${TF_APPLY_PARALLELISM:-}" ]]; then
    local args="-parallelism=${TF_APPLY_PARALLELISM}"
    if [[ -n "${TF_CLI_ARGS_apply:-}" ]]; then
      args="${TF_CLI_ARGS_apply} ${args}"
    fi
    TF_CLI_ARGS_apply="${args}" $MARS ${tf_workspace} apply --approve
  else
    $MARS ${tf_workspace} apply --approve
  fi
}

tfDestroy() {
  tfInit
  $MARS ${tf_workspace} destroy --approve
}
