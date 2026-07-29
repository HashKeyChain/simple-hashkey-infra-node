#!/bin/bash
#
# 停止所有 flashblocks 组件（由 chain-stop.sh `source`，需其已定义 stop_pid /
# stop_matching_processes，并已设 PID_DIR / DATA_DIR 及相关端口变量）。
# 在核心 op-node/op-geth 之前调用（与启动顺序相反）。
#
# 覆盖组件：fb-rpc-opnode、fb-rpc-reth、fb-proxy、rollup-boost、
#           op-rbuilder-opnode、op-rbuilder。

# 先停本轮 chain-start 记录的 pid 文件。
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder-opnode op-rbuilder; do
  pid_file="$PID_DIR/${name}.pid"
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    stop_pid "$name" "$pid"
    rm -f "$pid_file"
  fi
done

# 再按命令行特征清理 pid 文件被覆盖的残留进程（needle 以实际 ps 命令行为准）。
stop_matching_processes "fb-rpc-opnode"      "op-node "                      "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "op-rbuilder-opnode" "op-node "                      "--rpc.port=${RBUILDER_OPNODE_PORT:-9565}"
stop_matching_processes "fb-rpc-reth"        "op-reth "                      "$DATA_DIR/op-reth"
stop_matching_processes "fb-proxy"           "flashblocks-websocket-proxy "  "0.0.0.0:${FB_PROXY_PORT:-1113}"
stop_matching_processes "op-rbuilder"        "op-rbuilder "                  "$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost"       "rollup-boost "                 "--rpc-port ${RB_ENGINE_PORT:-8551}"
