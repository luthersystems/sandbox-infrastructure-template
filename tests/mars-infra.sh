# shellcheck shell=bash
# Sourced by the tests that run the template's scripts through the mars
# infra-* commands (shell_utils.sh marsInfra; luthersystems/mars
# docs/infra-repo.md).

# hasMarsInfra succeeds when MARS_BIN names a mars with the infra-*
# commands, and exports it; else it says why on stderr and fails. CI
# installs mars at .mars-version; a release older than the infra-* commands
# fails on purpose (the template would fail the same way in production).
hasMarsInfra() {
  if [[ -z "${MARS_BIN:-}" ]]; then
    echo "FAIL: set MARS_BIN to a mars build with the infra-* commands (luthersystems/mars#368)," >&2
    echo "      e.g. go build -o /tmp/mars ./cmd/mars in a mars checkout." >&2
    return 1
  fi
  if ! "$MARS_BIN" default infra-commit --help >/dev/null 2>&1; then
    echo "FAIL: $MARS_BIN has no infra-* commands; it needs luthersystems/mars#368 or a release with it." >&2
    return 1
  fi
  export MARS_BIN
}

# requireMarsInfra stops the test without such a mars: every check of the
# caller runs a script's git steps, so it would check nothing.
requireMarsInfra() {
  hasMarsInfra || exit 1
}

# requireMarsStages stops the test unless MARS_BIN names a mars with the
# stage commands the template's scripts call (plan-all --plan-file is the
# newest flag they use; tf/stages.sh, #114), and exports it.
requireMarsStages() {
  if [[ -z "${MARS_BIN:-}" ]]; then
    echo "FAIL: set MARS_BIN to a mars build with the stage commands (plan-all --plan-file)," >&2
    echo "      e.g. go build -o /tmp/mars ./cmd/mars in a mars checkout." >&2
    exit 1
  fi
  local help
  help="$("$MARS_BIN" default plan-all --help 2>&1 || true)"
  if [[ "$help" != *--plan-file* ]]; then
    echo "FAIL: $MARS_BIN has no plan-all --plan-file; it needs a mars release with it (#114)." >&2
    exit 1
  fi
  export MARS_BIN
}
