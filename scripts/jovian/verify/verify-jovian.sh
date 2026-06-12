#!/usr/bin/env bash
set -euo pipefail

# Verify the private network after the Jovian fork time has passed.
# Edit verify.env before running.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L2_RPC="${L2_RPC:?missing L2_RPC in verify.env}"
L2_VERIFY_PRIVATE_KEY="${L2_VERIFY_PRIVATE_KEY:?missing L2_VERIFY_PRIVATE_KEY in verify.env}"
JOVIAN_TIME="${JOVIAN_TIME:-0}"
EXPECTED_EIP1559_DENOMINATOR="${EXPECTED_EIP1559_DENOMINATOR:-0}"
EXPECTED_EIP1559_ELASTICITY="${EXPECTED_EIP1559_ELASTICITY:-0}"

GAS_PRICE_ORACLE="0x420000000000000000000000000000000000000F"
L1_BLOCK_PREDEPLOY="0x4200000000000000000000000000000000000015"
BASE_FEE_VAULT="0x4200000000000000000000000000000000000019"
OPERATOR_FEE_VAULT="0x420000000000000000000000000000000000001B"

if [ "$L2_RPC" = "https://REPLACE_ME_L2_RPC" ] || [ "$L2_VERIFY_PRIVATE_KEY" = "0xREPLACE_ME" ]; then
  echo "ERROR: set L2_RPC and L2_VERIFY_PRIVATE_KEY before running."
  exit 1
fi

FROM=$(cast wallet address --private-key "$L2_VERIFY_PRIVATE_KEY")
TO="$FROM"

echo "============================================"
echo "  Jovian Fork Verification"
echo "============================================"
echo "L2_RPC:      $L2_RPC"
echo "FROM:        $FROM"
echo "JOVIAN_TIME: $JOVIAN_TIME"
echo "EXPECTED_EIP1559_DENOMINATOR: $EXPECTED_EIP1559_DENOMINATOR"
echo "EXPECTED_EIP1559_ELASTICITY:  $EXPECTED_EIP1559_ELASTICITY"
echo ""

echo "== latest block =="
BLOCK_JSON=$(cast block latest --rpc-url "$L2_RPC" --json)
echo "$BLOCK_JSON" | jq '{number,timestamp,baseFeePerGas,extraData,blobGasUsed,hash}'
BLOCK_TIME=$(echo "$BLOCK_JSON" | jq -r '.timestamp')
EXTRA_DATA=$(echo "$BLOCK_JSON" | jq -r '.extraData')
if [[ "$BLOCK_TIME" == 0x* ]]; then
  BLOCK_TIME=$(cast to-dec "$BLOCK_TIME")
fi

if [ "$JOVIAN_TIME" != "0" ] && [ "$BLOCK_TIME" -lt "$JOVIAN_TIME" ]; then
  echo "ERROR: latest block timestamp has not reached JOVIAN_TIME."
  exit 1
fi
echo ""

