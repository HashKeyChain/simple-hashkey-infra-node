#!/bin/bash
#
# Generate rollup.json and genesis.json in one command by deploying L1 contracts and generating the L2 configuration.
# This generates configuration only; it does not start the L2 nodes.
#
# Usage:
#   bash scripts/chain-setup.sh [local|remote]
#
# Arguments:
#   local  - Local environment: start anvil automatically if L1 is not running, then deploy contracts and generate configuration
#   remote - Remote environment: use L1_RPC_URL from .envrc to deploy contracts and generate configuration directly
#
# If omitted, the environment is detected automatically from L1_RPC_URL (localhost/127.0.0.1 is treated as local).
#
# Generated file locations:
#   - $DEPLOYMENT_CONFIG_PATH/rollup.json
#   - $DEPLOYMENT_CONFIG_PATH/genesis.json
#   - $DEPLOYMENT_CONFIG_PATH/artifact.json
#   - $DEPLOYMENT_CONFIG_PATH/state-dump-latest.json
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

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
  echo "Usage: bash scripts/chain-setup.sh [local|remote]"
  exit 1
fi

# In local mode, use the local anvil instance; the generated-file directory still follows DEPLOYMENT_CONTEXT from .envrc.
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
fi

echo "=== Chain Setup (genesis.json + rollup.json) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "DEPLOYMENT_CONFIG_PATH=$DEPLOYMENT_CONFIG_PATH"
echo ""

# Wait for the L1 RPC to become ready
wait_l1() {
  local max=30
  local n=0
  while ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; do
    n=$((n + 1))
    if [ $n -ge $max ]; then
      echo "Error: L1 RPC not ready at $L1_RPC_URL after ${max}s"
      exit 1
    fi
    echo "  Waiting for L1... ($n/$max)"
    sleep 1
  done
  echo "  L1 RPC ready."
}

ANVIL_PID=""

if [ "$CHAIN_ENV" = "local" ]; then
  if ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; then
    echo "L1 not running. Starting anvil in background with block time ${L1_BLOCK_TIME}s..."
    # Container removal with --rm is asynchronous: after chain-reset's docker stop returns, the old container
    # may still exist, causing run to fail with a name conflict. Force-remove it first and wait until it is gone.
    docker rm -f anvil-chain >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [ -z "$(docker ps -aq -f name='^anvil-chain$')" ] && break
      sleep 0.5
    done
    docker run --rm -d -p 8545:8545 --name anvil-chain \
      --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 \
      --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 \
      --slots-in-an-epoch=1 --block-time $L1_BLOCK_TIME
    ANVIL_PID="docker"
    wait_l1
  else
    echo "L1 already running at $L1_RPC_URL"
  fi
else
  # Remote: check L1 availability directly.
  echo "Checking L1 RPC..."
  wait_l1
fi

# Local mode: fund deployment and operator accounts.
# Anvil pre-funds only its 20 derived accounts, while DEPLOY/GS_* in .envrc are custom accounts whose balances
# are zero on a fresh anvil instance. Without funding, subsequent CGT/contract deployment fails due to insufficient gas.
# Change balances directly on local anvil without transaction confirmation to avoid delays from L1_BLOCK_TIME.
if [ "$CHAIN_ENV" = "local" ]; then
  echo "Funding deploy/operator accounts..."
  for addr in "$DEPLOY_ADDRESS" "$GS_ADMIN_ADDRESS" "$GS_BATCHER_ADDRESS" "$GS_PROPOSER_ADDRESS" "$GS_SEQUENCER_ADDRESS"; do
    [ -z "$addr" ] && continue
    cast rpc anvil_setBalance "$addr" 0x3635c9adc5dea00000 --rpc-url "$L1_RPC_URL" >/dev/null 2>&1 \
      && echo "  funded $addr" || echo "  WARN: fund $addr failed"
  done

  # Local anvil does not include Multicall3 by default, but op-challenger depends on it for batch reads
  # and reports "failed to fetch batch: Resource not found" when it is absent. Before deploying contracts,
  # use the official keyless presigned transaction to deploy it at the canonical address, making it available
  # to all subsequent blocks. This operation is idempotent.
  echo "Deploying Multicall3..."
  bash "$SCRIPT_DIR/deploy-multicall3.sh"
fi

echo ""
echo "Running contract deployment and generating genesis/rollup config..."
bash "$SCRIPT_DIR/deploy-contracts.sh"

# Patch the generated rollup.json for compatibility with the runtime op-node (cgt-jovian/v1.16.5):
# remove da_challenge_contract_address, add chain_op_config, and refresh genesis.l1.hash in local mode.
# This allows chain-start to run immediately after setup without manual patching. The operation is idempotent.
echo ""
echo "Patching rollup.json compatibility..."
bash "$SCRIPT_DIR/patch-rollup-config.sh" "$CHAIN_ENV"

# If this script started anvil, it can remain running for the subsequent chain-start or be stopped manually.
if [ -n "$ANVIL_PID" ]; then
  echo ""
  echo "Anvil is still running in container 'anvil-chain'. Stop with: docker stop anvil-chain"
fi

echo ""
echo "=== Setup complete ==="
echo "Generated files:"
echo "  rollup.json  -> $DEPLOYMENT_CONFIG_PATH/rollup.json"
echo "  genesis.json -> $DEPLOYMENT_CONFIG_PATH/genesis.json"
echo "  artifact.json -> $DEPLOYMENT_CONFIG_PATH/artifact.json"
echo ""
echo "Next: run 'bash scripts/chain-start.sh $CHAIN_ENV' to start all services."
