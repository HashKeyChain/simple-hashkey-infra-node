#!/bin/bash
#
# 纯组件启动器：op-reth（flashblocks-aware RPC）—— 订阅 ws-proxy 的 flashblocks，
# 对外提供 pending/预确认；canonical 链由 run-flashblocks-rpc-op-node.sh（verifier op-node）
# 通过 Engine API 驱动同步。用与 op-geth 相同的 genesis。由 chain-start.sh 编排调用，也可单独调试。
#
# 注：跑的是 op-reth 二进制（reth v1.9.3，内置 flashblocks RPC），
# 不是 rollup-boost 里那个同名的 `flashblocks-rpc` 独立二进制。
#
# 本地全程 ws://（非 wss://，不涉 TLS）。
# flag 名以 `bin/op-reth node --help`（reth v1.9.3）为准，落地时先校准（尤其 --flashblocks-url）。
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# 与 op-geth 共用同一份 genesis.json（分叉在激活时由 activate-fork.sh 烘入）。
CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GENESIS_FILE="${_CALLER_OP_GETH_GENESIS_FILE:-$CFG/genesis.json}"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

# p2p 与真实主网一致：开启节点发现 + 持久化 peer（不加 --disable-discovery / --no-persist-peers）。
# --port 仍自定义，仅为本地避开 op-geth 默认 30303 端口冲突，不改变 p2p 行为语义。
#
# 交易转发目标 = rollup-boost（不是 op-geth）：rollup-boost 的 ProxyLayer 会把
# eth_sendRawTransaction 同时 fan-out 给 op-geth(canonical) 和 op-rbuilder(builder)，
# 从而保证 builder 交易池与 canonical 池同步、flashblock 非空（见 rollup-boost proxy.rs
# FORWARD_REQUESTS）。入站 --rpc-port 无 JWT，明文转发即可。
SEQ_RPC_URL="${SEQUENCER_RPC_URL:-http://localhost:${RB_ENGINE_PORT:-8551}}"
exec op-reth node \
  --chain "$GENESIS_FILE" --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" --http.api eth,web3,net,debug \
  --port "${FB_RPC_P2P_PORT:-30323}" \
  --rollup.sequencer-http "$SEQ_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
