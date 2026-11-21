# shellcheck shell=bash
# stages.sh — the template's calls to the mars stage commands: plan-all,
# plan-stage and apply-stage, configured by mars-stages.yaml at the project
# root (luthersystems/mars docs/stages.md).
#
# Why this exists: the loop over stages, the saved plans, the plan JSON,
# the change counts, the drift gate and the outputs capture used to be
# shell and jq in plan-all.sh, plan.sh, apply-plan.sh, apply-with-outputs.sh
# and drift-refresh.sh. mars now does them in Go, with tests there, so the
# scripts are thin entrypoints that keep the names and arguments ui-core
# calls and the /marsproject/outputs files it reads (#114). What stays here
# is what is the template's own and not Terraform:
#   - the stage files: utils.sh tfSetup (auto-vars and the credential drop)
#     and the stage's bootstrap.sh (the backend file, account-setup's
#     JUMP_ROLE_ARN);
#   - the cloud credentials and the bootstrap preflight (shell_utils.sh);
#   - the -infra git steps (marsInfra);
#   - the flags ui-core passes in the environment (TF_CLI_ARGS_plan).
#
# Source it after shell_utils.sh, with MARS_PROJECT_ROOT set.

# The mars environment of every stage command. It is fixed at "default", as
# tf_workspace in utils.sh is (#185): mars selects the workspace of that name
# and reads vars/default/ in the stage directory.
MARS_STAGES_ENV=default

# marsStages <command> [args...] runs a mars stage command on the template's
# mars-stages.yaml, from the project root. It needs a native mars
# (resolveNativeMarsCLI says why). Its exit code is the command's.
marsStages() {
  local cmd="$1" bin
  shift
  bin="$(resolveNativeMarsCLI)" || return 1
  (cd "$MARS_PROJECT_ROOT" && "$bin" "$MARS_STAGES_ENV" "$cmd" --config mars-stages.yaml "$@")
}

