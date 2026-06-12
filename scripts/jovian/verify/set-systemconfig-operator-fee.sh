#!/usr/bin/env bash
set -euo pipefail

# Set SystemConfig operator fee params on an external/private L1.
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
SET_OPERATOR_FEE_SCALAR="${SET_OPERATOR_FEE_SCALAR:?missing SET_OPERATOR_FEE_SCALAR in verify.env}"
SET_OPERATOR_FEE_CONSTANT="${SET_OPERATOR_FEE_CONSTANT:?missing SET_OPERATOR_FEE_CONSTANT in verify.env}"

if ! [[ "$SET_OPERATOR_FEE_SCALAR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SET_OPERATOR_FEE_SCALAR must be a decimal uint32 value."
  exit 1
fi

if ! [[ "$SET_OPERATOR_FEE_CONSTANT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SET_OPERATOR_FEE_CONSTANT must be a decimal uint64 value in wei."
  exit 1
fi

if [ "$SET_OPERATOR_FEE_SCALAR" -gt 4294967295 ]; then
  echo "ERROR: SET_OPERATOR_FEE_SCALAR exceeds uint32 max."
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
echo "  Set SystemConfig Operator Fee"
echo "============================================"
echo "L1_RPC:             $L1_RPC"
echo "SystemConfigProxy:  $SYSTEM_CONFIG_PROXY"
echo "signer:             $SIGNER"
echo "operatorFeeScalar:  $SET_OPERATOR_FEE_SCALAR"
echo "operatorFeeConstant: $SET_OPERATOR_FEE_CONSTANT"
echo ""

echo "== before =="
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeScalar()(uint32)" --rpc-url "$L1_RPC"
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeConstant()(uint64)" --rpc-url "$L1_RPC"
echo ""

echo "== send transaction =="
RECEIPT_JSON=$(cast send "$SYSTEM_CONFIG_PROXY" \
  "setOperatorFeeScalars(uint32,uint64)" \
  "$SET_OPERATOR_FEE_SCALAR" \
  "$SET_OPERATOR_FEE_CONSTANT" \
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
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeScalar()(uint32)" --rpc-url "$L1_RPC"
cast call "$SYSTEM_CONFIG_PROXY" "operatorFeeConstant()(uint64)" --rpc-url "$L1_RPC"
echo ""
echo "OK: SystemConfig operator fee params set. Wait for derivation, then run verify-jovian.sh."
