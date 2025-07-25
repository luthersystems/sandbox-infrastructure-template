#!/bin/sh
set -euo pipefail

# Use MARS_PROJECT_ROOT if set, otherwise fallback to $PWD
: "${MARS_PROJECT_ROOT:=$PWD}"

ANSIBLE_ENV_FILE="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/env.yaml"

echo_error() {
  echo "$1" >&2
}

getAnsibleField() {
  key=$1
  if [ ! -f "$ANSIBLE_ENV_FILE" ]; then
    echo_error "ERROR: cannot find $ANSIBLE_ENV_FILE"
    exit 1
  fi
  grep -E "^[[:space:]]*$key:" "$ANSIBLE_ENV_FILE" | head -n1 | sed 's/^[[:space:]]*'"$key"':[[:space:]]*//'
}

# mustGetAnsibleField KEY
#   like getAnsibleField but fails if empty, with error log
mustGetAnsibleField() {
  key=$1
  val=$(getAnsibleField "$key")
  if [ -z "$val" ]; then
    echo_error "ERROR: required ansible field '$key' is missing or empty in $ANSIBLE_ENV_FILE"
    exit 1
  fi
  echo "$val"
}
