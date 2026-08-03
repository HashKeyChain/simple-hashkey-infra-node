#!/bin/bash
#
# Deploy Multicall3 on local anvil at the canonical address 0xcA11bde05977b3631167028862bE2a173976CA11.
#
# Why it is needed: the op-challenger/op-service batching library uses Multicall3 aggregate3 to batch reads
# from DisputeGameFactory (gameCount, large preimage claims, and so on). Local anvil does not include Multicall3
# by default; without it, the challenger repeatedly reports "failed to fetch batch: Resource not found".
#
# Deployment method: the official keyless presigned transaction (Nick's method; see mds1/multicall).
# The transaction has no chainId (pre-EIP-155) and is broadcast by a fixed deployer (0x05f32...) with nonce 0,
# so it deploys to the same canonical address on every chain. With gasLimit=1,000,000 and gasPrice=100 gwei,
# the deployer must receive at least 0.1 ETH before deployment. The raw 3.9 KB hex transaction is stored in
# multicall3-presigned.tx in this directory to avoid embedding it inline.
#
# Idempotent: skip deployment if Multicall3 already exists. For local anvil only; real chains already have Multicall3.
#
# Usage:
#   bash scripts/deploy-multicall3.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

# Preserve values already set by chain-setup instead of overwriting them from .envrc (local uses the localhost L1).
_CALLER_L1_RPC="${L1_RPC_URL:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"

MC3_ADDR=0xcA11bde05977b3631167028862bE2a173976CA11
MC3_DEPLOYER=0x05f32b3cc3888453ff71b01135b34ff8e41263f2
RAW_TX_FILE="$SCRIPT_DIR/multicall3-presigned.tx"

[ -f "$RAW_TX_FILE" ] || { echo "ERROR: missing presigned transaction file $RAW_TX_FILE" >&2; exit 1; }
MC3_RAW_TX=$(tr -d ' \n\r\t' < "$RAW_TX_FILE")

# Idempotent: skip if already deployed
CODE=$(cast code "$MC3_ADDR" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo 0x)
if [ "${#CODE}" -gt 3 ]; then
  echo "Multicall3 already exists at ${MC3_ADDR} (code length ${#CODE}); skipping deployment."
  exit 0
fi

echo "Deploying Multicall3 to $MC3_ADDR (keyless presigned tx)..."

# Fund the keyless deployer with enough gas by changing its balance directly on local anvil,
# avoiding block-time delays. 1 ETH is sufficient.
cast rpc anvil_setBalance "$MC3_DEPLOYER" 0xde0b6b3a7640000 --rpc-url "$L1_RPC_URL" >/dev/null

# Broadcast the presigned transaction and wait for inclusion.
cast publish "$MC3_RAW_TX" --rpc-url "$L1_RPC_URL" >/dev/null

# Verify
CODE=$(cast code "$MC3_ADDR" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo 0x)
if [ "${#CODE}" -gt 3 ]; then
  echo "Multicall3 deployed successfully (code length ${#CODE})."
else
  echo "ERROR: Multicall3 deployment failed; $MC3_ADDR still has no code." >&2
  echo "       Check whether the anvil base fee exceeds 100 gwei or the deployer balance is insufficient." >&2
  exit 1
fi
