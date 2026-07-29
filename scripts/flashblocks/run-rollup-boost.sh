#!/bin/bash
#
# 纯组件启动器：rollup-boost —— op-node ↔ (op-geth fallback + op-rbuilder builder)
# 之间的 Engine API 代理，并对外广播 flashblocks。含 debug server（set-execution-mode 热切）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试。
#
# FLASHBLOCKS_MODE 仅作启动初值：dry_run→dry-run 执行模式（builder payload 只校验不采用），
# enabled→enabled（采用 builder payload）。off 态下本组件根本不启动（见 chain-start.sh）。
# 运行时热切走 debug server 的 JSON-RPC（v0.7.11 没有 `debug set-execution-mode` 子命令）：
#   curl -X POST -H 'Content-Type: application/json' \
#     --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
#     http://localhost:$RB_DEBUG_PORT
# 查当前模式用 debug_getExecutionMode。热切无需重启 op-node。
#
# flag 已按 `bin/rollup-boost --help`（v0.7.11）校准：
#   - 入站 engine server 是 --rpc-host/--rpc-port（无独立 --jwt-path；与 l2/builder 共用 jwt.txt）
#   - 上游用 --l2-url / --builder-url，必须带 scheme（http://host:port）；v0.7.11 运行时按 url::Url
#     解析，无 scheme 会 `Invalid URL: relative URL without a base` 直接崩溃（--help 默认虽写 host:port）
#   - 广播端是 --flashblocks-host/--flashblocks-port；builder 入口 --flashblocks-builder-url（ws://）
#   - 执行模式取值：enabled / dry-run / disabled（默认 enabled）
#   - --metrics 开 Prometheus（默认关）。暴露 block_building_gas_delta /
#     block_building_tx_count_delta（builder 相对 op-geth 的差值分布）、
#     rpc_blocks_created{source=l2|builder}、rollup_boost_execution_mode。
#     注意它不含区块哈希比对，也没有「块无效」计数 —— 那两项只能从日志算
#     （见 scripts/flashblocks/verify/p2-dryrun.sh）。
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

EXEC_MODE_FLAG=""
[ "$FLASHBLOCKS_MODE" = "dry_run" ] && EXEC_MODE_FLAG="--execution-mode=dry-run"
[ "$FLASHBLOCKS_MODE" = "enabled" ] && EXEC_MODE_FLAG="--execution-mode=enabled"

exec rollup-boost \
  --rpc-host 0.0.0.0 --rpc-port "$RB_ENGINE_PORT" \
  --l2-url  http://127.0.0.1:"${OP_GETH_AUTHRPC_PORT:-8651}" \
  --l2-jwt-path "$JWT_FILE" \
  --builder-url http://127.0.0.1:"$RBUILDER_AUTHRPC_PORT" \
  --builder-jwt-path "$JWT_FILE" \
  --flashblocks --flashblocks-builder-url ws://127.0.0.1:"$RBUILDER_FB_WS_PORT" \
  --flashblocks-host 0.0.0.0 --flashblocks-port "$RB_FLASHBLOCKS_WS_PORT" \
  --debug-server-port "$RB_DEBUG_PORT" \
  --metrics --metrics-host 127.0.0.1 --metrics-port "${RB_METRICS_PORT:-9090}" \
  $EXEC_MODE_FLAG
