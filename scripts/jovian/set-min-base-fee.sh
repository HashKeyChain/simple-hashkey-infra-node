#!/usr/bin/env bash
set -euo pipefail

# Set L1 SystemConfig minBaseFee for local Jovian testing.
#
# Usage:
#   bash scripts/jovian/set-min-base-fee.sh [min_base_fee_wei]
#
# Defaults:
#   min_base_fee_wei = ${MIN_BASE_FEE:-1000000000}
#
# Environment variables:
#   MIN_BASE_FEE_PRIVATE_KEY defaults to $GS_ADMIN_PRIVATE_KEY

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
MIN_BASE_FEE="${1:-${MIN_BASE_FEE:-1000000000}}"
MIN_BASE_FEE_PRIVATE_KEY="${MIN_BASE_FEE_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
MIN_BASE_FEE_SIGNER=$(cast wallet address --private-key "$MIN_BASE_FEE_PRIVATE_KEY")
UINT64_MAX="18446744073709551615"

to_dec() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value"
  else
    echo "${value%% *}"
  fi
}

if ! [[ "$MIN_BASE_FEE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: minBaseFee must be a uint64 decimal value in wei: $MIN_BASE_FEE"
  exit 1
fi

if [ "$(echo "$MIN_BASE_FEE <= $UINT64_MAX" | bc)" != "1" ]; then
  echo "ERROR: minBaseFee exceeds uint64 max: $MIN_BASE_FEE"
  exit 1
fi

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
  if [ "$(echo "$safe_owner" | tr '[:upper:]' '[:lower:]')" != "$(echo "$MIN_BASE_FEE_SIGNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: min base fee signer is not the 1-of-1 SystemOwnerSafe owner"
    echo "  signer:    $MIN_BASE_FEE_SIGNER"
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
    --private-key "$MIN_BASE_FEE_PRIVATE_KEY" \
    --rpc-url "$L1_RPC_URL"
}

send_owned_tx() {
  local owner="$1"
  local to="$2"
  local signature="$3"
  shift 3

  local owner_lc signer_lc safe_lc
  owner_lc=$(echo "$owner" | tr '[:upper:]' '[:lower:]')
  signer_lc=$(echo "$MIN_BASE_FEE_SIGNER" | tr '[:upper:]' '[:lower:]')
  safe_lc=$(echo "$SYSTEM_OWNER_SAFE" | tr '[:upper:]' '[:lower:]')

  if [ "$owner_lc" = "$signer_lc" ]; then
    cast send "$to" "$signature" "$@" \
      --private-key "$MIN_BASE_FEE_PRIVATE_KEY" \
      --rpc-url "$L1_RPC_URL"
  elif [ "$owner_lc" = "$safe_lc" ]; then
    local calldata
    calldata=$(cast calldata "$signature" "$@")
    send_safe_tx "$to" "$calldata"
  else
    echo "ERROR: unsupported SystemConfig owner"
    echo "  owner:  $owner"
    echo "  signer: $MIN_BASE_FEE_SIGNER"
    echo "  safe:   $SYSTEM_OWNER_SAFE"
    exit 1
  fi
}

echo "============================================"
echo "  Jovian Min Base Fee"
echo "============================================"
echo "L1 RPC:            $L1_RPC_URL"
echo "L2 RPC:            $L2_RPC"
echo "SystemConfigProxy: $SYSTEM_CONFIG_PROXY"
echo "SystemOwnerSafe:   $SYSTEM_OWNER_SAFE"
echo "signer:            $MIN_BASE_FEE_SIGNER"
echo "minBaseFee:        $MIN_BASE_FEE wei"
echo ""

SYSTEM_CONFIG_OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC_URL")
echo "SystemConfig owner: $SYSTEM_CONFIG_OWNER"
echo ""

echo "== current L2 base fee =="
if L2_BLOCK_JSON=$(cast rpc eth_getBlockByNumber latest false --rpc-url "$L2_RPC" 2>/dev/null); then
  L2_BLOCK_NUMBER_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.number')
  L2_BASE_FEE_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.baseFeePerGas // empty')
  L2_BLOCK_NUMBER_DEC=$(to_dec "$L2_BLOCK_NUMBER_HEX")

  echo "latest block:     $L2_BLOCK_NUMBER_DEC ($L2_BLOCK_NUMBER_HEX)"
  if [ -n "$L2_BASE_FEE_HEX" ] && [ "$L2_BASE_FEE_HEX" != "null" ]; then
    L2_BASE_FEE_DEC=$(to_dec "$L2_BASE_FEE_HEX")
    echo "baseFeePerGas:    $L2_BASE_FEE_DEC wei ($L2_BASE_FEE_HEX)"
    if [ "$(echo "$MIN_BASE_FEE > $L2_BASE_FEE_DEC" | bc)" = "1" ]; then
      echo "target relation:  minBaseFee is above current baseFeePerGas, clamp should be visible after propagation."
    else
      echo "target relation:  minBaseFee is not above current baseFeePerGas; clamp may not be visually obvious."
      echo "                  For a visible test, choose a minBaseFee greater than $L2_BASE_FEE_DEC wei."
    fi
  else
    echo "baseFeePerGas:    UNAVAILABLE"
  fi
else
  echo "WARN: cannot query latest L2 block from $L2_RPC"
fi
echo ""

echo "== current minBaseFee on L1 SystemConfig =="
cast call "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)" --rpc-url "$L1_RPC_URL"
echo ""

echo "== setting minBaseFee on L1 SystemConfig =="
send_owned_tx "$SYSTEM_CONFIG_OWNER" "$SYSTEM_CONFIG_PROXY" \
  "setMinBaseFee(uint64)" \
  "$MIN_BASE_FEE"

echo "== verifying minBaseFee on L1 SystemConfig =="
cast call "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)" --rpc-url "$L1_RPC_URL"

echo ""
echo "Wait for op-node to derive the L1 transaction block, then verify L2:"
echo "  bash scripts/jovian/verify-min-base-fee.sh $MIN_BASE_FEE"
