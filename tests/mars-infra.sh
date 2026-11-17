# shellcheck shell=bash
# Sourced by the tests that run the template's scripts through the mars
# infra-* commands (shell_utils.sh marsInfra; luthersystems/mars
# docs/infra-repo.md).

# requireMarsInfra exports MARS_BIN, or stops the test: the scripts' git
# steps are mars commands, so without a mars that has them these tests
# would check nothing. CI installs mars at .mars-version; a release older
# than the infra-* commands fails here on purpose (the template would fail
# the same way in production).
requireMarsInfra() {
  if [[ -z "${MARS_BIN:-}" ]]; then
    echo "FAIL: set MARS_BIN to a mars build with the infra-* commands (luthersystems/mars#368)," >&2
    echo "      e.g. go build -o /tmp/mars ./cmd/mars in a mars checkout." >&2
    exit 1
  fi
  if ! "$MARS_BIN" default infra-commit --help >/dev/null 2>&1; then
    echo "FAIL: $MARS_BIN has no infra-* commands; it needs luthersystems/mars#368 or a release with it." >&2
    exit 1
  fi
  export MARS_BIN
}
