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
calls_log="$WORKDIR/docker-calls.log"
mkdir -p "$mock_bin" "$mock_mars_root"
touch "$mock_mars_root/mars" "$mock_mars_root/mars-entrypoint"
chmod +x "$mock_mars_root/mars" "$mock_mars_root/mars-entrypoint"

# The mock docker appends every call, one per line, to calls_log, so tests
# can check the daemon probes (docker --version, docker info) and the
# reclaim containers (docker run --entrypoint find). The mars run itself
# also goes to docker_log, one argument per line. MOCK_DOCKER_VERSION and
# MOCK_DOCKER_SECURITY_OPTS fake what the daemon reports.
cat > "$mock_bin/docker" <<OUTER
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$calls_log"
case " \$* " in
  " --version ") echo "\${MOCK_DOCKER_VERSION:-Docker version 28.0.0, build test}"; exit 0 ;;
  *" info "*) echo "\${MOCK_DOCKER_SECURITY_OPTS:-[name=seccomp,profile=builtin]}"; exit 0 ;;
  *" --entrypoint find "*) exit 0 ;;
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

# The wrapper looks for root-owned files with find -user 0. Which files root
# owns depends on who runs the test, so the mock answers that probe from a
# marker instead: a directory holding .root-owned has a root-owned file.
# Every other find runs the real one.
cat > "$mock_bin/find" <<'OUTER'
#!/usr/bin/env bash
if [[ "$2 $3" == "-user 0" ]]; then
  if [[ -e "$1/.root-owned" ]]; then
    echo "$1/.root-owned"
  fi
  exit 0
fi
exec /usr/bin/find "$@"
OUTER
chmod +x "$mock_bin/find"

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

# make_checkout <dir> [<mars version>]: a fixture git checkout, as a real
# infra repo is (the wrapper reads .mars-version from the git root). The
# wrapper only ever runs in these, never in this repo, so the reclaim scan
# never touches the real checkout. No version: no .mars-version file.
make_checkout() {
  mkdir -p "$1"
  git -C "$1" init -q
  if [[ -n "${2:-}" ]]; then
    echo "$2" > "$1/.mars-version"
  fi
}

checkout="$WORKDIR/checkout"
make_checkout "$checkout" "$(cat "$ROOT/.mars-version")"

