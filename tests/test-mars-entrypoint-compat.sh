#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT/shell_utils.sh"

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

old_root="$WORKDIR/old"
new_root="$WORKDIR/new"
mkdir -p "$old_root" "$new_root"

touch "$old_root/run.sh"
chmod +x "$old_root/run.sh"

touch "$new_root/run.sh" "$new_root/mars"
chmod +x "$new_root/run.sh" "$new_root/mars"

export MARS_CONTAINER_ROOT="$old_root"
old_bin="$(resolveMarsBinary)"
if [[ "$old_bin" != "$old_root/run.sh" ]]; then
  echo "expected old Mars resolver to use run.sh, got $old_bin" >&2
  exit 1
fi

export MARS_CONTAINER_ROOT="$new_root"
new_bin="$(resolveMarsBinary)"
if [[ "$new_bin" != "$new_root/mars" ]]; then
  echo "expected new Mars resolver to use mars binary, got $new_bin" >&2
  exit 1
fi

mock_bin="$WORKDIR/bin"
mock_mars_root="$WORKDIR/mars-dev"
docker_log="$WORKDIR/docker.log"
mkdir -p "$mock_bin" "$mock_mars_root"
touch "$mock_mars_root/mars" "$mock_mars_root/mars-entrypoint"
chmod +x "$mock_mars_root/mars" "$mock_mars_root/mars-entrypoint"

# The mock logs only the mars run itself. The wrapper also calls docker to
# detect rootless Docker (docker info) and to give root-owned files back
# (docker run --entrypoint find); those would overwrite the log.
cat > "$mock_bin/docker" <<OUTER
#!/usr/bin/env bash
case " \$* " in
  *" info "*|*" --entrypoint find "*) exit 0 ;;
esac
printf '%s\n' "\$@" > "$docker_log"
OUTER
chmod +x "$mock_bin/docker"

# Run the wrapper as uid 1001 (a GitHub runner's uid), whatever uid runs
# the test: as root, the expected --user would be 0:0 either way and the
# test could not tell the caller's uid from the root fallback.
cat > "$mock_bin/id" <<'OUTER'
#!/usr/bin/env bash
case "$1" in
  -u | -g) echo 1001 ;;
  *) exec /usr/bin/id "$@" ;;
esac
OUTER
chmod +x "$mock_bin/id"

cat > "$mock_bin/greadlink" <<'OUTER'
#!/usr/bin/env bash
if [[ "$1" == "-f" ]]; then
  shift
fi
printf '%s\n' "$1"
OUTER
chmod +x "$mock_bin/greadlink"

cat > "$mock_bin/mars" <<OUTER
#!/usr/bin/env bash
exec "$ROOT/mars" "\$@"
OUTER
chmod +x "$mock_bin/mars"

(
  export PATH="$mock_bin:$PATH"
  export HOME="$WORKDIR/home"
  export MARS_DEV=true
  export MARS_DEV_BINARY="$mock_mars_root/mars"
  export MARS_DEV_ENTRYPOINT="$mock_mars_root/mars-entrypoint"
  export MARS_DEV_ROOT="$mock_mars_root"
  export MARS_DEBUG=false
  export MARS_SHELL=false
  export MARS_AZ=false
  bash "$ROOT/mars" version
)

if grep -q "$mock_mars_root/scripts:/opt/mars:ro" "$docker_log"; then
  echo "expected MARS_DEV mode not to mount removed scripts directory" >&2
  exit 1
fi

if ! grep -q "$mock_mars_root/mars:/opt/mars/mars:ro" "$docker_log"; then
  echo "expected MARS_DEV_BINARY to mount the Go Mars binary" >&2
  exit 1
fi

if ! grep -q "$mock_mars_root/mars-entrypoint:/opt/mars/mars-entrypoint:ro" "$docker_log"; then
  echo "expected MARS_DEV_ENTRYPOINT to mount the Go Mars entrypoint helper" >&2
  exit 1
fi

# expect_user <user> <what>: the logged docker run passes --user <user>
# and no USER_ID/GROUP_ID.
expect_user() {
  if ! grep -A1 -x -- "--user" "$docker_log" | grep -qx "$1"; then
    echo "expected the mars wrapper to pass --user $1 for $2" >&2
    exit 1
  fi
  if grep -qE '^(USER_ID|GROUP_ID)=' "$docker_log"; then
    echo "expected the mars wrapper not to pass USER_ID or GROUP_ID for $2" >&2
    exit 1
  fi
}

# Terraform and other commands run as the caller (#187): the pinned image
# (v0.147.0, luthersystems/mars#363) runs as any uid, so files mars writes
# to the checkout stay the caller's.
expect_user "1001:1001" "mars version"

# run_wrapper <args...>: run the wrapper with the mocks, outside MARS_DEV.
run_wrapper() {
  (
    export PATH="$mock_bin:$PATH"
    export HOME="$WORKDIR/home"
    export MARS_DEV=false
    export MARS_DEBUG=false
    export MARS_SHELL="${MARS_SHELL:-false}"
    bash "$ROOT/mars" "$@"
  )
}

run_wrapper default plan
expect_user "1001:1001" "mars plan"

# ansible commands stay root: mars's umbrella role chowns its chart directory
# to root, which a non-root uid cannot do (luthersystems/ui-infrastructure#611).
run_wrapper default ansible-playbook app.yaml
expect_user "0:0" "ansible-playbook"

# MARS_SHELL's bash entrypoint skips mars-entrypoint, which gives a non-root
# uid its passwd entry, so the shell stays root.
MARS_SHELL=true run_wrapper default
expect_user "0:0" "MARS_SHELL=true"

# An image older than v0.147.0 cannot run as another uid, so the wrapper
# falls back to root.
old_pin_root="$WORKDIR/old-pin"
mkdir -p "$old_pin_root"
# A git checkout, as a real infra repo is: the wrapper reads .mars-version
# from the git root.
git -C "$old_pin_root" init -q
echo v0.146.0 > "$old_pin_root/.mars-version"
(cd "$old_pin_root" && run_wrapper default plan)
expect_user "0:0" "a mars image older than v0.147.0"
