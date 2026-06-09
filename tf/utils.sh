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
  # #2048: a stack that adopted reverse-Terraform-imported (customer-owned)
  # resources carries `removed { ... lifecycle { destroy = false } }` blocks in
  # its composed archive. `terraform destroy` destroys everything in state, so
  # running it directly would DELETE those pre-existing resources. When such
  # blocks are present, FIRST apply them so terraform forgets the adopted
  # addresses from state without deleting them, THEN destroy — which now only
  # tears down resources this stack actually manages.
  #
  # The pre-destroy apply runs through mars' `--forbid-resource-changes` guard:
  # it refuses (and aborts the destroy) if that apply would create/update/delete
  # any real resource, so the forget-step can never silently mutate
  # infrastructure. cwd here is the stage dir holding the composed *.tf files.
  # Gated on a removed{} block actually being present, so non-import stacks keep
  # the plain init -> destroy path unchanged.
  local removed_present=false
  shopt -s nullglob
  local f
  for f in *.tf; do
    if grep -Eqs '^[[:space:]]*removed[[:space:]]*\{' "$f"; then
      removed_present=true
      break
    fi
  done
  shopt -u nullglob
  if [[ "$removed_present" == true ]]; then
    echo "tfDestroy: removed{} block(s) present — forgetting adopted imports before destroy (apply --forbid-resource-changes) [#2048]"
    # Strip any plan-only CLI args Oracle may have set in the job env (invalid
    # for a plain apply); mirrors plan-all.sh. Subshell keeps the unset local.
    ( unset TF_CLI_ARGS_plan TF_CLI_ARGS_apply; $MARS ${tf_workspace} apply --forbid-resource-changes )
  fi
  $MARS ${tf_workspace} destroy --approve
}