(
  cd "$checkout"
  export PATH="$mock_bin:$PATH"
  export HOME="$WORKDIR/home"
  export MARS_DEV=true
  export MARS_DEV_BINARY="$mock_mars_root/mars"
  export MARS_DEV_ENTRYPOINT="$mock_mars_root/mars-entrypoint"
  export MARS_DEV_ROOT="$mock_mars_root"
  export MARS_DEBUG=false
  export MARS_SHELL=false
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

# run_wrapper <dir> <args...>: run the wrapper in checkout <dir> with the
# mocks, outside MARS_DEV, with fresh call logs.
run_wrapper() {
  local dir="$1"
  shift
  : > "$calls_log"
  : > "$docker_log"
  (
    cd "$dir"
    export PATH="$mock_bin:$PATH"
    export HOME="$WORKDIR/home"
    export MARS_DEV=false
    export MARS_DEBUG=false
    export MARS_SHELL="${MARS_SHELL:-false}"
    bash "$ROOT/mars" "$@"
  )
}

run_wrapper "$checkout" default plan
expect_user "1001:1001" "mars plan"
if ! grep -qx -- "info --format {{.SecurityOptions}}" "$calls_log"; then
  echo "expected a run as the caller to check the daemon for rootless or userns-remap" >&2
  exit 1
fi

# ansible commands stay root: mars's umbrella role chowns its chart directory
# to root, which a non-root uid cannot do (luthersystems/ui-infrastructure#611,
# luthersystems/mars#367). Root is known without the daemon, so no probe.
run_wrapper "$checkout" default ansible-playbook app.yaml
expect_user "0:0" "ansible-playbook"
if grep -qE '^(info|--version)' "$calls_log"; then
  echo "expected an ansible run to make no daemon probe, got:" >&2
  cat "$calls_log" >&2
  exit 1
fi

# MARS_SHELL's bash entrypoint skips mars-entrypoint, which gives a non-root
# uid its passwd entry, so the shell stays root.
MARS_SHELL=true run_wrapper "$checkout" default
expect_user "0:0" "MARS_SHELL=true"
if grep -qE '^(info|--version)' "$calls_log"; then
  echo "expected a MARS_SHELL run to make no daemon probe" >&2
  exit 1
fi

# Rootless Docker, userns-remap and podman's docker shim map container root
# to the caller or a subordinate uid, so the wrapper stays root.
MOCK_DOCKER_SECURITY_OPTS="[name=seccomp,profile=builtin name=rootless]" \
  run_wrapper "$checkout" default plan
expect_user "0:0" "rootless Docker"
MOCK_DOCKER_SECURITY_OPTS="[name=seccomp,profile=builtin name=userns]" \
  run_wrapper "$checkout" default plan
expect_user "0:0" "userns-remap"
MOCK_DOCKER_VERSION="podman version 5.2.0" run_wrapper "$checkout" default plan
expect_user "0:0" "podman's docker shim"

# A pin that is not a release at or after v0.147.0 runs as root: an older
# image cannot run as another uid, and latest (no .mars-version) or another
# tag can be a cached image older than v0.147.0.
for pin in v0.146.0 latest main-abc123 ""; do
  pin_root="$WORKDIR/pin-${pin:-none}"
  make_checkout "$pin_root" "$pin"
  run_wrapper "$pin_root" default plan
  expect_user "0:0" "mars version pin '${pin:-none}'"
done

# Reclaim: a run as the caller gives root-owned files that an earlier root
# run left back to the caller, from a root container, for the checkout and
# the Terraform caches only. The ansible caches stay as they are: ansible
# still runs as root, and a chown container on every Terraform run after an
# ansible run would be wasted.
reclaim_root="$WORKDIR/reclaim-checkout"
make_checkout "$reclaim_root" "$(cat "$ROOT/.mars-version")"
touch "$reclaim_root/.root-owned"
mkdir -p "$WORKDIR/home/.mars/tf-plugin-cache" "$WORKDIR/home/.mars/helmcharts" \
  "$WORKDIR/home/.mars/hyperledger"
touch "$WORKDIR/home/.mars/tf-plugin-cache/.root-owned" \
  "$WORKDIR/home/.mars/helmcharts/.root-owned" \
  "$WORKDIR/home/.mars/hyperledger/.root-owned"
run_wrapper "$reclaim_root" default plan 2>/dev/null
expect_user "1001:1001" "mars plan with root-owned files"
image="luthersystems/mars:$(cat "$ROOT/.mars-version")"
for dir in "$reclaim_root" "$WORKDIR/home/.mars/tf-plugin-cache"; do
  want="run --rm --user 0:0 --entrypoint find --mount type=bind,src=$dir,dst=/reclaim $image /reclaim -user 0 -exec chown -h 1001:1001 {} +"
  if ! grep -qxF -- "$want" "$calls_log"; then
    echo "expected the reclaim call: $want" >&2
    echo "calls:" >&2
    cat "$calls_log" >&2
    exit 1
  fi
done
for dir in helmcharts hyperledger; do
  if grep -qF -- "src=$WORKDIR/home/.mars/$dir," "$calls_log"; then
    echo "expected no reclaim of the ansible cache ~/.mars/$dir" >&2
    exit 1
  fi
done
rm -f "$WORKDIR/home/.mars/tf-plugin-cache/.root-owned"

# A root run reclaims nothing: there is nothing to give back to.
run_wrapper "$reclaim_root" default ansible-playbook app.yaml
if grep -q -- "--entrypoint find" "$calls_log"; then
  echo "expected a root run not to start a reclaim container" >&2
  exit 1
fi
