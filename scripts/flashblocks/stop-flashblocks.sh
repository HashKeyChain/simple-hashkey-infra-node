#!/bin/bash
#
# Stop all Flashblocks components. This script is sourced by chain-stop.sh, which must
# define stop_pid/stop_matching_processes and set PID_DIR, DATA_DIR, and the related
# port variables. Run it before stopping the core op-node/op-geth processes, in reverse
# startup order.
#
# Components: fb-rpc-opnode, fb-rpc-reth, fb-proxy, rollup-boost,
#             op-rbuilder-opnode, op-rbuilder.

# First stop processes recorded in PID files by the current chain-start run.
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder-opnode op-rbuilder; do
  pid_file="$PID_DIR/${name}.pid"
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    stop_pid "$name" "$pid"
    rm -f "$pid_file"
  fi
done

# Then remove residual processes whose PID files were overwritten by matching their
# command lines (needles correspond to the actual ps command lines).
stop_matching_processes "fb-rpc-opnode"      "op-node "                      "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "op-rbuilder-opnode" "op-node "                      "--rpc.port=${RBUILDER_OPNODE_PORT:-9565}"
stop_matching_processes "fb-rpc-reth"        "op-reth "                      "$DATA_DIR/op-reth"
stop_matching_processes "fb-proxy"           "flashblocks-websocket-proxy "  "0.0.0.0:${FB_PROXY_PORT:-1113}"
stop_matching_processes "op-rbuilder"        "op-rbuilder "                  "$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost"       "rollup-boost "                 "--rpc-port ${RB_ENGINE_PORT:-8551}"
