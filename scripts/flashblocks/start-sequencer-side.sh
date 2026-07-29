#!/bin/bash
#
# Flashblocks 序列器侧启动（由 chain-start.sh 在 FLASHBLOCKS_MODE != off 时 `source`）。
# 以 source 方式运行：共享 chain-start.sh 的变量作用域（BASE_PATH/DATA_DIR/LOG_DIR/PID_DIR/
# FLASHBLOCKS_MODE 等）。
#
# 职责（必须在主 op-node 之前起）：
#   - 起 op-rbuilder（reth 系 flashblocks builder，EL）
#   - 起 rollup-boost（Engine API 代理，mode=$FLASHBLOCKS_MODE 为初值，可经 debug API 热切）
#
# 拓扑约束：dry_run/enabled 态下 op-rbuilder 的 Engine（auth RPC=RBUILDER_AUTHRPC_PORT）由
# rollup-boost 驱动（rollup-boost --builder-url 指向它，转发主 op-node 的 Engine 调用）。因此
# 这里【不起 builder op-node】——builder op-node 也连同一个 auth RPC，二者并存会抢驱动 op-rbuilder。
# builder op-node 只用于 off 阶段的“专门同步”：给冷启的 op-rbuilder 从 L1 派生 + gossip 追同步，
# 见 switch-to-flashblocks-dryrun.sh [2]/[3]。追平后 fullrestart 到这里，改由 rollup-boost 驱动。
#
# 相位职责：本脚本只“拉起 flashblocks 拓扑”。op-rbuilder 追平由 off 阶段的专门同步步骤保证，
# 这里不重复做同步等待。主 op-node 的 CL p2p 身份由 run-op-node.sh 自行生成/维护，无需在此处理。
#
# 注：本脚本不做 set -e / exit；沿用调用方（chain-start.sh set -e）的执行语义。

FB_DIR="$BASE_PATH/scripts/flashblocks"

# reth 系与 geth 共用同一份 genesis.json（分叉已由 activate-fork.sh 烘入），无需单独 chainspec。
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
