#!/usr/bin/env bash
set -euo pipefail

# Query Jovian-related params from L1 SystemConfig and the currently derived
# L2 L1Block predeploy values.
#
# Usage:
#   bash scripts/jovian/query-systemconfig-params.sh

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc
[ -f scripts/jovian/upgrade.env ] && source scripts/jovian/upgrade.env

ARTIFACT_FILE="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}/artifact.json"
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "ERROR: artifact.json not found: $ARTIFACT_FILE"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT_FILE")
L1_BLOCK_PREDEPLOY="0x4200000000000000000000000000000000000015"
GAS_PRICE_ORACLE="0x420000000000000000000000000000000000000F"

if [ -z "$SYSTEM_CONFIG_PROXY" ] || [ "$SYSTEM_CONFIG_PROXY" = "null" ]; then
  echo "ERROR: SystemConfigProxy missing in $ARTIFACT_FILE"
  exit 1
fi

call_or_warn() {
  local rpc="$1"
  local address="$2"
  local sig="$3"
  shift 3

  cast call "$address" "$sig" "$@" --rpc-url "$rpc" 2>/dev/null || echo "UNAVAILABLE"
}

to_dec() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value"
  else
    echo "${value%% *}"
  fi
}

print_call_dec_or_warn() {
  local rpc="$1"
  local address="$2"
  local sig="$3"
  shift 3

  local value
  value=$(cast call "$address" "$sig" "$@" --rpc-url "$rpc" 2>/dev/null || true)
  if [ -z "$value" ]; then
    echo "UNAVAILABLE"
    return
  fi

  to_dec "$value"
}

decode_jovian_extra_data() {
  local extra="$1"
  local raw="${extra#0x}"
  local byte_len=$(( ${#raw} / 2 ))

  if [ "$byte_len" -ne 17 ]; then
    return 1
  fi

  local version_hex denominator_hex elasticity_hex min_base_fee_hex
  version_hex="0x${raw:0:2}"
  denominator_hex="0x${raw:2:8}"
  elasticity_hex="0x${raw:10:8}"
  min_base_fee_hex="0x${raw:18:16}"

  EXTRA_VERSION_DEC=$(to_dec "$version_hex")
  EXTRA_DENOMINATOR_DEC=$(to_dec "$denominator_hex")
  EXTRA_ELASTICITY_DEC=$(to_dec "$elasticity_hex")
  EXTRA_MIN_BASE_FEE_DEC=$(to_dec "$min_base_fee_hex")
}

echo "============================================"
echo "  Jovian SystemConfig Params"
echo "============================================"
echo "L1 RPC:              $L1_RPC_URL"
echo "L2 RPC:              $L2_RPC_URL"
echo "SystemConfigProxy:   $SYSTEM_CONFIG_PROXY"
echo "L2 L1Block:          $L1_BLOCK_PREDEPLOY"
echo ""

echo "== L1 SystemConfig =="
echo -n "version:                 "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "version()(string)"
echo -n "owner:                   "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "owner()(address)"
echo -n "eip1559Denominator:      "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "eip1559Denominator()(uint32)"
echo -n "eip1559Elasticity:       "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "eip1559Elasticity()(uint32)"
echo -n "operatorFeeScalar:       "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "operatorFeeScalar()(uint32)"
echo -n "operatorFeeConstant:     "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "operatorFeeConstant()(uint64)"
echo -n "daFootprintGasScalar:    "
call_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "daFootprintGasScalar()(uint16)"
echo -n "minBaseFee:              "
print_call_dec_or_warn "$L1_RPC_URL" "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)"
echo ""

echo "== L2 L1Block derived values =="
echo -n "operatorFeeScalar:       "
call_or_warn "$L2_RPC_URL" "$L1_BLOCK_PREDEPLOY" "operatorFeeScalar()(uint32)"
echo -n "operatorFeeConstant:     "
call_or_warn "$L2_RPC_URL" "$L1_BLOCK_PREDEPLOY" "operatorFeeConstant()(uint64)"
echo -n "daFootprintGasScalar:    "
call_or_warn "$L2_RPC_URL" "$L1_BLOCK_PREDEPLOY" "daFootprintGasScalar()(uint16)"
echo ""

echo "== L2 latest block fee params =="
if L2_BLOCK_JSON=$(cast rpc eth_getBlockByNumber latest false --rpc-url "$L2_RPC_URL" 2>/dev/null); then
  L2_BLOCK_NUMBER_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.number')
  L2_BASE_FEE_HEX=$(echo "$L2_BLOCK_JSON" | jq -r '.baseFeePerGas // empty')
  L2_EXTRA_DATA=$(echo "$L2_BLOCK_JSON" | jq -r '.extraData')

  echo "blockNumber:             $(to_dec "$L2_BLOCK_NUMBER_HEX") ($L2_BLOCK_NUMBER_HEX)"
  if [ -n "$L2_BASE_FEE_HEX" ] && [ "$L2_BASE_FEE_HEX" != "null" ]; then
    echo "baseFeePerGas:           $(to_dec "$L2_BASE_FEE_HEX") wei ($L2_BASE_FEE_HEX)"
  else
    echo "baseFeePerGas:           UNAVAILABLE"
  fi
  echo "extraData:               $L2_EXTRA_DATA"
  if decode_jovian_extra_data "$L2_EXTRA_DATA"; then
    echo "extraData.version:       $EXTRA_VERSION_DEC"
    echo "extraData.denominator:   $EXTRA_DENOMINATOR_DEC"
    echo "extraData.elasticity:    $EXTRA_ELASTICITY_DEC"
    echo "extraData.minBaseFee:    $EXTRA_MIN_BASE_FEE_DEC wei"
  else
    echo "extraData.minBaseFee:    UNAVAILABLE (latest block is not using Jovian extraData format)"
  fi
else
  echo "WARN: cannot query latest L2 block from $L2_RPC_URL"
fi
echo ""

echo "== L2 GasPriceOracle checks =="
echo -n "isIsthmus:               "
call_or_warn "$L2_RPC_URL" "$GAS_PRICE_ORACLE" "isIsthmus()(bool)"
echo -n "isJovian:                "
call_or_warn "$L2_RPC_URL" "$GAS_PRICE_ORACLE" "isJovian()(bool)"
echo -n "getOperatorFee(21000):   "
call_or_warn "$L2_RPC_URL" "$GAS_PRICE_ORACLE" "getOperatorFee(uint256)(uint256)" 21000