echo "== Jovian EIP-1559 params from extraData =="
RAW_EXTRA="${EXTRA_DATA#0x}"
EXTRA_BYTES=$(( ${#RAW_EXTRA} / 2 ))
if [ "$EXTRA_BYTES" -ne 17 ]; then
  echo "ERROR: expected Jovian extraData length 17 bytes, got $EXTRA_BYTES bytes: $EXTRA_DATA"
  exit 1
fi

EXTRA_VERSION=$(cast to-dec "0x${RAW_EXTRA:0:2}")
DENOMINATOR=$(cast to-dec "0x${RAW_EXTRA:2:8}")
ELASTICITY=$(cast to-dec "0x${RAW_EXTRA:10:8}")
MIN_BASE_FEE=$(cast to-dec "0x${RAW_EXTRA:18:16}")
echo "extraData.version:     $EXTRA_VERSION"
echo "eip1559Denominator:   $DENOMINATOR"
echo "eip1559Elasticity:    $ELASTICITY"
echo "minBaseFee:           $MIN_BASE_FEE"

if [ "$EXTRA_VERSION" != "1" ]; then
  echo "ERROR: Jovian extraData version should be 1."
  exit 1
fi

if [ "$DENOMINATOR" = "0" ] || [ "$ELASTICITY" = "0" ]; then
  echo "ERROR: Jovian extraData must encode non-zero EIP-1559 params."
  exit 1
fi

if [ "$EXPECTED_EIP1559_DENOMINATOR" != "0" ] && [ "$DENOMINATOR" != "$EXPECTED_EIP1559_DENOMINATOR" ]; then
  echo "ERROR: denominator mismatch, expected $EXPECTED_EIP1559_DENOMINATOR got $DENOMINATOR."
  exit 1
fi

if [ "$EXPECTED_EIP1559_ELASTICITY" != "0" ] && [ "$ELASTICITY" != "$EXPECTED_EIP1559_ELASTICITY" ]; then
  echo "ERROR: elasticity mismatch, expected $EXPECTED_EIP1559_ELASTICITY got $ELASTICITY."
  exit 1
fi
echo ""

echo "== fork flag =="
IS_JOVIAN=$(cast call "$GAS_PRICE_ORACLE" "isJovian()(bool)" --rpc-url "$L2_RPC")
echo "isJovian: $IS_JOVIAN"
if [ "$IS_JOVIAN" != "true" ]; then
  echo "ERROR: GasPriceOracle.isJovian() is not true."
  exit 1
fi
echo ""

echo "== L1Block derived Jovian values =="
echo -n "operatorFeeScalar:    "
cast call "$L1_BLOCK_PREDEPLOY" "operatorFeeScalar()(uint32)" --rpc-url "$L2_RPC" || true
echo -n "operatorFeeConstant:  "
cast call "$L1_BLOCK_PREDEPLOY" "operatorFeeConstant()(uint64)" --rpc-url "$L2_RPC" || true
echo -n "daFootprintGasScalar: "
cast call "$L1_BLOCK_PREDEPLOY" "daFootprintGasScalar()(uint16)" --rpc-url "$L2_RPC" || true
echo ""

echo "== balances before transaction =="
BASE_FEE_VAULT_BALANCE_BEFORE=$(cast balance "$BASE_FEE_VAULT" --rpc-url "$L2_RPC")
OPERATOR_FEE_VAULT_BALANCE_BEFORE=$(cast balance "$OPERATOR_FEE_VAULT" --rpc-url "$L2_RPC")
echo "baseFeeVault:     $BASE_FEE_VAULT_BALANCE_BEFORE"
echo "operatorFeeVault: $OPERATOR_FEE_VAULT_BALANCE_BEFORE"
echo ""

echo "== send ordinary L2 transaction =="
RECEIPT_JSON=$(cast send "$TO" --value 0 --private-key "$L2_VERIFY_PRIVATE_KEY" --rpc-url "$L2_RPC" --json)
echo "$RECEIPT_JSON" | jq '{
  transactionHash,
  status,
  blockNumber,
  gasUsed,
  effectiveGasPrice,
  l1Fee,
  operatorFeeScalar,
  operatorFeeConstant
}'

STATUS=$(echo "$RECEIPT_JSON" | jq -r '.status')
if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "ERROR: transaction failed."
  exit 1
fi

echo ""
echo "== balances after transaction =="
BASE_FEE_VAULT_BALANCE_AFTER=$(cast balance "$BASE_FEE_VAULT" --rpc-url "$L2_RPC")
OPERATOR_FEE_VAULT_BALANCE_AFTER=$(cast balance "$OPERATOR_FEE_VAULT" --rpc-url "$L2_RPC")
BASE_FEE_VAULT_RECEIVED=$((BASE_FEE_VAULT_BALANCE_AFTER - BASE_FEE_VAULT_BALANCE_BEFORE))
OPERATOR_FEE_VAULT_RECEIVED=$((OPERATOR_FEE_VAULT_BALANCE_AFTER - OPERATOR_FEE_VAULT_BALANCE_BEFORE))
echo "baseFeeVaultBefore:     $BASE_FEE_VAULT_BALANCE_BEFORE"
echo "baseFeeVaultAfter:      $BASE_FEE_VAULT_BALANCE_AFTER"
echo "baseFeeVaultGot:        $BASE_FEE_VAULT_RECEIVED"
echo "operatorFeeVaultBefore: $OPERATOR_FEE_VAULT_BALANCE_BEFORE"
echo "operatorFeeVaultAfter:  $OPERATOR_FEE_VAULT_BALANCE_AFTER"
echo "operatorFeeVaultGot:    $OPERATOR_FEE_VAULT_RECEIVED"

echo ""
echo "OK: Jovian verification passed."
