#!/bin/bash
set -euo pipefail

ANSIBLE_PLAYBOOK_OPTS=${ANSIBLE_PLAYBOOK_OPTS:-""}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

. "$MARS_PROJECT_ROOT/shell_utils.sh"

MARS="$(resolveMarsBinary)"

PLAYBOOK=$1

export ANSIBLE_JINJA2_NATIVE=yes
export ANSIBLE_FORCE_COLOR=yes
export ANSIBLE_LOAD_CALLBACK_PLUGINS=yes
export ANSIBLE_STDOUT_CALLBACK=yaml
export ANSIBLE_TRANSPORT=local

export ANSIBLE_ENV=default

$MARS $ANSIBLE_ENV ansible-playbook $ANSIBLE_PLAYBOOK_OPTS $PLAYBOOK
