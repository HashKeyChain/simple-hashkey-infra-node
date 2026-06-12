#!/usr/bin/env bash
set -euo pipefail

# Set SystemConfig minBaseFee on an external/private L1.
# Fill scripts/jovian/verify/verify.env before running.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L1_RPC="${L1_RPC:?missing L1_RPC in verify.env}"
SYSTEM_CONFIG_PROXY="${SYSTEM_CONFIG_PROXY:?missing SYSTEM_CONFIG_PROXY in verify.env}"
SYSTEM_CONFIG_PRIVATE_KEY="${SYSTEM_CONFIG_PRIVATE_KEY:?missing SYSTEM_CONFIG_PRIVATE_KEY in verify.env}"
SET_MIN_BASE_FEE="${SET_MIN_BASE_FEE:?missing SET_MIN_BASE_FEE in verify.env}"

if ! [[ "$SET_MIN_BASE_FEE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SET_MIN_BASE_FEE must be a decimal uint64 value in wei."
  exit 1
fi

SIGNER=$(cast wallet address --private-key "$SYSTEM_CONFIG_PRIVATE_KEY")
OWNER=$(cast call "$SYSTEM_CONFIG_PROXY" "owner()(address)" --rpc-url "$L1_RPC")

if [ "$(echo "$SIGNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" ]; then
  echo "ERROR: SYSTEM_CONFIG_PRIVATE_KEY is not the direct SystemConfig owner."
  echo "signer: $SIGNER"
  echo "owner:  $OWNER"
  exit 1
fi

echo "============================================"
echo "  Set SystemConfig minBaseFee"
echo "============================================"
echo "L1_RPC:             $L1_RPC"
echo "SystemConfigProxy:  $SYSTEM_CONFIG_PROXY"
echo "signer:             $SIGNER"
echo "minBaseFee:         $SET_MIN_BASE_FEE wei"
echo ""

echo "== before =="
cast call "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)" --rpc-url "$L1_RPC"
echo ""

echo "== send transaction =="
RECEIPT_JSON=$(cast send "$SYSTEM_CONFIG_PROXY" \
  "setMinBaseFee(uint64)" \
  "$SET_MIN_BASE_FEE" \
  --private-key "$SYSTEM_CONFIG_PRIVATE_KEY" \
  --rpc-url "$L1_RPC" \
  --json)
echo "$RECEIPT_JSON" | jq '{transactionHash,status,blockNumber,gasUsed}'

STATUS=$(echo "$RECEIPT_JSON" | jq -r '.status')
if [ "$STATUS" != "0x1" ] && [ "$STATUS" != "1" ]; then
  echo "ERROR: transaction failed."
  exit 1
fi
echo ""

echo "== after =="
cast call "$SYSTEM_CONFIG_PROXY" "minBaseFee()(uint64)" --rpc-url "$L1_RPC"
echo ""
echo "OK: SystemConfig minBaseFee set. Wait for derivation, then run verify-jovian.sh."
