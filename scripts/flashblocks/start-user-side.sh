#!/bin/bash
#
# Flashblocks 用户面启动（由 chain-start.sh 在 FLASHBLOCKS_MODE = enabled 时 `source`）。
# 以 source 方式运行：共享 chain-start.sh 的变量作用域（BASE_PATH/DATA_DIR/LOG_DIR/PID_DIR 及
# start-sequencer-side.sh 已导出的 _CALLER_*）。
#
# 职责（仅 enabled；本地=生产同构，proxy 不省略）：
#   - flashblocks-websocket-proxy：对外广播 flashblocks 流
#   - op-reth（flashblocks-aware RPC 副本）：对外提供带 pending flashblocks 的 RPC
#   - 该 op-reth 的校验 op-node：驱动 op-reth 同步
#
# 注：本脚本不做 set -e / exit；沿用调用方（chain-start.sh set -e）的执行语义。

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
