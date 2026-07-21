#!/usr/bin/env bash
set -euo pipefail

# Set L1 SystemConfig operator fee params for local Jovian testing.
#
# Usage:
#   bash scripts/jovian/set-operator-fee.sh [scalar] [constant]
#
# Defaults:
#   scalar   = ${OPERATOR_FEE_SCALAR:-1}
#   constant = ${OPERATOR_FEE_CONSTANT:-1000000}
#
# Environment variables:
#   OPERATOR_FEE_PRIVATE_KEY defaults to $GS_ADMIN_PRIVATE_KEY

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

OPERATOR_FEE_SCALAR="${1:-${OPERATOR_FEE_SCALAR:-1}}"
OPERATOR_FEE_CONSTANT="${2:-${OPERATOR_FEE_CONSTANT:-1000000}}"
OPERATOR_FEE_PRIVATE_KEY="${OPERATOR_FEE_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
OPERATOR_FEE_SIGNER=$(cast wallet address --private-key "$OPERATOR_FEE_PRIVATE_KEY")

ARTIFACT_FILE="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}/artifact.json"
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "ERROR: artifact.json not found: $ARTIFACT_FILE"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT_FILE")
SYSTEM_OWNER_SAFE=$(jq -r '.SystemOwnerSafe' "$ARTIFACT_FILE")

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
  if [ "$(echo "$safe_owner" | tr '[:upper:]' '[:lower:]')" != "$(echo "$OPERATOR_FEE_SIGNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: operator fee signer is not the 1-of-1 SystemOwnerSafe owner"
    echo "  signer:    $OPERATOR_FEE_SIGNER"
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
    --private-key "$OPERATOR_FEE_PRIVATE_KEY" \
    --rpc-url "$L1_RPC_URL"
}

send_owned_tx() {
  local owner="$1"
  local to="$2"
  local signature="$3"
  shift 3

  local owner_lc signer_lc safe_lc
  owner_lc=$(echo "$owner" | tr '[:upper:]' '[:lower:]')
  signer_lc=$(echo "$OPERATOR_FEE_SIGNER" | tr '[:upper:]' '[:lower:]')
  safe_lc=$(echo "$SYSTEM_OWNER_SAFE" | tr '[:upper:]' '[:lower:]')

  if [ "$owner_lc" = "$signer_lc" ]; then
    cast send "$to" "$signature" "$@" \
      --private-key "$OPERATOR_FEE_PRIVATE_KEY" \
      --rpc-url "$L1_RPC_URL"
  elif [ "$owner_lc" = "$safe_lc" ]; then
    local calldata
    calldata=$(cast calldata "$signature" "$@")
    send_safe_tx "$to" "$calldata"
  else
    echo "ERROR: unsupported SystemConfig owner"
    echo "  owner:  $owner"
    echo "  signer: $OPERATOR_FEE_SIGNER"
    echo "  safe:   $SYSTEM_OWNER_SAFE"
    exit 1
  fi
}

echo "============================================"
echo "  Jovian Operator Fee Params"
echo "============================================"
echo "L1 RPC:              $L1_RPC_URL"
echo "SystemConfigProxy:   $SYSTEM_CONFIG_PROXY"
echo "SystemOwnerSafe:     $SYSTEM_OWNER_SAFE"
echo "signer:              $OPERATOR_FEE_SIGNER"
echo "operatorFeeScalar:   $OPERATOR_FEE_SCALAR"
echo "operatorFeeConstant: $OPERATOR_FEE_CONSTANT"
echo ""

SYSTEM_CONFIG_OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC_URL")
echo "SystemConfig owner:  $SYSTEM_CONFIG_OWNER"
echo ""

echo "== setting operator fee params on L1 SystemConfig =="
send_owned_tx "$SYSTEM_CONFIG_OWNER" "$SYSTEM_CONFIG_PROXY" \
  "setOperatorFeeScalars(uint32,uint64)" \
  "$OPERATOR_FEE_SCALAR" \
  "$OPERATOR_FEE_CONSTANT"

echo "== verifying operator fee params on L1 SystemConfig =="
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeScalar()(uint32)" --rpc-url "$L1_RPC_URL"
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeConstant()(uint64)" --rpc-url "$L1_RPC_URL"

echo ""
echo "Wait for op-node to derive the L1 transaction block, then check L2:"
echo "  cast call 0x4200000000000000000000000000000000000015 'operatorFeeScalar()(uint32)' --rpc-url \$L2_RPC_URL"
echo "  cast call 0x4200000000000000000000000000000000000015 'operatorFeeConstant()(uint64)' --rpc-url \$L2_RPC_URL"
