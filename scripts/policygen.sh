#!/usr/bin/env bash
set -euo pipefail

# Writes or checks the generated deploy policies in tf/account-setup/policies
# (#147, #194). The generator is cmd/policygen of
# luthersystems/insideout-terraform-presets at PRESETS_REF; the policy follows
# what that presets version can create.
#
#   scripts/policygen.sh          write the files
#   scripts/policygen.sh -check   fail if the committed files differ (CI)
#
# Bump PRESETS_REF with the presets version reliable composes with, and run
# this script to update the files in the same PR.

# TODO(#194): pin a release tag once luthersystems/insideout-terraform-presets#946 is released.
PRESETS_REF="5f02d08"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/tf/account-setup/policies"

check=()
case "${1:-}" in
  "") ;;
  -check) check=(-check) ;;
  *) echo "usage: $0 [-check]" >&2; exit 2 ;;
esac

# go run of a module path works from any directory; run it outside the repo
# so no go.mod here is needed.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"
go run "github.com/luthersystems/insideout-terraform-presets/cmd/policygen@${PRESETS_REF}" \
  "${check[@]}" -out "$DIR" -extra-services "$DIR/extra-services.txt"
