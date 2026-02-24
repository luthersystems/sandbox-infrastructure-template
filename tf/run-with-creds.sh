#!/usr/bin/env bash

# Credential wrapper for the Mars CLI runner.
# Sets up cloud-specific credentials (GCP real or dummy, AWS jump role)
# then hands off to the real Mars runner.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shell_utils.sh"

if ! setupCloudEnv; then
  echo "Failed to setup cloud environment" >&2
  exit 1
fi
trap 'cleanupCloudEnv' EXIT

# Hand off to the real Mars runner.
# exec replaces this process, so the trap won't fire — the Mars container
# handles its own cleanup on exit (same as prior behavior).
exec /opt/mars/run.sh "$@"
