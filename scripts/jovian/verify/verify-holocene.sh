#!/usr/bin/env bash
set -euo pipefail

# Verify the private network after the Holocene fork time has passed.
# Edit verify.env before running.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L2_RPC="${L2_RPC:?missing L2_RPC in verify.env}"
L2_VERIFY_PRIVATE_KEY="${L2_VERIFY_PRIVATE_KEY:?missing L2_VERIFY_PRIVATE_KEY in verify.env}"
HOLOCENE_TIME="${HOLOCENE_TIME:-0}"
EXPECTED_EIP1559_DENOMINATOR="${EXPECTED_EIP1559_DENOMINATOR:-0}"
EXPECTED_EIP1559_ELASTICITY="${EXPECTED_EIP1559_ELASTICITY:-0}"

if [ "$L2_RPC" = "https://REPLACE_ME_L2_RPC" ] || [ "$L2_VERIFY_PRIVATE_KEY" = "0xREPLACE_ME" ]; then
  echo "ERROR: set L2_RPC and L2_VERIFY_PRIVATE_KEY before running."
  exit 1
fi

FROM=$(cast wallet address --private-key "$L2_VERIFY_PRIVATE_KEY")
TO="$FROM"

echo "============================================"
echo "  Holocene Fork Verification"
echo "============================================"
echo "L2_RPC:        $L2_RPC"
echo "FROM:          $FROM"
echo "HOLOCENE_TIME: $HOLOCENE_TIME"
echo "EXPECTED_EIP1559_DENOMINATOR: $EXPECTED_EIP1559_DENOMINATOR"
echo "EXPECTED_EIP1559_ELASTICITY:  $EXPECTED_EIP1559_ELASTICITY"
echo ""

echo "== latest block =="
BLOCK_JSON=$(cast block latest --rpc-url "$L2_RPC" --json)
echo "$BLOCK_JSON" | jq '{number,timestamp,baseFeePerGas,extraData,hash}'
BLOCK_TIME=$(echo "$BLOCK_JSON" | jq -r '.timestamp')
EXTRA_DATA=$(echo "$BLOCK_JSON" | jq -r '.extraData')
if [[ "$BLOCK_TIME" == 0x* ]]; then
  BLOCK_TIME=$(cast to-dec "$BLOCK_TIME")
fi

if [ "$HOLOCENE_TIME" != "0" ] && [ "$BLOCK_TIME" -lt "$HOLOCENE_TIME" ]; then
  echo "ERROR: latest block timestamp has not reached HOLOCENE_TIME."
  exit 1
fi
echo ""

echo "== Holocene EIP-1559 params from extraData =="
RAW_EXTRA="${EXTRA_DATA#0x}"
EXTRA_BYTES=$(( ${#RAW_EXTRA} / 2 ))
if [ "$EXTRA_BYTES" -ne 9 ] && [ "$EXTRA_BYTES" -ne 17 ]; then
  echo "ERROR: expected Holocene/Jovian extraData length 9 or 17 bytes, got $EXTRA_BYTES bytes: $EXTRA_DATA"
  exit 1
fi

EXTRA_VERSION=$(cast to-dec "0x${RAW_EXTRA:0:2}")
DENOMINATOR=$(cast to-dec "0x${RAW_EXTRA:2:8}")
ELASTICITY=$(cast to-dec "0x${RAW_EXTRA:10:8}")
echo "extraData.version:     $EXTRA_VERSION"
echo "eip1559Denominator:   $DENOMINATOR"
echo "eip1559Elasticity:    $ELASTICITY"

if [ "$EXTRA_BYTES" -eq 9 ] && [ "$EXTRA_VERSION" != "0" ]; then
  echo "ERROR: Holocene extraData version should be 0."
  exit 1
fi

if [ "$EXTRA_BYTES" -eq 17 ] && [ "$EXTRA_VERSION" != "1" ]; then
  echo "ERROR: Jovian extraData version should be 1."
  exit 1
fi

if [ "$DENOMINATOR" = "0" ] || [ "$ELASTICITY" = "0" ]; then
  echo "ERROR: Holocene extraData must encode non-zero EIP-1559 params."
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

echo "== sender state =="
BALANCE=$(cast balance "$FROM" --rpc-url "$L2_RPC")
NONCE=$(cast nonce "$FROM" --rpc-url "$L2_RPC")
echo "balance: $BALANCE"
echo "nonce:   $NONCE"
if [ "$BALANCE" = "0" ]; then
  echo "ERROR: sender has no L2 native balance."
  exit 1
fi
echo ""

echo "== send ordinary L2 transaction =="
RECEIPT_JSON=$(cast send "$TO" --value 0 --private-key "$L2_VERIFY_PRIVATE_KEY" --rpc-url "$L2_RPC" --json)
echo "$RECEIPT_JSON" | jq '{transactionHash,status,blockNumber,gasUsed,effectiveGasPrice,l1Fee}'

STATUS=$(echo "$RECEIPT_JSON" | jq -r '.status')
if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "ERROR: transaction failed."
  exit 1
fi

echo ""
echo "OK: Holocene verification passed."
