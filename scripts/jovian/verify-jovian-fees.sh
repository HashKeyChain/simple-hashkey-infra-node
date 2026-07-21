#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
KEY="${1:-$DEPLOY_PRIVATE_KEY}"
TO="${2:-0x000000000000000000000000000000000000dEaD}"

GPO="0x420000000000000000000000000000000000000F"
OPERATOR_FEE_VAULT="0x420000000000000000000000000000000000001B"

FROM=$(cast wallet address --private-key "$KEY")

receipt_hex_to_dec() {
  local jq_filter="$1"
  local value

  value=$(jq -r "$jq_filter // empty" "$RECEIPT_FILE")
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "null"
    return
  fi

  cast to-dec "$value"
}

echo "=== Jovian Fee Verification ==="
echo "L2_RPC=$L2_RPC"
echo "FROM=$FROM"
echo "TO=$TO"
echo ""

echo "== latest block =="
cast block latest --rpc-url "$L2_RPC" --json | jq '{number,timestamp,baseFeePerGas,hash}'
echo ""

echo "== fork flags =="
echo -n "isFjord:   "
cast call "$GPO" "isFjord()(bool)" --rpc-url "$L2_RPC" || true
echo -n "isIsthmus: "
cast call "$GPO" "isIsthmus()(bool)" --rpc-url "$L2_RPC" || true
echo -n "isJovian:  "
cast call "$GPO" "isJovian()(bool)" --rpc-url "$L2_RPC" || true
echo ""

echo "== operator fee vault code length =="
CODE_LEN=$(cast code "$OPERATOR_FEE_VAULT" --rpc-url "$L2_RPC" | wc -c | tr -d ' ')
echo "$CODE_LEN"
echo ""

echo "== balances before =="
FROM_BALANCE=$(cast balance "$FROM" --rpc-url "$L2_RPC")
VAULT_BEFORE=$(cast balance "$OPERATOR_FEE_VAULT" --rpc-url "$L2_RPC")
echo "sender balance:              $FROM_BALANCE"
echo "operator fee vault balance:  $VAULT_BEFORE"
echo ""

if [ "$FROM_BALANCE" = "0" ]; then
  echo "ERROR: sender has no L2 native balance. Bridge custom gas token to $FROM first."
  exit 1
fi

