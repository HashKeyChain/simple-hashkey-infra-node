#!/bin/bash
#
# Start the sequencer side of Flashblocks (sourced by chain-start.sh when
# FLASHBLOCKS_MODE != off). It runs via source and shares chain-start.sh's variable
# scope (BASE_PATH/DATA_DIR/LOG_DIR/PID_DIR/FLASHBLOCKS_MODE, and others).
#
# Responsibilities (must start before the primary op-node):
#   - start op-rbuilder (reth-based Flashblocks builder, EL);
#   - start rollup-boost (Engine API proxy, initially mode=$FLASHBLOCKS_MODE, with
#     live switching available through the debug API).
#
# Topology constraint: in dry_run/enabled mode, op-rbuilder's Engine
# (auth RPC=RBUILDER_AUTHRPC_PORT) is driven by rollup-boost. Its --builder-url points
# to op-rbuilder and forwards Engine calls from the primary op-node. Therefore, this
# script does not start the builder op-node: it connects to the same auth RPC and would
# compete with rollup-boost for control of op-rbuilder. The builder op-node is used only
# for dedicated synchronization in off mode, deriving from L1 and following gossip to
# warm a cold op-rbuilder; see steps [2]/[3] in switch-to-flashblocks-dryrun.sh. After
# catching up and fully restarting into this topology, rollup-boost takes over.
#
# Phase responsibility: this script only starts the Flashblocks topology. Dedicated
# synchronization in the off phase ensures op-rbuilder is caught up, so this script does
# not wait for synchronization again. run-op-node.sh generates and maintains the primary
# op-node's CL P2P identity.
#
# Note: this script does not run set -e or exit; it inherits the caller's execution
# semantics (chain-start.sh uses set -e).

FB_DIR="$BASE_PATH/scripts/flashblocks"

# The reth-based components share genesis.json with geth (forks are embedded by
# activate-fork.sh), so no separate chain specification is needed.
export _CALLER_OP_GETH_GENESIS_FILE="$OP_GETH_GENESIS_FILE"

echo "Starting op-rbuilder..."
nohup bash "$FB_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder.pid"
echo "  op-rbuilder started (pid $(cat $PID_DIR/op-rbuilder.pid)), log: $LOG_DIR/op-rbuilder.log"
sleep 3

echo "Starting rollup-boost (mode=$FLASHBLOCKS_MODE)..."
nohup bash "$FB_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
echo $! > "$PID_DIR/rollup-boost.pid"
echo "  rollup-boost started (pid $(cat $PID_DIR/rollup-boost.pid)), log: $LOG_DIR/rollup-boost.log"
sleep 2
