#!/bin/sh
set -euo pipefail

# usage: license-gen.sh [-f|--force]

force=0
while [ "$#" -gt 0 ]; do
  case "$1" in
  -f | --force)
    force=1
    ;;
  *)
    echo "Usage: $0 [-f|--force]" >&2
    exit 1
    ;;
  esac
  shift
done

# encapsulate generation logic
generate_license() {
  # Determine script directory and project root
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  : "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"
  # Source helpers from project root
  . "$MARS_PROJECT_ROOT/shell_utils.sh"

  # Load vars from Ansible env
  project_id=$(mustGetAnsibleField project_id)
  expiration_days=$(mustGetAnsibleField license_expiration_days)
  expiration_blocks=$(mustGetAnsibleField license_expiration_blocks)

  # Path to output license
  ANSIBLE_LICENSE_ARTIFACTS="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/license.yaml"

  # Generate and encode license
  LICENSE_B64=$(
    /ko-app/license generate \
      -l "$expiration_days" \
      -b "$expiration_blocks" \
      -s "$project_id" | base64 | tr -d '\n'
  )

  # Write out
  echo "substrate_license: $LICENSE_B64" >"$ANSIBLE_LICENSE_ARTIFACTS"
  echo "" >>"$ANSIBLE_LICENSE_ARTIFACTS"
  echo "license-gen: generated license file [project_id=$project_id expiration_days=$expiration_days block_limit=$expiration_blocks overwrite=$force]"
}

# Determine license file path
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARS_PROJECT_ROOT="${MARS_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ANSIBLE_LICENSE_ARTIFACTS="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/license.yaml"

# Skip if already exists and non-empty, unless forced
if [ -f "$ANSIBLE_LICENSE_ARTIFACTS" ] && [ -s "$ANSIBLE_LICENSE_ARTIFACTS" ] && [ "$force" -eq 0 ]; then
  echo "license-gen: license.yaml already exists and is non-empty; skipping generation"
  exit 0
fi

# Otherwise, generate or overwrite
generate_license
