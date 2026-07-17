#!/usr/bin/env bash
set -euo pipefail

# Set L1 SystemConfig EIP-1559 params for local Holocene/Jovian testing.
#
# Usage:
#   bash scripts/jovian/set-eip1559-params.sh [denominator] [elasticity]
#
# Defaults:
#   denominator = ${EIP1559_DENOMINATOR:-250}
#   elasticity  = ${EIP1559_ELASTICITY:-6}
#
# Environment variables:
#   EIP1559_PRIVATE_KEY defaults to $GS_ADMIN_PRIVATE_KEY

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc
[ -f scripts/jovian/upgrade.env ] && source scripts/jovian/upgrade.env

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
EIP1559_DENOMINATOR="${1:-${EIP1559_DENOMINATOR:-250}}"
EIP1559_ELASTICITY="${2:-${EIP1559_ELASTICITY:-6}}"
EIP1559_PRIVATE_KEY="${EIP1559_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
EIP1559_SIGNER=$(cast wallet address --private-key "$EIP1559_PRIVATE_KEY")
UINT32_MAX="4294967295"

to_dec() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value"
  else
    echo "${value%% *}"
  fi
}

require_uint32_nonzero() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name must be a uint32 decimal value: $value"
    exit 1
  fi

  if [ "$value" = "0" ]; then
    echo "ERROR: $name must be >= 1. SystemConfig.setEIP1559Params does not accept 0."
    exit 1
  fi

  if [ "$(echo "$value <= $UINT32_MAX" | bc)" != "1" ]; then
    echo "ERROR: $name exceeds uint32 max: $value"
    exit 1
  fi
}

decode_jovian_or_holocene_extra_data() {
  local extra="$1"
  local raw="${extra#0x}"
  local byte_len=$(( ${#raw} / 2 ))

  if [ "$byte_len" -ne 9 ] && [ "$byte_len" -ne 17 ]; then
    return 1
  fi

  local version_hex denominator_hex elasticity_hex
  version_hex="0x${raw:0:2}"
  denominator_hex="0x${raw:2:8}"
  elasticity_hex="0x${raw:10:8}"

  EXTRA_VERSION_DEC=$(to_dec "$version_hex")
  EXTRA_DENOMINATOR_DEC=$(to_dec "$denominator_hex")
  EXTRA_ELASTICITY_DEC=$(to_dec "$elasticity_hex")
}

require_uint32_nonzero "denominator" "$EIP1559_DENOMINATOR"
require_uint32_nonzero "elasticity" "$EIP1559_ELASTICITY"

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
  if [ "$(echo "$safe_owner" | tr '[:upper:]' '[:lower:]')" != "$(echo "$EIP1559_SIGNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "ERROR: EIP-1559 signer is not the 1-of-1 SystemOwnerSafe owner"
    echo "  signer:    $EIP1559_SIGNER"
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
    --private-key "$EIP1559_PRIVATE_KEY" \
    --rpc-url "$L1_RPC_URL"
}

send_owned_tx() {
  local owner="$1"
  local to="$2"
  local signature="$3"
  shift 3

  local owner_lc signer_lc safe_lc
  owner_lc=$(echo "$owner" | tr '[:upper:]' '[:lower:]')
  signer_lc=$(echo "$EIP1559_SIGNER" | tr '[:upper:]' '[:lower:]')
  safe_lc=$(echo "$SYSTEM_OWNER_SAFE" | tr '[:upper:]' '[:lower:]')

  if [ "$owner_lc" = "$signer_lc" ]; then
    cast send "$to" "$signature" "$@" \
      --private-key "$EIP1559_PRIVATE_KEY" \
      --rpc-url "$L1_RPC_URL"
  elif [ "$owner_lc" = "$safe_lc" ]; then
    local calldata
    calldata=$(cast calldata "$signature" "$@")
    send_safe_tx "$to" "$calldata"
  else
    echo "ERROR: unsupported SystemConfig owner"
    echo "  owner:  $owner"
    echo "  signer: $EIP1559_SIGNER"
    echo "  safe:   $SYSTEM_OWNER_SAFE"
    exit 1
  fi
}

echo "============================================"
echo "  Holocene/Jovian EIP-1559 Params"
echo "============================================"
echo "L1 RPC:              $L1_RPC_URL"
echo "L2 RPC:              $L2_RPC"
echo "SystemConfigProxy:   $SYSTEM_CONFIG_PROXY"
echo "SystemOwnerSafe:     $SYSTEM_OWNER_SAFE"
echo "signer:              $EIP1559_SIGNER"
echo "eip1559Denominator:  $EIP1559_DENOMINATOR"
echo "eip1559Elasticity:   $EIP1559_ELASTICITY"
echo ""

SYSTEM_CONFIG_OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC_URL")
echo "SystemConfig owner:  $SYSTEM_CONFIG_OWNER"
echo ""

echo "== current EIP-1559 params on L1 SystemConfig =="
echo -n "eip1559Denominator: "
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Denominator()(uint32)" --rpc-url "$L1_RPC_URL"
echo -n "eip1559Elasticity:  "
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Elasticity()(uint32)" --rpc-url "$L1_RPC_URL"
echo ""

echo "== current L2 latest block EIP-1559 params =="
if L2_BLOCK_JSON=$(cast rpc eth_getBlockByNumber latest false --rpc-url "$L2_RPC" 2>/dev/null); then
  L2_BLOCK_NUMBER_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.number')
  L2_BASE_FEE_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.baseFeePerGas // empty')
  L2_EXTRA_DATA=$(echo "$L2_BLOCK_JSON" | jq -r '.extraData')

  echo "latest block:       $(to_dec "$L2_BLOCK_NUMBER_HEX") ($L2_BLOCK_NUMBER_HEX)"
  if [ -n "$L2_BASE_FEE_HEX" ] && [ "$L2_BASE_FEE_HEX" != "null" ]; then
    echo "baseFeePerGas:      $(to_dec "$L2_BASE_FEE_HEX") wei ($L2_BASE_FEE_HEX)"
  else
    echo "baseFeePerGas:      UNAVAILABLE"
  fi
  echo "extraData:          $L2_EXTRA_DATA"
  if decode_jovian_or_holocene_extra_data "$L2_EXTRA_DATA"; then
    echo "extraData.version:  $EXTRA_VERSION_DEC"
    echo "extraData.denom:    $EXTRA_DENOMINATOR_DEC"
    echo "extraData.elastic:  $EXTRA_ELASTICITY_DEC"
  else
    echo "extraData params:   UNAVAILABLE"
  fi
else
  echo "WARN: cannot query latest L2 block from $L2_RPC"
fi
echo ""

echo "== setting EIP-1559 params on L1 SystemConfig =="
send_owned_tx "$SYSTEM_CONFIG_OWNER" "$SYSTEM_CONFIG_PROXY" \
  "setEIP1559Params(uint32,uint32)" \
  "$EIP1559_DENOMINATOR" \
  "$EIP1559_ELASTICITY"

echo "== verifying EIP-1559 params on L1 SystemConfig =="
echo -n "eip1559Denominator: "
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Denominator()(uint32)" --rpc-url "$L1_RPC_URL"
echo -n "eip1559Elasticity:  "
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Elasticity()(uint32)" --rpc-url "$L1_RPC_URL"

echo ""
echo "Wait for op-node to derive the L1 transaction block, then check L2:"
echo "  bash scripts/jovian/query-systemconfig-params.sh"
