#!/bin/bash
#
# 纯组件启动器：op-rbuilder（reth 系 flashblocks builder）。本组件 flags 的唯一真源。
# 用与 op-geth 相同的 genesis；不需要单独的 builder op-node —— 由 rollup-boost
# 转发主 op-node 的 Engine 调用来驱动出块。
# 由 chain-start.sh 编排调用，也可单独运行用于调试。
#
# flag 名以 `bin/op-rbuilder node --help`（v0.2.13）为准，落地时先校准。
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# 与 op-geth 共用同一份 genesis.json（分叉在激活时由 activate-fork.sh 烘入）。
CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GENESIS_FILE="${_CALLER_OP_GETH_GENESIS_FILE:-$CFG/genesis.json}"
DATADIR="$BASE_PATH/data/op-rbuilder"
mkdir -p "$DATADIR"

# 每区块的 flashblock 切片数 = chain-block-time / flashblocks.block-time
# （见 op-rbuilder/crates/op-rbuilder/src/builders/flashblocks/config.rs 的 flashblocks_per_block）。
# --rollup.chain-block-time 默认只有 1000ms，不显式传就会按 1 秒切片：L2_BLOCK_TIME=2 时只切 4 片、
# 且每片 gas 预算 = block_gas_limit / 片数，等于把整个区块的 gas 在前 1 秒就分配完，
# 区块后半段进来的交易进不了任何 flashblock。所以必须与 L2_BLOCK_TIME 对齐。
FB_INTERVAL_MS="${FB_INTERVAL_MS:-250}"
CHAIN_BLOCK_TIME_MS=$(( ${L2_BLOCK_TIME:-2} * 1000 ))
if [ $(( CHAIN_BLOCK_TIME_MS % FB_INTERVAL_MS )) -ne 0 ]; then
  echo "WARN: L2_BLOCK_TIME(${CHAIN_BLOCK_TIME_MS}ms) 不是 flashblock 间隔(${FB_INTERVAL_MS}ms) 的整数倍，" \
       "整除后每区块 $(( CHAIN_BLOCK_TIME_MS / FB_INTERVAL_MS )) 片会盖不满整个区块窗口。" >&2
fi

# p2p 与真实主网一致：开启节点发现 + 持久化 peer（不加 --disable-discovery / --no-persist-peers）。
# --port 仍自定义，仅为本地避开 op-geth 默认 30303 端口冲突，不改变 p2p 行为语义。
exec op-rbuilder node \
  --chain "$GENESIS_FILE" \
  --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$RBUILDER_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$RBUILDER_HTTP_PORT" --http.api eth,web3,net,debug,txpool \
  --ws --ws.addr 0.0.0.0 --ws.port "$RBUILDER_WS_PORT" \
  --port "${RBUILDER_P2P_PORT:-30313}" \
  --rollup.chain-block-time "$CHAIN_BLOCK_TIME_MS" \
  --flashblocks.enabled --flashblocks.addr 0.0.0.0 --flashblocks.port "$RBUILDER_FB_WS_PORT" \
  --flashblocks.block-time "$FB_INTERVAL_MS"
