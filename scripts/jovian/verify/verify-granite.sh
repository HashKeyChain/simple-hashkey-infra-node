#!/usr/bin/env bash
set -euo pipefail

# Verify the private network after the Granite fork time has passed.
# Edit verify.env before running.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L2_RPC="${L2_RPC:?missing L2_RPC in verify.env}"
L2_VERIFY_PRIVATE_KEY="${L2_VERIFY_PRIVATE_KEY:?missing L2_VERIFY_PRIVATE_KEY in verify.env}"
GRANITE_TIME="${GRANITE_TIME:-0}"

if [ "$L2_RPC" = "https://REPLACE_ME_L2_RPC" ] || [ "$L2_VERIFY_PRIVATE_KEY" = "0xREPLACE_ME" ]; then
  echo "ERROR: set L2_RPC and L2_VERIFY_PRIVATE_KEY before running."
  exit 1
fi

FROM=$(cast wallet address --private-key "$L2_VERIFY_PRIVATE_KEY")
TO="$FROM"

echo "============================================"
echo "  Granite Fork Verification"
echo "============================================"
echo "L2_RPC:       $L2_RPC"
echo "FROM:         $FROM"
echo "GRANITE_TIME: $GRANITE_TIME"
echo ""

echo "== latest block =="
BLOCK_JSON=$(cast block latest --rpc-url "$L2_RPC" --json)
echo "$BLOCK_JSON" | jq '{number,timestamp,baseFeePerGas,hash}'
BLOCK_TIME=$(echo "$BLOCK_JSON" | jq -r '.timestamp')
if [[ "$BLOCK_TIME" == 0x* ]]; then
  BLOCK_TIME=$(cast to-dec "$BLOCK_TIME")
fi

if [ "$GRANITE_TIME" != "0" ] && [ "$BLOCK_TIME" -lt "$GRANITE_TIME" ]; then
  echo "ERROR: latest block timestamp has not reached GRANITE_TIME."
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
echo "$RECEIPT_JSON" | jq '{transactionHash,status,blockNumber,gasUsed,effectiveGasPrice}'

STATUS=$(echo "$RECEIPT_JSON" | jq -r '.status')
if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "ERROR: transaction failed."
  exit 1
fi

echo ""
echo "OK: Granite verification passed."
