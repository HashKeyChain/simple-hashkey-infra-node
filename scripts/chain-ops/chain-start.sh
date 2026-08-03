#!/bin/bash
#
# Start all services in one command (optional L1, op-geth, op-node, op-batcher, op-proposer, and op-challenger).
# Run chain-setup.sh first to generate rollup.json and genesis.json.
#
# Usage:
#   bash scripts/chain-start.sh [local|remote]
#
# Arguments:
#   local  - Local: start anvil if L1 is not running, then start op-geth / op-node / batcher / proposer
#   remote - Remote: do not start L1; only start op-geth / op-node / batcher / proposer
#
# If omitted, the environment is detected automatically from L1_RPC_URL.
#
# Optional environment variables:
#   SKIP_BATCHER=1    - Do not start op-batcher
#   SKIP_PROPOSER=1   - Do not start op-proposer
#   SKIP_CHALLENGER=1 - Do not start op-challenger (it starts only when USE_FAULT_PROOFS=true)
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

# Data and log directories
DATA_DIR="${BASE_PATH}/data"
LOG_DIR="${DATA_DIR}/logs"
PID_DIR="${DATA_DIR}/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# Resolve the runtime environment
CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  echo "Usage: bash scripts/chain-start.sh [local|remote]"
  exit 1
fi

# In local mode, use the local anvil instance.
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
fi

# In both local and remote modes, load the patched canonical configuration from config/<context>/.
# The config directory is Git-tracked and patched by the runbook; deployments contains only raw build output.
export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
export OP_GETH_GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
export OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
export DEPLOYMENT_OUTFILE="$DEPLOYMENT_CONFIG_PATH/artifact.json"

# Check that the required configuration has been generated
if [ ! -f "$OP_NODE_ROLLUP_FILE" ] || [ ! -f "$OP_GETH_GENESIS_FILE" ]; then
  echo "Error: rollup.json or genesis.json not found. Run first: bash scripts/chain-setup.sh $CHAIN_ENV"
  echo "  OP_NODE_ROLLUP_FILE=$OP_NODE_ROLLUP_FILE"
  echo "  OP_GETH_GENESIS_FILE=$OP_GETH_GENESIS_FILE"
  exit 1
fi

echo "=== Chain Start (all services) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo ""

# ---------- L1 (local only) ----------
if [ "$CHAIN_ENV" = "local" ]; then
  if ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; then
    echo "Starting anvil with block time ${L1_BLOCK_TIME}s..."
    # Container removal with --rm is asynchronous: after the previous stop returns, the old container may
    # still exist, causing run to fail with a name conflict. Force-remove it first and wait until it is gone.
    docker rm -f anvil-chain >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [ -z "$(docker ps -aq -f name='^anvil-chain$')" ] && break
      sleep 0.5
    done
    docker run --rm -d -p 8545:8545 --name anvil-chain \
      --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 \
      --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 \
      --slots-in-an-epoch=1 --block-time $L1_BLOCK_TIME
    echo "Waiting for anvil..."
    for i in $(seq 1 15); do
      cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null && break
      sleep 1
    done
    echo "Anvil started."
  else
    echo "L1 already running at $L1_RPC_URL"
  fi
fi

# ---------- JWT (shared by op-geth and op-node) ----------
export OP_GETH_DATA_PATH="${DATA_DIR}/op-geth"
mkdir -p "$OP_GETH_DATA_PATH"
JWT_FILE="${OP_GETH_DATA_PATH}/jwt.txt"
if [ ! -f "$JWT_FILE" ]; then
  openssl rand -hex 32 > "$JWT_FILE"
  echo "Generated JWT at $JWT_FILE"
fi

# activate-fork.sh bakes the fork schedule into genesis.json when activating a fork: sync_fork writes rollup,
# while bake-genesis-forks.sh bakes genesis from .envrc FORK_*_TIME values shared by geth/reth.
# chain-start does not bake the schedule, so ordinary restarts do not change it.

# ---------- op-geth init (first database creation only) ----------
# Ordinary restarts do not re-init. activate-fork.sh handles re-init when activating a fork (changing the schedule).
# geth init is nondestructive for an existing datadir with a matching genesis hash: it only updates the fork schedule
# and preserves chain data.
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "Initializing op-geth datadir (fresh)..."
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$OP_GETH_GENESIS_FILE"
fi

# ---------- Pass orchestration-layer overrides to run-op-* (caller values take precedence; scripts fall back to .envrc) ----------
export SAFEDB_PATH="${DATA_DIR}/op-node/safedb"
mkdir -p "$(dirname "$SAFEDB_PATH")"
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export _CALLER_OP_GETH_DATA_PATH="$OP_GETH_DATA_PATH"
export _CALLER_JWT_FILE="$JWT_FILE"
export _CALLER_OP_NODE_ROLLUP_FILE="$OP_NODE_ROLLUP_FILE"
export _CALLER_DEPLOYMENT_OUTFILE="$DEPLOYMENT_OUTFILE"
export _CALLER_SAFEDB_PATH="$SAFEDB_PATH"

