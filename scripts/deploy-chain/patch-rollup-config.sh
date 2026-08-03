#!/bin/bash
#
# Patch the generated rollup.json into a form compatible with the runtime op-node (cgt-jovian/v1.16.5).
# chain-setup.sh invokes this automatically after deployment; it can also run independently.
# Every operation is idempotent and safe to repeat.
#
# Background: deploy-contracts.sh generates rollup.json with the op-node from op-contracts/v2.0.0-beta.3
# because it recognizes the CGT fields in deploy-config. The actual runtime uses cgt-jovian/v1.16.5 op-node,
# whose rollup.json field requirements differ, so the compatibility patches below are required.
#
# Usage:
#   bash scripts/patch-rollup-config.sh [local|remote]
#
# Arguments:
#   local  - Also refresh genesis.l1.hash from the current anvil instance (the hash changes on every rebuild)
#   remote - Skip refreshing genesis.l1.hash (a real L1 deployment already contains the correct hash)
#
# If omitted, the environment is detected automatically from L1_RPC_URL (localhost/127.0.0.1 is treated as local).
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

# Preserve values already set by chain-setup instead of overwriting them from .envrc
# (local uses the localhost L1 and config/<context>). Fall back to .envrc when run standalone.
_CALLER_L1_RPC="${L1_RPC_URL:-}"
_CALLER_DEPLOYMENT_CONFIG_PATH="${DEPLOYMENT_CONFIG_PATH:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"
[ -n "$_CALLER_DEPLOYMENT_CONFIG_PATH" ] && export DEPLOYMENT_CONFIG_PATH="$_CALLER_DEPLOYMENT_CONFIG_PATH"

# Resolve the runtime environment: local | remote
CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  echo "Usage: bash scripts/patch-rollup-config.sh [local|remote]"
  exit 1
fi

ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
if [ ! -f "$ROLLUP_FILE" ]; then
  echo "Error: rollup.json not found at $ROLLUP_FILE" >&2
  echo "       Run bash scripts/chain-setup.sh $CHAIN_ENV first to generate the configuration." >&2
  exit 1
fi

echo "=== Patch rollup.json compatibility ($CHAIN_ENV) ==="
echo "  file: $ROLLUP_FILE"

# Use a temporary file in the same directory to avoid cross-filesystem mv operations and collisions
# when multiple contexts write to /tmp concurrently.
TMP_FILE="$ROLLUP_FILE.tmp"

# ---------- [1/3] genesis.l1.hash: local only ----------
# Every anvil rebuild changes the hash for the same block number. Fetch the hash from the current anvil instance
# using genesis.l1.number recorded in rollup.json and write it back. Remote uses a real L1 whose correct hash
# was written at deployment and must not be changed.
if [ "$CHAIN_ENV" = "local" ]; then
  L1_GENESIS_NUMBER=$(jq -r '.genesis.l1.number' "$ROLLUP_FILE")
  L1_GENESIS_HASH=$(cast block "$L1_GENESIS_NUMBER" --rpc-url "$L1_RPC_URL" --json | jq -r '.hash')
  if [ -z "$L1_GENESIS_HASH" ] || [ "$L1_GENESIS_HASH" = "null" ]; then
    echo "Error: failed to retrieve the hash of L1 block $L1_GENESIS_NUMBER from $L1_RPC_URL" >&2
    exit 1
  fi
  jq --arg hash "$L1_GENESIS_HASH" '.genesis.l1.hash = $hash' \
    "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  echo "  [1/3] genesis.l1.hash -> $L1_GENESIS_HASH (block $L1_GENESIS_NUMBER)"
else
  echo "  [1/3] Skipped refreshing genesis.l1.hash (remote uses the real L1 hash)"
fi

# ---------- [2/3] Remove da_challenge_contract_address ----------
# beta.3 op-node writes this field, but the runtime cgt-jovian/v1.16.5 op-node does not recognize it, so remove it.
jq 'del(.da_challenge_contract_address)' \
  "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
echo "  [2/3] Removed da_challenge_contract_address"

# ---------- [3/3] Ensure chain_op_config exists ----------
# The runtime op-node requires EIP-1559 parameters and may fail to start without them. These values match this chain.
jq '.chain_op_config = {
  "eip1559Elasticity": 6,
  "eip1559Denominator": 50,
  "eip1559DenominatorCanyon": 250
}' "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
echo "  [3/3] Ensured chain_op_config is present"

# Note: this script only patches a newly deployed rollup.json for runtime compatibility; it does not configure fork times.
# The deployment tool produces a pure Fjord baseline. scripts/deploy-chain/activate-fork.sh exclusively schedules
# Granite through Jovian by writing *_time in rollup.json and baking config.*Time into genesis.json.

echo "=== Patch complete ==="
