#!/usr/bin/env bash
set -euo pipefail

# Upgrade L1 SystemConfig proxy to an existing implementation.
#
# Usage:
#   bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>
#
# Environment variables:
#   UPGRADE_PRIVATE_KEY       defaults to $GS_ADMIN_PRIVATE_KEY

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

NEW_SYSTEM_CONFIG="${1:-}"
UPGRADE_PRIVATE_KEY="${UPGRADE_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
UPGRADE_SIGNER=$(cast wallet address --private-key "$UPGRADE_PRIVATE_KEY")

if [ -z "$NEW_SYSTEM_CONFIG" ]; then
  echo "Usage: bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>"
  echo ""
  echo "Deploy implementation first:"
  echo "  bash scripts/jovian/deploy-systemconfig.sh"
  exit 1
fi

ARTIFACT_FILE="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}/artifact.json"
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "ERROR: artifact.json not found: $ARTIFACT_FILE"
  echo "Run chain setup first: bash scripts/deploy-chain/chain-setup.sh local"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT_FILE")
PROXY_ADMIN=$(jq -r '.ProxyAdmin' "$ARTIFACT_FILE")
SYSTEM_OWNER_SAFE=$(jq -r '.SystemOwnerSafe' "$ARTIFACT_FILE")

for value in "$SYSTEM_CONFIG_PROXY" "$PROXY_ADMIN" "$SYSTEM_OWNER_SAFE"; do
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "ERROR: missing required address in $ARTIFACT_FILE"
    jq '{SystemConfigProxy, ProxyAdmin, SystemOwnerSafe}' "$ARTIFACT_FILE"
    exit 1
  fi
done

send_safe_tx() {
  local to="$1"
  local data="$2"

  local owners_raw safe_owner owner_no_prefix signature
  owners_raw=$(curl -s -X POST "$L1_RPC_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_OWNER_SAFE\",\"data\":\"0xa0e67e2b\"},\"latest\"],\"id\":1}" \
    | jq -r '.result')

  if [ -z "$owners_raw" ] || [ "$owners_raw" = "null" ] || [ "$owners_raw" = "0x" ]; then
    echo "ERROR: failed to read SystemOwnerSafe owners"
    exit 1
  fi

  # Local deployments use a 1-of-1 Safe. ABI result layout:
  # offset(32) + length(32) + owner(32), so the last 20 bytes are the owner.
  safe_owner="0x${owners_raw: -40}"
  if [ "$(echo "$safe_owner" | tr '[:upper:]' '[:lower:]')" != "$(echo "$UPGRADE_SIGNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: upgrade signer is not the 1-of-1 SystemOwnerSafe owner"
    echo "  signer:    $UPGRADE_SIGNER"
    echo "  safeOwner: $safe_owner"
    exit 1
  fi

  owner_no_prefix=$(echo "$safe_owner" | sed 's/^0x//')
  signature="0x000000000000000000000000${owner_no_prefix}000000000000000000000000000000000000000000000000000000000000000001"

  cast send "$SYSTEM_OWNER_SAFE" \
    "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
    "$to" \
    0 \
    "$data" \
    0 \
    0 \
    0 \
    0 \
    "0x0000000000000000000000000000000000000000" \
    "0x0000000000000000000000000000000000000000" \
    "$signature" \
    --private-key "$UPGRADE_PRIVATE_KEY" \
    --rpc-url "$L1_RPC_URL"
}

send_owned_tx() {
  local owner="$1"
  local to="$2"
  local signature="$3"
  shift 3

  local owner_lc signer_lc safe_lc
  owner_lc=$(echo "$owner" | tr '[:upper:]' '[:lower:]')
  signer_lc=$(echo "$UPGRADE_SIGNER" | tr '[:upper:]' '[:lower:]')
  safe_lc=$(echo "$SYSTEM_OWNER_SAFE" | tr '[:upper:]' '[:lower:]')

  if [ "$owner_lc" = "$signer_lc" ]; then
    cast send "$to" "$signature" "$@" \
      --private-key "$UPGRADE_PRIVATE_KEY" \
      --rpc-url "$L1_RPC_URL"
  elif [ "$owner_lc" = "$safe_lc" ]; then
    local calldata
    calldata=$(cast calldata "$signature" "$@")
    send_safe_tx "$to" "$calldata"
  else
    echo "ERROR: unsupported owner for transaction"
    echo "  owner:  $owner"
    echo "  signer: $UPGRADE_SIGNER"
    echo "  safe:   $SYSTEM_OWNER_SAFE"
    exit 1
  fi
}

echo "============================================"
echo "  Jovian SystemConfig Upgrade"
echo "============================================"
echo "L1 RPC:              $L1_RPC_URL"
echo "artifact:            $ARTIFACT_FILE"
echo "SystemConfigProxy:   $SYSTEM_CONFIG_PROXY"
echo "ProxyAdmin:          $PROXY_ADMIN"
echo "SystemOwnerSafe:     $SYSTEM_OWNER_SAFE"
echo "new implementation:  $NEW_SYSTEM_CONFIG"
echo "upgrade signer:      $UPGRADE_SIGNER"
echo ""

echo "== current SystemConfig proxy =="
CURRENT_VERSION=$(cast call "$SYSTEM_CONFIG_PROXY" "version()(string)" --rpc-url "$L1_RPC_URL")
SYSTEM_CONFIG_OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC_URL")
PROXY_ADMIN_OWNER=$(cast call "$PROXY_ADMIN" "owner()(address)" --rpc-url "$L1_RPC_URL")
echo "version:          $CURRENT_VERSION"
echo "SystemConfigOwner: $SYSTEM_CONFIG_OWNER"
echo "ProxyAdminOwner:   $PROXY_ADMIN_OWNER"
echo ""

NEW_IMPL_CODE=$(cast code "$NEW_SYSTEM_CONFIG" --rpc-url "$L1_RPC_URL")
if [ "$NEW_IMPL_CODE" = "0x" ]; then
  echo "ERROR: new implementation has no code on L1: $NEW_SYSTEM_CONFIG"
  exit 1
fi

NEW_IMPL_VERSION=$(cast call "$NEW_SYSTEM_CONFIG" "version()(string)" --rpc-url "$L1_RPC_URL")
echo "new impl version:   $NEW_IMPL_VERSION"
echo ""

echo "== upgrading proxy implementation =="
send_owned_tx "$PROXY_ADMIN_OWNER" "$PROXY_ADMIN" "upgrade(address,address)" "$SYSTEM_CONFIG_PROXY" "$NEW_SYSTEM_CONFIG"

UPGRADED_VERSION=$(cast call "$SYSTEM_CONFIG_PROXY" "version()(string)" --rpc-url "$L1_RPC_URL")
echo "proxy version after upgrade: $UPGRADED_VERSION"
echo ""

cd "$BASE_PATH"

echo ""
echo "============================================"
echo "  Done"
echo "============================================"
echo "Artifact files were not modified."
echo "To set operator fee params separately, run:"
echo "  bash scripts/jovian/set-operator-fee.sh"