# Hardfork times are baked into genesis.json by activate-fork.sh from .envrc FORK_*_TIME values.
# Geth reads genesis instead of using --override.*, while op-node continues reading rollup.json.
# All three derive from the same source and remain consistent.

# ---------- Start op-geth (see run-op-geth.sh for component flags) ----------
echo "Starting op-geth..."
nohup bash "$SCRIPT_DIR/run-op-geth.sh" >> "$LOG_DIR/op-geth.log" 2>&1 &
echo $! > "$PID_DIR/op-geth.pid"
echo "  op-geth started (pid $(cat $PID_DIR/op-geth.pid)), log: $LOG_DIR/op-geth.log"

# Wait for the Engine RPC to become ready
echo "Waiting for op-geth engine..."
for i in $(seq 1 30); do
  if curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8645 &>/dev/null; then
    break
  fi
  sleep 1
done
sleep 2

# ---------- Flashblocks sequencer side (FLASHBLOCKS_MODE != off; start before op-node) ----------
# See scripts/flashblocks/start-sequencer-side.sh for orchestration; source it to share this script's scope.
# Start only op-rbuilder and rollup-boost. Because rollup-boost drives op-rbuilder, do not start the builder op-node here.
# It is used only to pre-warm a cold sync while in off mode; see scripts/flashblocks/switch-to-flashblocks-dryrun.sh.
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  source "$BASE_PATH/scripts/flashblocks/start-sequencer-side.sh"
fi

# ---------- Start op-node (see run-op-node.sh for component flags) ----------
echo "Starting op-node..."
nohup bash "$SCRIPT_DIR/run-op-node.sh" >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat $PID_DIR/op-node.pid)), log: $LOG_DIR/op-node.log"

sleep 3

# ---------- Start op-batcher (optional; see run-op-batcher.sh for component flags) ----------
if [ "${SKIP_BATCHER:-0}" != "1" ]; then
  echo "Starting op-batcher..."
  nohup bash "$SCRIPT_DIR/run-op-batcher.sh" >> "$LOG_DIR/op-batcher.log" 2>&1 &
  echo $! > "$PID_DIR/op-batcher.pid"
  echo "  op-batcher started (pid $(cat $PID_DIR/op-batcher.pid)), log: $LOG_DIR/op-batcher.log"
fi

# ---------- Start op-proposer (optional; see run-op-proposer.sh for component flags) ----------
# Note: deployment seeds AnchorStateRegistry with a nonzero faultGameGenesisOutputRoot (0xdead...),
#       so the proposer can create its first game without separate anchor initialization.
if [ "${SKIP_PROPOSER:-0}" != "1" ]; then
  echo "Starting op-proposer..."
  nohup bash "$SCRIPT_DIR/run-op-proposer.sh" >> "$LOG_DIR/op-proposer.log" 2>&1 &
  echo $! > "$PID_DIR/op-proposer.pid"
  echo "  op-proposer started (pid $(cat $PID_DIR/op-proposer.pid)), log: $LOG_DIR/op-proposer.log"
fi

# ---------- Start op-challenger (FP mode only; see run-op-challenger.sh for component flags) ----------
# The challenger requires a ready chain and built fault-proof binaries (bin/cannon, bin/op-program, bin/prestate.json).
# It runs in the foreground (run-op-challenger.sh ends with exec). A failed preflight exits and writes to the log
# without affecting other components.
if [ "${USE_FAULT_PROOFS:-false}" = "true" ] && [ "${SKIP_CHALLENGER:-0}" != "1" ]; then
  sleep 3
  echo "Starting op-challenger..."
  nohup bash "$SCRIPT_DIR/run-op-challenger.sh" >> "$LOG_DIR/op-challenger.log" 2>&1 &
  echo $! > "$PID_DIR/op-challenger.pid"
  echo "  op-challenger started (pid $(cat $PID_DIR/op-challenger.pid)), log: $LOG_DIR/op-challenger.log"
fi

# ---------- Flashblocks user side (dry_run/enabled; ready before the live mode switch) ----------
# See scripts/flashblocks/start-user-side.sh for orchestration; source it to share this script's scope.
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  source "$BASE_PATH/scripts/flashblocks/start-user-side.sh"
fi

echo ""
echo "=== All services started ==="
echo "  L2 RPC:      $L2_RPC_URL"
echo "  Rollup RPC:  $OP_NODE_RPC_URL"
echo "  PIDs:        $PID_DIR/*.pid"
echo "  Logs:        $LOG_DIR/*.log"
echo ""
echo "Stop all: bash scripts/chain-stop.sh"
