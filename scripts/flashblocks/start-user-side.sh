#!/bin/bash
#
# Start the user-facing side of Flashblocks (sourced by chain-start.sh when
# FLASHBLOCKS_MODE is dry_run or enabled). It runs via source and shares chain-start.sh's variable
# scope (BASE_PATH/DATA_DIR/LOG_DIR/PID_DIR and the _CALLER_* values exported by
# start-sequencer-side.sh).
#
# Responsibilities (dry_run and enabled; local topology matches production and includes
# the proxy). In dry_run this is a shadow preview and must not receive production traffic:
#   - flashblocks-websocket-proxy: broadcasts the Flashblocks stream externally;
#   - op-reth (Flashblocks-aware RPC replica): serves RPC with pending Flashblocks;
#   - the verifier op-node for this op-reth instance: drives op-reth synchronization.
#
# Note: this script does not run set -e or exit; it inherits the caller's execution
# semantics (chain-start.sh uses set -e).

FB_DIR="$BASE_PATH/scripts/flashblocks"

echo "Starting flashblocks ws-proxy..."
nohup bash "$FB_DIR/run-flashblocks-proxy.sh" >> "$LOG_DIR/fb-proxy.log" 2>&1 &
echo $! > "$PID_DIR/fb-proxy.pid"; sleep 1

echo "Starting flashblocks-aware RPC (op-reth)..."
nohup bash "$FB_DIR/run-flashblocks-rpc-op-reth.sh" >> "$LOG_DIR/fb-rpc-reth.log" 2>&1 &
echo $! > "$PID_DIR/fb-rpc-reth.pid"; sleep 2

echo "Starting flashblocks RPC verifier op-node..."
nohup bash "$FB_DIR/run-flashblocks-rpc-op-node.sh" >> "$LOG_DIR/fb-rpc-opnode.log" 2>&1 &
echo $! > "$PID_DIR/fb-rpc-opnode.pid"
