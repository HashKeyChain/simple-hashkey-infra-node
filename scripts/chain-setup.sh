#!/bin/bash
#
# Generate rollup.json and genesis.json (deploy L1 contracts and produce L2 config).
# Does not start L2 services — only generates config files.
# Initial deployment uses L2OutputOracle (USE_FAULT_PROOFS=false).
# Contract version is set by OP_CONTRACTS_REF in .envrc (e.g. op-contracts/v2.0.0-beta.2).
# To upgrade to PermissionedDisputeGame, see: scripts/upgrade-to-fault-proofs.sh
#
# Usage:
#   bash scripts/chain-setup.sh [local|server]
#
# Args:
#   local  - start anvil if not running, deploy contracts, generate config
#   server - use L1_RPC_URL from .envrc, deploy contracts, generate config
#
# Auto-detects mode from L1_RPC_URL if no argument given.
#
# Output files:
#   - $DEPLOYMENT_CONFIG_PATH/rollup.json
#   - $DEPLOYMENT_CONFIG_PATH/genesis.json
#   - $DEPLOYMENT_CONFIG_PATH/artifact.json
#   - $DEPLOYMENT_CONFIG_PATH/state-dump-latest.json
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

# Detect environment
CHAIN_ENV="${1:-}"

if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "server" ]; then
  echo "Usage: bash scripts/chain-setup.sh [local|server]"
  exit 1
fi

# local mode: use local anvil, output config to config/local
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONTEXT=local
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/local"
fi

echo "=== Chain Setup (genesis.json + rollup.json) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "DEPLOYMENT_CONFIG_PATH=$DEPLOYMENT_CONFIG_PATH"
echo ""

# Wait for L1 RPC
_l1_ok() {
  curl -sf -X POST -H "Content-Type: application/json" \
    --connect-timeout 1 --max-time 2 \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L1_RPC_URL" >/dev/null 2>&1
}
wait_l1() {
  for i in $(seq 1 10); do
    _l1_ok && { echo "  L1 RPC ready."; return 0; }
    sleep 0.5
  done
  echo "Error: L1 RPC not ready at $L1_RPC_URL after 5s"
  exit 1
}

ANVIL_PID=""

if [ "$CHAIN_ENV" = "local" ]; then
  if curl -sf -X POST -H "Content-Type: application/json" --connect-timeout 1 --max-time 2 \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L1_RPC_URL" >/dev/null 2>&1; then
    echo "L1 already running at $L1_RPC_URL"
  else
    echo "L1 not running. Starting anvil (native)..."
    ANVIL_LOG="${DATA_DIR:-$BASE_PATH/data}/logs/anvil.log"
    mkdir -p "$(dirname "$ANVIL_LOG")"
    nohup anvil --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 --port=8545 \
      --slots-in-an-epoch=1 --block-time ${L1_BLOCK_TIME:-12} >> "$ANVIL_LOG" 2>&1 &
    ANVIL_PID=$!
    echo $ANVIL_PID > "${DATA_DIR:-$BASE_PATH/data}/pids/anvil.pid"
    wait_l1
  fi
else
  # server: verify L1 is reachable
  echo "Checking L1 RPC..."
  wait_l1
fi

echo ""
echo "Running contract deployment and generating genesis/rollup config..."
export CHAIN_ENV
bash "$SCRIPT_DIR/deploy-contracts.sh"

if [ -n "$ANVIL_PID" ]; then
  echo ""
  echo "Anvil is still running (pid $ANVIL_PID). It will be reused by chain-start."
fi

echo ""
echo "=== Setup complete ==="
echo "Generated files:"
echo "  rollup.json  -> $DEPLOYMENT_CONFIG_PATH/rollup.json"
echo "  genesis.json -> $DEPLOYMENT_CONFIG_PATH/genesis.json"
echo "  artifact.json -> $DEPLOYMENT_CONFIG_PATH/artifact.json"
echo ""
echo "Next: run 'bash scripts/chain-start.sh $CHAIN_ENV' to start all services."