# stagePlanFile prints the saved plan name that ui-core asks for with -out in
# TF_CLI_ARGS_plan, or nothing. ui-core plans with -out={planID}.tfplan and
# applies {planID}.tfplan in a later step (apply-plan.sh --plan-file). The
# -out that mars adds comes after TF_CLI_ARGS_plan on terraform's command
# line and wins, so the name must reach mars as --plan-file instead.
stagePlanFile() {
  local -a words
  local i out=""
  read -ra words <<<"${TF_CLI_ARGS_plan:-}"
  for ((i = 0; i < ${#words[@]}; i++)); do
    case "${words[i]}" in
      -out=* | --out=*) out="${words[i]#*=}" ;;
      -out | --out)
        out="${words[i + 1]:-}"
        i=$((i + 1))
        ;;
    esac
  done
  printf '%s' "$out"
}

# exportStageParallelism adds the template's Terraform parallelism to the
# environment, as utils.sh tfPlan and tfApply do: plans at 20 (TF_PARALLELISM)
# to halve the AWS Describe* refresh time on 30 to 50 resource stacks, applies
# at Terraform's default unless TF_APPLY_PARALLELISM is set. It goes through
# TF_CLI_ARGS_plan and TF_CLI_ARGS_apply, which terraform reads itself, so
# mars needs no flag for it.
exportStageParallelism() {
  TF_CLI_ARGS_plan="${TF_CLI_ARGS_plan:+$TF_CLI_ARGS_plan }-parallelism=${TF_PARALLELISM:-20}"
  export TF_CLI_ARGS_plan
  if [[ -n "${TF_APPLY_PARALLELISM:-}" ]]; then
    TF_CLI_ARGS_apply="${TF_CLI_ARGS_apply:+$TF_CLI_ARGS_apply }-parallelism=$TF_APPLY_PARALLELISM"
    export TF_CLI_ARGS_apply
  fi
}

# enterStage <stage> stages the stage's files and enters its directory, in
# this shell, as the scripts always did through utils.sh. bootstrap.sh is
# sourced here, so what it exports (account-setup's JUMP_ROLE_ARN) reaches
# the cloud setup and the mars call.
enterStage() {
  cd "$MARS_PROJECT_ROOT/tf"
  set -- "$1"
  # shellcheck source=tf/utils.sh
  . "$MARS_PROJECT_ROOT/tf/utils.sh"
}

# stageCloudEnv <stage> sets up the cloud for the stage whose directory is
# the current directory (setupCloudEnv: its .tf files, credentials and
# preflight), arms the credential cleanup, and marks the stage prepared, so
# the mars setup hook (stage-setup.sh) does not stage it a second time and
# run the preflight twice.
stageCloudEnv() {
  setupCloudEnv || return 1
  trap 'cleanupCloudEnv' EXIT
  export MARS_STAGE_PREPARED="$1"
}

# prepareStage <stage> is enterStage then stageCloudEnv: the setup of a
# script that runs one stage.
prepareStage() {
  enterStage "$1"
  stageCloudEnv "$1"
}

# driftApplySkipped prints true when the drift report says the apply was
# skipped on actionable drift (apply-stage --check-drift, template#108).
driftApplySkipped() {
  jq -r '.apply_skipped // false' "$MARS_PROJECT_ROOT/outputs/drift.json" 2>/dev/null || echo false
}

# persistCustomStack persists the applied custom stack to the per-project
# -infra repo (#143). ui-core's custom-stack apply runs apply-plan.sh or
# apply-with-outputs.sh --check-drift, never apply.sh, so without this the
# -infra repo stays empty after a successful deploy. Only custom-stack-provision:
# it carries the full generated stack and has the infra .git and remote that
# prepare-custom-stack wired; earlier stages have no .git yet and would only
# warn. Non-fatal by contract: a push problem must not fail an applied deploy.
persistCustomStack() {
  [[ "$1" == "custom-stack-provision" ]] || return 0
  marsInfra infra-persist ||
    echo "⚠️  [git-infra] WARNING: mars infra-persist returned non-zero (non-fatal; deploy already applied). [sandbox-infrastructure-template#143]" >&2
}

# applyStageWithInfraSync <stage> [apply-stage flags...] is the apply of
# apply.sh and of apply-with-outputs.sh without --check-drift, for the stage
# whose files enterStage staged:
#   1. Merge infra/main before Terraform runs, so a developer's stale
#      checkout applies with teammates' edits. A failed merge stops the
#      apply; --abort-on-conflict cleans it up first, so the snapshot of a
#      later run cannot push conflict markers (a merge it did not start is
#      refused, not aborted). rc 2 does not stop it: a checkout infra-clone
#      laid the deploy archive over, an unborn HEAD, or ui-core's squashed
#      tree, which shares no commit with infra/main (#160).
#   2. The cloud setup, after the merge, so the cloud's .tf files are copied
#      from the merged templates.
#   3. mars apply-stage: plan, then apply that plan.
#   4. Snapshot and push the deployed tree. A git problem must not fail a
#      deploy that already applied. The snapshot fetches infra/main again: a
#      teammate may have pushed during the apply, and the push must
#      fast-forward.
applyStageWithInfraSync() {
  local stage="$1" merge_rc=0
  shift
  marsInfra infra-merge --abort-on-conflict || merge_rc=$?
  if [[ "$merge_rc" -ne 0 && "$merge_rc" -ne 2 ]]; then
    return "$merge_rc"
  fi
  stageCloudEnv "$stage" || return 1
  marsStages apply-stage "$stage" "$@" || return $?
  marsInfra infra-snapshot "auto-commit: infrastructure changes [ci skip]" ||
    echo "⚠️  [git-infra] WARNING: mars infra-snapshot returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
  marsInfra infra-push ||
    echo "⚠️  [git-infra] WARNING: mars infra-push returned non-zero (continuing; non-fatal). [sandbox-infrastructure-template#160]" >&2
}