echo "== send L2 transaction =="
NONCE_HEX=$(cast rpc eth_getTransactionCount "$FROM" latest --rpc-url "$L2_RPC" | tr -d '"')
PENDING_NONCE_HEX=$(cast rpc eth_getTransactionCount "$FROM" pending --rpc-url "$L2_RPC" | tr -d '"')
NONCE=$(cast to-dec "$NONCE_HEX")
MAX_FEE_PER_GAS=$(cast to-dec "$(cast rpc eth_gasPrice --rpc-url "$L2_RPC" | tr -d '"')")
MAX_PRIORITY_FEE_PER_GAS=$(cast to-dec "$(cast rpc eth_maxPriorityFeePerGas --rpc-url "$L2_RPC" | tr -d '"')")

if [ "$PENDING_NONCE_HEX" != "$NONCE_HEX" ]; then
  echo "pending tx detected, replacing nonce $NONCE with bumped fees"
  MAX_FEE_PER_GAS=$((MAX_FEE_PER_GAS * 3))
  MAX_PRIORITY_FEE_PER_GAS=$((MAX_PRIORITY_FEE_PER_GAS * 3))
fi

echo "nonce:                    $NONCE"
echo "max fee per gas:          $MAX_FEE_PER_GAS"
echo "max priority fee per gas: $MAX_PRIORITY_FEE_PER_GAS"

TX_HASH=""
if [ "$PENDING_NONCE_HEX" != "$NONCE_HEX" ]; then
  FROM_LOWER=$(echo "$FROM" | tr '[:upper:]' '[:lower:]')
  TX_HASH=$(cast rpc txpool_content --rpc-url "$L2_RPC" | jq -r --arg from "$FROM_LOWER" --arg nonce "$NONCE" '
    .pending
    | to_entries[]?
    | select(.key | ascii_downcase == $from)
    | .value[$nonce].hash // empty
  ')
  if [ -n "$TX_HASH" ]; then
    echo "using existing pending tx: $TX_HASH"
  fi
fi

if [ -z "$TX_HASH" ]; then
  TX_HASH=$(cast send "$TO" \
    --value 0 \
    --nonce "$NONCE" \
    --gas-price "$MAX_FEE_PER_GAS" \
    --priority-gas-price "$MAX_PRIORITY_FEE_PER_GAS" \
    --private-key "$KEY" \
    --rpc-url "$L2_RPC" \
    --async)
fi
echo "tx=$TX_HASH"
echo ""

echo "waiting for receipt..."
RECEIPT_FILE="${TMPDIR:-/tmp}/jovian-fee-receipt.json"
rm -f "$RECEIPT_FILE"
for _ in $(seq 1 30); do
  RECEIPT_JSON=$(cast rpc eth_getTransactionReceipt "$TX_HASH" --rpc-url "$L2_RPC" 2>/dev/null || true)
  if [ -n "$RECEIPT_JSON" ] && [ "$RECEIPT_JSON" != "null" ]; then
    echo "$RECEIPT_JSON" >"$RECEIPT_FILE"
    break
  fi
  sleep 1
done

if [ ! -s "$RECEIPT_FILE" ]; then
  echo "ERROR: transaction was submitted but not confirmed within 30s."
  echo ""
  echo "== txpool status =="
  cast rpc txpool_status --rpc-url "$L2_RPC" || true
  echo ""
  echo "== nonce latest/pending =="
  cast rpc eth_getTransactionCount "$FROM" latest --rpc-url "$L2_RPC" || true
  cast rpc eth_getTransactionCount "$FROM" pending --rpc-url "$L2_RPC" || true
  echo ""
  echo "== op-node L1 gap =="
  if cast rpc optimism_syncStatus --rpc-url http://localhost:9545 >/tmp/jovian-sync-status.json 2>/dev/null; then
    jq '{
      l2_number: .unsafe_l2.number,
      l2_l1_origin: .unsafe_l2.l1origin.number,
      current_l1: .current_l1.number,
      l1_origin_gap: (.current_l1.number - .unsafe_l2.l1origin.number)
    }' /tmp/jovian-sync-status.json
  else
    echo "WARN: cannot query op-node sync status at http://localhost:9545"
  fi
  echo ""
  echo "If l1_origin_gap is large, wait for op-node to catch up to L1 head, then rerun this script."
  exit 1
fi

echo "== receipt =="
jq '{
  blockNumber,
  status,
  gasUsed,
  effectiveGasPrice,
  operatorFeeScalar,
  operatorFeeConstant,
  daFootprintGasScalar,
  blobGasUsed
}' "$RECEIPT_FILE"
echo ""

echo "== receipt decimal =="
BLOCK_NUMBER_DEC=$(receipt_hex_to_dec '.blockNumber')
GAS_USED_DEC=$(receipt_hex_to_dec '.gasUsed')
EFFECTIVE_GAS_PRICE_DEC=$(receipt_hex_to_dec '.effectiveGasPrice')
OPERATOR_FEE_SCALAR_DEC=$(receipt_hex_to_dec '.operatorFeeScalar')
OPERATOR_FEE_CONSTANT_DEC=$(receipt_hex_to_dec '.operatorFeeConstant')
DA_FOOTPRINT_GAS_SCALAR_DEC=$(receipt_hex_to_dec '.daFootprintGasScalar')
BLOB_GAS_USED_DEC=$(receipt_hex_to_dec '.blobGasUsed')
printf '{\n'
printf '  "blockNumber": %s,\n' "$BLOCK_NUMBER_DEC"
printf '  "gasUsed": %s,\n' "$GAS_USED_DEC"
printf '  "effectiveGasPrice": %s,\n' "$EFFECTIVE_GAS_PRICE_DEC"
printf '  "operatorFeeScalar": %s,\n' "$OPERATOR_FEE_SCALAR_DEC"
printf '  "operatorFeeConstant": %s,\n' "$OPERATOR_FEE_CONSTANT_DEC"
printf '  "daFootprintGasScalar": %s,\n' "$DA_FOOTPRINT_GAS_SCALAR_DEC"
printf '  "blobGasUsed": %s\n' "$BLOB_GAS_USED_DEC"
printf '}\n'
echo ""

STATUS=$(jq -r '.status' "$RECEIPT_FILE")
if [ "$STATUS" != "0x1" ]; then
  echo "ERROR: transaction failed, status=$STATUS"
  exit 1
fi

EXPECTED_OPERATOR_FEE=""
if jq -e '.operatorFeeScalar != null and .operatorFeeConstant != null' "$RECEIPT_FILE" >/dev/null; then
  GAS_USED="$GAS_USED_DEC"
  OPERATOR_FEE_SCALAR="$OPERATOR_FEE_SCALAR_DEC"
  OPERATOR_FEE_CONSTANT="$OPERATOR_FEE_CONSTANT_DEC"
  EXPECTED_OPERATOR_FEE=$(echo "$GAS_USED * $OPERATOR_FEE_SCALAR * 100 + $OPERATOR_FEE_CONSTANT" | bc)

  echo "== Jovian operator fee calculation =="
  echo "formula: gasUsed * operatorFeeScalar * 100 + operatorFeeConstant"
  echo "gasUsed:             $GAS_USED"
  echo "operatorFeeScalar:   $OPERATOR_FEE_SCALAR"
  echo "operatorFeeConstant: $OPERATOR_FEE_CONSTANT"
  echo "expected fee:        $EXPECTED_OPERATOR_FEE"
  echo ""
fi

echo "== balances after =="
VAULT_AFTER=$(cast balance "$OPERATOR_FEE_VAULT" --rpc-url "$L2_RPC")
echo "operator fee vault balance:  $VAULT_AFTER"
echo ""

echo "== operator fee vault delta =="
DELTA=$(echo "$VAULT_AFTER - $VAULT_BEFORE" | bc)
echo "$DELTA"
echo ""

if [ -n "$EXPECTED_OPERATOR_FEE" ]; then
  if [ "$DELTA" = "$EXPECTED_OPERATOR_FEE" ]; then
    echo "OK: OperatorFeeVault delta matches expected operator fee."
  else
    echo "WARN: OperatorFeeVault delta does not match expected operator fee."
    echo "  expected: $EXPECTED_OPERATOR_FEE"
    echo "  actual:   $DELTA"
  fi
  echo ""
fi

if jq -e '.operatorFeeScalar != null and .operatorFeeConstant != null' "$RECEIPT_FILE" >/dev/null; then
  echo "OK: receipt contains operator fee fields."
else
  echo "WARN: receipt does not contain operator fee fields."
fi

if jq -e '.daFootprintGasScalar != null and .blobGasUsed != null' "$RECEIPT_FILE" >/dev/null; then
  echo "OK: receipt contains Jovian DA footprint fields."
else
  echo "WARN: receipt does not contain Jovian DA footprint fields."
fi

if [ "$DELTA" = "0" ]; then
  echo "WARN: OperatorFeeVault balance did not increase. This can happen if operator fee params are zero."
else
  echo "OK: OperatorFeeVault balance increased."
fi

echo ""
echo "=== Done ==="
