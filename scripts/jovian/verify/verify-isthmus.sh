#!/usr/bin/env bash
set -euo pipefail

# Verify the private network after the Isthmus fork time has passed.
# Edit verify.env before running.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L2_RPC="${L2_RPC:?missing L2_RPC in verify.env}"
L2_VERIFY_PRIVATE_KEY="${L2_VERIFY_PRIVATE_KEY:?missing L2_VERIFY_PRIVATE_KEY in verify.env}"
ISTHMUS_TIME="${ISTHMUS_TIME:-0}"

GAS_PRICE_ORACLE="0x420000000000000000000000000000000000000F"

if [ "$L2_RPC" = "https://REPLACE_ME_L2_RPC" ] || [ "$L2_VERIFY_PRIVATE_KEY" = "0xREPLACE_ME" ]; then
  echo "ERROR: set L2_RPC and L2_VERIFY_PRIVATE_KEY before running."
  exit 1
fi

FROM=$(cast wallet address --private-key "$L2_VERIFY_PRIVATE_KEY")
TO="$FROM"

echo "============================================"
echo "  Isthmus Fork Verification"
echo "============================================"
echo "L2_RPC:       $L2_RPC"
echo "FROM:         $FROM"
echo "ISTHMUS_TIME: $ISTHMUS_TIME"
echo ""

echo "== latest block =="
BLOCK_JSON=$(cast block latest --rpc-url "$L2_RPC" --json)
echo "$BLOCK_JSON" | jq '{number,timestamp,baseFeePerGas,extraData,hash}'
BLOCK_TIME=$(echo "$BLOCK_JSON" | jq -r '.timestamp')
if [[ "$BLOCK_TIME" == 0x* ]]; then
  BLOCK_TIME=$(cast to-dec "$BLOCK_TIME")
fi

if [ "$ISTHMUS_TIME" != "0" ] && [ "$BLOCK_TIME" -lt "$ISTHMUS_TIME" ]; then
  echo "ERROR: latest block timestamp has not reached ISTHMUS_TIME."
  exit 1
fi
echo ""

echo "== fork flag =="
IS_ISTHMUS=$(cast call "$GAS_PRICE_ORACLE" "isIsthmus()(bool)" --rpc-url "$L2_RPC")
echo "isIsthmus: $IS_ISTHMUS"
if [ "$IS_ISTHMUS" != "true" ]; then
  echo "ERROR: GasPriceOracle.isIsthmus() is not true."
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
echo "OK: Isthmus basic verification passed."
echo "NOTE: EIP-7702 is enabled with Isthmus. Run scripts/jovian/7702/run.sh for the full SetCodeTx verification."
