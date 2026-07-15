#!/bin/bash
# destroy.sh — Destroy a lifecycle stage's terraform-managed resources.
#
# Usage: bash destroy.sh <lifecycle> [--ignore-drift]
#
# Default behavior is a pre-destroy convergence gate (#2048): tfDestroy runs
# `mars apply --forbid-resource-changes` before `destroy`, which
#   - executes any `removed { lifecycle { destroy = false } }` forgets the
#     composed archive carries (adopted / reverse-imported resources are
#     released from state WITHOUT being deleted), and
#   - fails the job if the archive would create/update/delete any real
#     resource — unexpected changes at destroy time mean drift or a
#     half-applied stack, and tearing infrastructure down on top of that
#     deserves a human decision, not an automatic destroy.
#
# --ignore-drift is that human decision (same end-to-end override channel as
# the apply path: reliable API ?ignore_drift=true → workflow args → argv).
# See tfDestroy in utils.sh for the exact semantics matrix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: destroy.sh <lifecycle> [--ignore-drift]" >&2
  exit 1
fi
lifecycle="$1"
shift

ignore_drift=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore-drift) ignore_drift=true; shift ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Source utils.sh (expects $1 = workspace/lifecycle) — mirrors apply-plan.sh.
set -- "$lifecycle"
. ./utils.sh
logTemplateVersion
logPresetsVersion

# Suppress the cloud-provision bootstrap-permission preflight on the destroy
# path (luthersystems/reliable#2243). The preflight (setupCloudEnv →
# {aws,gcp}-preflight.sh) fires on EVERY mars invocation via run-with-creds.sh
# ($MARS) whenever the stage dir basename is "cloud-provision" — and tfDestroy
# runs `mars init` (and the convergence-gate `mars apply --help` / `mars apply
# --forbid-resource-changes`) before `mars destroy`. It checks the CREATE
# permissions the bootstrap APPLY needs (s3:CreateBucket, iam:CreateRole, …),
# which a teardown does NOT need. Left unsuppressed, a stack whose connecting
# credential was later locked down (or was under-privileged and left orphaned
# partial state — the very #2243 scenario) could no longer be destroyed: the
# preflight would fail closed and abort the teardown, blocking cleanup. The
# hook can't cheaply tell a destroy's `init` from an apply's `init` (they are
# identical mars calls), so we scope the skip here at the destroy entry point.
# These exports live only in this process and its mars children — apply.sh /
# plan.sh / drift-refresh.sh run as separate processes and keep the guard.
export SKIP_AWS_BOOTSTRAP_PREFLIGHT=1
export SKIP_GCP_BOOTSTRAP_PREFLIGHT=1

tfInit
if [[ "$ignore_drift" == "true" ]]; then
  tfDestroy --ignore-drift
else
  tfDestroy
fi
gitCommit
