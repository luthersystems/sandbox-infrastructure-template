#!/bin/bash
set -euxo pipefail
echo "Arg 0: $0"
echo "Arg 1: $1"
export PLAYBOOK=$1
echo "Arg 2: $2"
export ENV=$2
echo "Arg 3: $3"
export CHECK_MODE=$3
echo "Arg 4: $4"
export VERBOSITY=$4
echo "whoami: $(whoami)"
echo "pwd: $(pwd)"
echo "date: $(date)"
echo "docker version"
docker --version

ARGS=()
if [ "$CHECK_MODE" == "True" ]; then
  ARGS+=('--check')
fi

if [ "$VERBOSITY" -gt '0' ]; then
  ARG='-'
  for ((i = 0; i < VERBOSITY; i++)); do
    ARG+='v'
  done
  ARGS+=("$ARG")
fi

cd ansible

source "vars/${ENV}/vault-ref"

bash ../mars "$ENV" ansible-playbook \
  "--aws-sm-secret-id=${AWS_SM_SECRET_ID}" \
  "--aws-region=${AWS_REGION}" \
  "--aws-role-arn=${AWS_ROLE_ARN}" \
  "${ARGS[@]}" \
  "$PLAYBOOK"
