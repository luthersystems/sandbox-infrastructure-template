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

  # #160 Phase 1: stage the customer cloud credentials from the gitignored
  # secrets/ dir into the stage working dir as a single auto-loaded tfvars file
  # (zz-secret.auto.tfvars.json — the zz- prefix sorts it last so it overrides).
  # Because secrets/ (and tf/*/zz-secret.auto.tfvars.json) are gitignored, this
  # keeps credentials OFF the persistInfraRepo `git add -A` push — unlike
  # common.auto.tfvars.json under tf/auto-vars/. tfSetup's CWD is tf/ (not the
  # project root), so use the absolute $MARS_PROJECT_ROOT path. Multiple
  # *.auto.tfvars.json cannot be concatenated (invalid JSON), so copy only the
  # canonical cloud-credentials.auto.tfvars.json and warn on any other match.
  # Guarded on MARS_PROJECT_ROOT being set (the real apply paths always export
  # it before sourcing utils.sh; some narrow unit tests source utils.sh without
  # it, and the original relative-only tfSetup never referenced it — so under
  # `set -u` the unset case must stay a no-op). No-op when secrets/ is absent or
  # has no tfvars (today's state): nullglob makes the loop body simply not run.
  if [ -n "${MARS_PROJECT_ROOT:-}" ] && [ -d "${MARS_PROJECT_ROOT}/secrets" ]; then
    local secrets_dir="${MARS_PROJECT_ROOT}/secrets"
    local canonical="${secrets_dir}/cloud-credentials.auto.tfvars.json"
    local sf staged=0
    shopt -s nullglob
    for sf in "${secrets_dir}"/*.auto.tfvars.json; do
      if [ "$sf" = "$canonical" ]; then
        cp -f "$sf" "${workspace}/zz-secret.auto.tfvars.json"
        staged=1
      else
        echo "⚠️  [secrets] WARNING: ignoring non-canonical secrets tfvars '$sf' — only cloud-credentials.auto.tfvars.json is staged (concatenating multiple JSON tfvars is invalid). [sandbox-infrastructure-template#160]" >&2
      fi
    done
    shopt -u nullglob
    if [ "$staged" = 1 ]; then
      echo "🔐 [secrets] staged secrets/cloud-credentials.auto.tfvars.json → ${workspace}/zz-secret.auto.tfvars.json [sandbox-infrastructure-template#160]"
    fi
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

# tfDestroy [--ignore-drift] — pre-destroy convergence gate + adopted-import
# protection (#2048).
#
# A stack that adopted reverse-Terraform-imported (customer-owned) resources
# carries `removed { ... lifecycle { destroy = false } }` blocks in its
# composed archive. `terraform destroy` destroys everything in state, so
# running it directly would DELETE those pre-existing resources; `removed{}`
# is an APPLY-time construct that destroy ignores. The pre-destroy apply
# executes those forgets (releasing the adopted addresses from state without
# deleting them) AND — via mars' `--forbid-resource-changes` guard — fails if
# the archive would create/update/delete any real resource. An apply that is
# not a state-only no-op at destroy time means drift or a half-applied stack;
# destroying on top of that deserves a human decision (--ignore-drift), not
# an automatic teardown.
#
# Semantics matrix (guard = mars supports `apply --forbid-resource-changes`,
# probed via `apply --help` so an older pinned mars degrades gracefully
# instead of erroring on an unknown flag):
#
#   guard  | removed{} | --ignore-drift | behavior
#   -------+-----------+----------------+------------------------------------
#   yes    | any       | no             | guarded apply (gate + forgets) -> destroy
#   yes/no | yes       | yes            | UNguarded apply (forgets; drift accepted) -> destroy
#   yes/no | no        | yes            | plain destroy (gate skipped)
#   no     | no        | no             | WARN + plain destroy (legacy behavior)
#   no     | yes       | no             | FAIL — adopted imports cannot be
#                                         destroyed safely without the guard;
#                                         bump the mars image or pass
#                                         --ignore-drift (human accepts the
#                                         unguarded forget-apply).
#
# cwd here is the stage dir holding the composed *.tf files.
tfDestroy() {
  local ignore_drift=false
  if [[ "${1:-}" == "--ignore-drift" ]]; then
    ignore_drift=true
  fi
  tfInit

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

  if [[ "$ignore_drift" == true ]]; then
    if [[ "$removed_present" == true ]]; then
      # Forgets are NEVER skippable (data-loss invariant); the override only
      # downgrades the guard: the operator accepted whatever drift the apply
      # carries alongside the forgets. Strip plan-only CLI args Oracle may
      # have set (invalid for a plain apply); mirrors plan-all.sh. Subshell
      # keeps the unset local.
      echo "tfDestroy: --ignore-drift — applying forgets UNGUARDED before destroy (drift accepted by operator) [#2048]"
      ( unset TF_CLI_ARGS_plan TF_CLI_ARGS_apply; tfApply )
    else
      echo "tfDestroy: --ignore-drift — skipping pre-destroy convergence gate [#2048]"
    fi
  else
    # Capture help output first, then grep the captured string: a direct
    # `$MARS ... --help | grep -q` pipeline under pipefail can false-negative
    # when grep -q exits early and the producer dies on SIGPIPE. `|| true`
    # guards set -e if an old wrapper errors on --help.
    local guard_supported=false
    local mars_apply_help
    mars_apply_help=$($MARS ${tf_workspace} apply --help 2>&1 || true)
    if grep -q -- '--forbid-resource-changes' <<<"$mars_apply_help"; then
      guard_supported=true
    fi
    if [[ "$guard_supported" == true ]]; then
      echo "tfDestroy: pre-destroy convergence gate (apply --forbid-resource-changes) [#2048]"
      ( unset TF_CLI_ARGS_plan TF_CLI_ARGS_apply; $MARS ${tf_workspace} apply --forbid-resource-changes )
    elif [[ "$removed_present" == true ]]; then
      echo "ERROR: tfDestroy: archive carries removed{} blocks (adopted imports) but this mars image lacks 'apply --forbid-resource-changes'." >&2
      echo "ERROR: destroying now would DELETE the adopted resources. Bump the mars image, or re-run with --ignore-drift to apply the forgets unguarded. [#2048]" >&2
      return 1
    else
      echo "WARNING: tfDestroy: mars image lacks 'apply --forbid-resource-changes'; skipping pre-destroy convergence gate (legacy destroy) [#2048]"
    fi
  fi
  $MARS ${tf_workspace} destroy --approve
}
