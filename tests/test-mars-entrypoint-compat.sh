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

cat > "$mock_bin/docker" <<OUTER
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$docker_log"
OUTER
chmod +x "$mock_bin/docker"

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
