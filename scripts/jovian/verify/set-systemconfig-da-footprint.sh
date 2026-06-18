#!/usr/bin/env bash
set -euo pipefail

# Set SystemConfig daFootprintGasScalar on an external/remote L1.
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
SET_DA_FOOTPRINT_GAS_SCALAR="${SET_DA_FOOTPRINT_GAS_SCALAR:?missing SET_DA_FOOTPRINT_GAS_SCALAR in verify.env}"

if ! [[ "$SET_DA_FOOTPRINT_GAS_SCALAR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: SET_DA_FOOTPRINT_GAS_SCALAR must be a decimal uint16 value."
  exit 1
fi

if [ "$SET_DA_FOOTPRINT_GAS_SCALAR" -gt 65535 ]; then
  echo "ERROR: SET_DA_FOOTPRINT_GAS_SCALAR exceeds uint16 max."
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
echo "  Set SystemConfig DA Footprint"
echo "============================================"
echo "L1_RPC:                $L1_RPC"
echo "SystemConfigProxy:     $SYSTEM_CONFIG_PROXY"
echo "signer:                $SIGNER"
echo "daFootprintGasScalar:  $SET_DA_FOOTPRINT_GAS_SCALAR"
echo ""

echo "== before =="
cast call "$SYSTEM_CONFIG_PROXY" "daFootprintGasScalar()(uint16)" --rpc-url "$L1_RPC"
echo ""

if [ "$SET_DA_FOOTPRINT_GAS_SCALAR" = "0" ]; then
  echo "NOTE: L1 value 0 maps to the op-node default value on L2 derivation."
  echo ""
fi

echo "== send transaction =="
RECEIPT_JSON=$(cast send "$SYSTEM_CONFIG_PROXY" \
  "setDAFootprintGasScalar(uint16)" \
  "$SET_DA_FOOTPRINT_GAS_SCALAR" \
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
cast call "$SYSTEM_CONFIG_PROXY" "daFootprintGasScalar()(uint16)" --rpc-url "$L1_RPC"
echo ""
echo "OK: SystemConfig daFootprintGasScalar set. Wait for derivation, then run verify-jovian.sh."
