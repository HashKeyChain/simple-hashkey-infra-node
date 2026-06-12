#!/usr/bin/env bash
set -euo pipefail

# Set SystemConfig EIP-1559 params on an external/private L1.
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
SET_EIP1559_DENOMINATOR="${SET_EIP1559_DENOMINATOR:?missing SET_EIP1559_DENOMINATOR in verify.env}"
SET_EIP1559_ELASTICITY="${SET_EIP1559_ELASTICITY:?missing SET_EIP1559_ELASTICITY in verify.env}"

if ! [[ "$SET_EIP1559_DENOMINATOR" =~ ^[0-9]+$ ]] || [ "$SET_EIP1559_DENOMINATOR" = "0" ]; then
  echo "ERROR: SET_EIP1559_DENOMINATOR must be a non-zero decimal uint32."
  exit 1
fi

if ! [[ "$SET_EIP1559_ELASTICITY" =~ ^[0-9]+$ ]] || [ "$SET_EIP1559_ELASTICITY" = "0" ]; then
  echo "ERROR: SET_EIP1559_ELASTICITY must be a non-zero decimal uint32."
  exit 1
fi

if [ "$SET_EIP1559_DENOMINATOR" -gt 4294967295 ] || [ "$SET_EIP1559_ELASTICITY" -gt 4294967295 ]; then
  echo "ERROR: EIP-1559 params exceed uint32 max."
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
echo "  Set SystemConfig EIP-1559 Params"
echo "============================================"
echo "L1_RPC:             $L1_RPC"
echo "SystemConfigProxy:  $SYSTEM_CONFIG_PROXY"
echo "signer:             $SIGNER"
echo "denominator:        $SET_EIP1559_DENOMINATOR"
echo "elasticity:         $SET_EIP1559_ELASTICITY"
echo ""

echo "== before =="
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Denominator()(uint32)" --rpc-url "$L1_RPC"
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Elasticity()(uint32)" --rpc-url "$L1_RPC"
echo ""

echo "== send transaction =="
RECEIPT_JSON=$(cast send "$SYSTEM_CONFIG_PROXY" \
  "setEIP1559Params(uint32,uint32)" \
  "$SET_EIP1559_DENOMINATOR" \
  "$SET_EIP1559_ELASTICITY" \
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
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Denominator()(uint32)" --rpc-url "$L1_RPC"
cast call "$SYSTEM_CONFIG_PROXY" "eip1559Elasticity()(uint32)" --rpc-url "$L1_RPC"
echo ""
echo "OK: SystemConfig EIP-1559 params set. Wait for derivation, then run verify-holocene.sh or verify-jovian.sh."
