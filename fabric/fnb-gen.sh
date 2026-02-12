#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${MARS_PROJECT_ROOT:=$(cd "$SCRIPT_DIR/.." && pwd)}"

# Source helpers
. "$MARS_PROJECT_ROOT/shell_utils.sh"

ANSIBLE_FABRIC_ARTIFACTS="$MARS_PROJECT_ROOT/ansible/inventories/default/group_vars/all/fabric.yaml"

log() { echo "[fnb-gen] $*" >&2; }

# Parse args
FORCE_REGEN=0
while [ $# -gt 0 ]; do
  case "$1" in
  --force | -f)
    FORCE_REGEN=1
    ;;
  *)
    log "Unknown argument: $1"
    exit 2
    ;;
  esac
  shift
done

log "Extracting variables from ansible env..."

NUM_ORGS=$(mustGetAnsibleField num_orgs)
NUM_PEERS=$(mustGetAnsibleField num_peers)
NUM_ORDERERS=$(mustGetAnsibleField num_orderers)
DOMAIN=$(mustGetAnsibleField k8s_fabric_network_domain_root)

log "Generating artifacts for domain=$DOMAIN orgs=$NUM_ORGS peers=$NUM_PEERS orderers=$NUM_ORDERERS"

if [ -d "crypto-config" ] && [ "$FORCE_REGEN" -ne 1 ]; then
  log "Artifacts already exist. Use --force to regenerate. Exiting."
  exit 0
elif [ -d "crypto-config" ] && [ "$FORCE_REGEN" -eq 1 ]; then
  log "Removing existing crypto-config for regeneration (--force)..."
  rm -rf crypto-config channel-artifacts collections.json
fi

log "Running fabric-network-builder..."
fabric-network-builder --force generate \
  --domain-name "$DOMAIN" \
  --peer-count "$NUM_PEERS" \
  --org-count "$NUM_ORGS" \
  --orderer-count "$NUM_ORDERERS"

log "Base64 encoding channel-artifacts..."
FABRIC_ARTIFACTS_ZIP_B64=$(zip -r - channel-artifacts | base64 | tr -d '\n')
echo "k8s_fabric_channel_artifacts: $FABRIC_ARTIFACTS_ZIP_B64" >"$ANSIBLE_FABRIC_ARTIFACTS"
echo "" >>"$ANSIBLE_FABRIC_ARTIFACTS"

log "Base64 encoding collections.json..."
COLLECTIONS_JSON_B64=$(base64 collections.json | tr -d '\n')
echo "k8s_fabric_collections: $COLLECTIONS_JSON_B64" >>"$ANSIBLE_FABRIC_ARTIFACTS"
echo "" >>"$ANSIBLE_FABRIC_ARTIFACTS"

log "Base64 encoding crypto-config..."
FABRIC_CRYPTO_ZIP_B64=$(zip -r - crypto-config | base64 | tr -d '\n')
echo "k8s_fabric_crypto_config: $FABRIC_CRYPTO_ZIP_B64" >>"$ANSIBLE_FABRIC_ARTIFACTS"
echo "" >>"$ANSIBLE_FABRIC_ARTIFACTS"

log "fnb-gen: generated fabric artifacts [done]"

gitCommit "fabric: auto-commit fabric artifacts [ci skip]"
