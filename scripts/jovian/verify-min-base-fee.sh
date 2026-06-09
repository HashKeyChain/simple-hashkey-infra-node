#!/usr/bin/env bash
set -euo pipefail

# Verify Jovian minBaseFee propagation and enforcement.
#
# Usage:
#   bash scripts/jovian/verify-min-base-fee.sh [expected_min_base_fee_wei]
#
# If no expected value is supplied, the script uses L1 SystemConfig.minBaseFee().

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
EXPECTED_MIN_BASE_FEE="${1:-${MIN_BASE_FEE:-}}"
POLL_ATTEMPTS="${VERIFY_MIN_BASE_FEE_ATTEMPTS:-60}"
POLL_INTERVAL="${VERIFY_MIN_BASE_FEE_INTERVAL:-2}"

ARTIFACT_FILE="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}/artifact.json"
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "ERROR: artifact.json not found: $ARTIFACT_FILE"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT_FILE")
if [ -z "$SYSTEM_CONFIG_PROXY" ] || [ "$SYSTEM_CONFIG_PROXY" = "null" ]; then
  echo "ERROR: SystemConfigProxy missing in $ARTIFACT_FILE"
  exit 1
fi

to_dec() {
  local value="$1"
  if [[ "$value" == 0x* ]]; then
    cast to-dec "$value"
  else
    echo "$value"
  fi
}

require_uint64_decimal() {
  local name="$1"
  local value="$2"
  local uint64_max="18446744073709551615"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $name must be a uint64 decimal value in wei: $value"
    exit 1
  fi

  if [ "$(echo "$value <= $uint64_max" | bc)" != "1" ]; then
    echo "ERROR: $name exceeds uint64 max: $value"
    exit 1
  fi
}

decode_jovian_extra_data() {
  local extra="$1"
  local raw="${extra#0x}"
  local byte_len=$(( ${#raw} / 2 ))

  if [ "$byte_len" -ne 17 ]; then
    echo "ERROR: expected Jovian extraData to be 17 bytes, got $byte_len bytes: $extra" >&2
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
echo "  Jovian Min Base Fee Verification"
echo "============================================"
echo "L1 RPC:            $L1_RPC_URL"
echo "L2 RPC:            $L2_RPC"
echo "SystemConfigProxy: $SYSTEM_CONFIG_PROXY"
echo ""

L1_MIN_BASE_FEE=$(cast call "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)" --rpc-url "$L1_RPC_URL")
L1_MIN_BASE_FEE=$(to_dec "$L1_MIN_BASE_FEE")

if [ -z "$EXPECTED_MIN_BASE_FEE" ]; then
  EXPECTED_MIN_BASE_FEE="$L1_MIN_BASE_FEE"
fi
EXPECTED_MIN_BASE_FEE=$(to_dec "$EXPECTED_MIN_BASE_FEE")

require_uint64_decimal "expected minBaseFee" "$EXPECTED_MIN_BASE_FEE"
require_uint64_decimal "L1 minBaseFee" "$L1_MIN_BASE_FEE"

echo "== L1 SystemConfig =="
echo "minBaseFee: $L1_MIN_BASE_FEE"
echo ""

if [ "$L1_MIN_BASE_FEE" != "$EXPECTED_MIN_BASE_FEE" ]; then
  echo "ERROR: L1 SystemConfig.minBaseFee does not match expected value."
  echo "  expected: $EXPECTED_MIN_BASE_FEE"
  echo "  actual:   $L1_MIN_BASE_FEE"
  exit 1
fi

echo "== waiting for L2 extraData and baseFeePerGas =="
echo "expected minBaseFee: $EXPECTED_MIN_BASE_FEE"
echo "attempts:            $POLL_ATTEMPTS"
echo "interval:            ${POLL_INTERVAL}s"
echo ""

LAST_BLOCK_NUMBER=""
LAST_BASE_FEE=""
LAST_EXTRA_DATA=""
LAST_EXTRA_MIN_BASE_FEE=""

for attempt in $(seq 1 "$POLL_ATTEMPTS"); do
  BLOCK_JSON=$(cast rpc eth_getBlockByNumber latest false --rpc-url "$L2_RPC")
  BLOCK_NUMBER=$(to_dec "$(echo "$BLOCK_JSON" | jq -r '.number')")
  BASE_FEE=$(to_dec "$(echo "$BLOCK_JSON" | jq -r '.baseFeePerGas')")
  EXTRA_DATA=$(echo "$BLOCK_JSON" | jq -r '.extraData')

  LAST_BLOCK_NUMBER="$BLOCK_NUMBER"
  LAST_BASE_FEE="$BASE_FEE"
  LAST_EXTRA_DATA="$EXTRA_DATA"

  if decode_jovian_extra_data "$EXTRA_DATA" 2>/dev/null; then
    LAST_EXTRA_MIN_BASE_FEE="$EXTRA_MIN_BASE_FEE_DEC"

    if [ "$EXTRA_MIN_BASE_FEE_DEC" = "$EXPECTED_MIN_BASE_FEE" ]; then
      echo "matched L2 extraData at block $BLOCK_NUMBER"
      echo "  version:       $EXTRA_VERSION_DEC"
      echo "  denominator:   $EXTRA_DENOMINATOR_DEC"
      echo "  elasticity:    $EXTRA_ELASTICITY_DEC"
      echo "  minBaseFee:    $EXTRA_MIN_BASE_FEE_DEC"
      echo "  baseFeePerGas: $BASE_FEE"
      echo ""

      if [ "$(echo "$BASE_FEE >= $EXPECTED_MIN_BASE_FEE" | bc)" = "1" ]; then
        echo "OK: L2 block extraData contains expected minBaseFee."
        echo "OK: L2 baseFeePerGas is >= minBaseFee."
        echo ""
        echo "=== Done ==="
        exit 0
      fi

      echo "extraData is updated, but baseFeePerGas is still below minBaseFee; waiting for next block..."
    elif [ "$attempt" = "1" ] || [ $((attempt % 5)) -eq 0 ]; then
      echo "attempt $attempt/$POLL_ATTEMPTS: block=$BLOCK_NUMBER extraData.minBaseFee=$EXTRA_MIN_BASE_FEE_DEC baseFeePerGas=$BASE_FEE"
    fi
  elif [ "$attempt" = "1" ] || [ $((attempt % 5)) -eq 0 ]; then
    echo "attempt $attempt/$POLL_ATTEMPTS: block=$BLOCK_NUMBER has non-Jovian extraData: $EXTRA_DATA"
  fi

  sleep "$POLL_INTERVAL"
done

echo "ERROR: minBaseFee was not observed on L2 within the polling window."
echo "last block:              $LAST_BLOCK_NUMBER"
echo "last baseFeePerGas:      $LAST_BASE_FEE"
echo "last extraData:          $LAST_EXTRA_DATA"
echo "last extraData.minBaseFee: ${LAST_EXTRA_MIN_BASE_FEE:-UNAVAILABLE}"
echo "expected minBaseFee:     $EXPECTED_MIN_BASE_FEE"
echo ""
echo "If L1 was just updated, wait for op-node to derive the L1 transaction block and rerun this script."
exit 1
