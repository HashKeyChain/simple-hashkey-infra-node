#!/usr/bin/env bash
set -euo pipefail

# Set L1 SystemConfig DA footprint gas scalar for local Jovian testing.
#
# Usage:
#   bash scripts/jovian/set-da-footprint-gas-scalar.sh [scalar]
#
# Defaults:
#   scalar = ${DA_FOOTPRINT_GAS_SCALAR:-400}
#
# Environment variables:
#   DA_FOOTPRINT_PRIVATE_KEY defaults to $GS_ADMIN_PRIVATE_KEY

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc
[ -f scripts/jovian/upgrade.env ] && source scripts/jovian/upgrade.env

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
DA_FOOTPRINT_GAS_SCALAR="${1:-${DA_FOOTPRINT_GAS_SCALAR:-400}}"
DA_FOOTPRINT_PRIVATE_KEY="${DA_FOOTPRINT_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
DA_FOOTPRINT_SIGNER=$(cast wallet address --private-key "$DA_FOOTPRINT_PRIVATE_KEY")
UINT16_MAX="65535"

if ! [[ "$DA_FOOTPRINT_GAS_SCALAR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: daFootprintGasScalar must be a uint16 decimal value: $DA_FOOTPRINT_GAS_SCALAR"
  exit 1
fi

if [ "$(echo "$DA_FOOTPRINT_GAS_SCALAR <= $UINT16_MAX" | bc)" != "1" ]; then
  echo "ERROR: daFootprintGasScalar exceeds uint16 max: $DA_FOOTPRINT_GAS_SCALAR"
  exit 1
fi

ARTIFACT_FILE="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}/artifact.json"
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "ERROR: artifact.json not found: $ARTIFACT_FILE"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT_FILE")
SYSTEM_OWNER_SAFE=$(jq -r '.SystemOwnerSafe' "$ARTIFACT_FILE")
L1_BLOCK_PREDEPLOY="0x4200000000000000000000000000000000000015"

if [ -z "$SYSTEM_CONFIG_PROXY" ] || [ "$SYSTEM_CONFIG_PROXY" = "null" ]; then
  echo "ERROR: SystemConfigProxy missing in $ARTIFACT_FILE"
  exit 1
fi

if [ -z "$SYSTEM_OWNER_SAFE" ] || [ "$SYSTEM_OWNER_SAFE" = "null" ]; then
  echo "ERROR: SystemOwnerSafe missing in $ARTIFACT_FILE"
  exit 1
fi

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

  safe_owner="0x${owners_raw: -40}"
  if [ "$(echo "$safe_owner" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DA_FOOTPRINT_SIGNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: DA footprint signer is not the 1-of-1 SystemOwnerSafe owner"
    echo "  signer:    $DA_FOOTPRINT_SIGNER"
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
    --private-key "$DA_FOOTPRINT_PRIVATE_KEY" \
    --rpc-url "$L1_RPC_URL"
}

send_owned_tx() {
  local owner="$1"
  local to="$2"
  local signature="$3"
  shift 3

  local owner_lc signer_lc safe_lc
  owner_lc=$(echo "$owner" | tr '[:upper:]' '[:lower:]')
  signer_lc=$(echo "$DA_FOOTPRINT_SIGNER" | tr '[:upper:]' '[:lower:]')
  safe_lc=$(echo "$SYSTEM_OWNER_SAFE" | tr '[:upper:]' '[:lower:]')

  if [ "$owner_lc" = "$signer_lc" ]; then
    cast send "$to" "$signature" "$@" \
      --private-key "$DA_FOOTPRINT_PRIVATE_KEY" \
      --rpc-url "$L1_RPC_URL"
  elif [ "$owner_lc" = "$safe_lc" ]; then
    local calldata
    calldata=$(cast calldata "$signature" "$@")
    send_safe_tx "$to" "$calldata"
  else
    echo "ERROR: unsupported SystemConfig owner"
    echo "  owner:  $owner"
    echo "  signer: $DA_FOOTPRINT_SIGNER"
    echo "  safe:   $SYSTEM_OWNER_SAFE"
    exit 1
  fi
}

echo "============================================"
echo "  Jovian DA Footprint Gas Scalar"
echo "============================================"
echo "L1 RPC:                 $L1_RPC_URL"
echo "L2 RPC:                 $L2_RPC"
echo "SystemConfigProxy:      $SYSTEM_CONFIG_PROXY"
echo "SystemOwnerSafe:        $SYSTEM_OWNER_SAFE"
echo "L2 L1Block:             $L1_BLOCK_PREDEPLOY"
echo "signer:                 $DA_FOOTPRINT_SIGNER"
echo "daFootprintGasScalar:   $DA_FOOTPRINT_GAS_SCALAR"
echo ""

SYSTEM_CONFIG_OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC_URL")
echo "SystemConfig owner:     $SYSTEM_CONFIG_OWNER"
echo ""

echo "== current DA footprint params =="
echo -n "L1 SystemConfig.daFootprintGasScalar: "
cast call "$SYSTEM_CONFIG_PROXY" "daFootprintGasScalar()(uint16)" --rpc-url "$L1_RPC_URL"
echo -n "L2 L1Block.daFootprintGasScalar:      "
cast call "$L1_BLOCK_PREDEPLOY" "daFootprintGasScalar()(uint16)" --rpc-url "$L2_RPC" || true
echo ""

if [ "$DA_FOOTPRINT_GAS_SCALAR" = "0" ]; then
  echo "NOTE: setting L1 value to 0 maps to the op-node default value 400 on L2 derivation."
  echo ""
fi

echo "== setting DA footprint gas scalar on L1 SystemConfig =="
send_owned_tx "$SYSTEM_CONFIG_OWNER" "$SYSTEM_CONFIG_PROXY" \
  "setDAFootprintGasScalar(uint16)" \
  "$DA_FOOTPRINT_GAS_SCALAR"

echo "== verifying DA footprint gas scalar on L1 SystemConfig =="
cast call "$SYSTEM_CONFIG_PROXY" "daFootprintGasScalar()(uint16)" --rpc-url "$L1_RPC_URL"

echo ""
echo "Wait for op-node to derive the L1 transaction block, then check L2:"
echo "  bash scripts/jovian/query-systemconfig-params.sh"
echo "  bash scripts/jovian/verify-jovian-fees.sh"
