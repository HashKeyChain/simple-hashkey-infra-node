#!/bin/bash
#
# 纯组件启动器：仅负责用正确 flags 启动 op-node（本组件 flags 的唯一真源）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试/重启。
#
# 单独运行前提：op-geth 已在 :$OP_GETH_AUTHRPC_PORT 提供 engine RPC、JWT 已生成、rollup.json 已生成。
#

source .envrc

# 允许被 chain-start 编排层通过 _CALLER_* 覆盖；单独运行时回落到 .envrc / 默认值。
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# rollup.json 统一取 config/<context>/（git 跟踪、经 runbook patch 的规范配置），
# 而非 .envrc 默认指向的 optimism/.../deployments/（构建原始产物）。
OP_NODE_ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"
SAFEDB_PATH="${_CALLER_SAFEDB_PATH:-${SAFEDB_PATH:-$BASE_PATH/data/op-node/safedb}}"

mkdir -p "$(dirname "$SAFEDB_PATH")"

# L2 engine 目标随模式切换：off → 直连 op-geth(OP_GETH_AUTHRPC_PORT)；dry_run/enabled → 走 rollup-boost(RB_ENGINE_PORT)。
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:${OP_GETH_AUTHRPC_PORT:-8651}"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi

# CL p2p 始终开启（含 off 模式）：主(sequencer) op-node 向 builder op-node gossip unsafe 块，
# 使 op-rbuilder 在 off 阶段就能预同步到 unsafe head，再从容切 dry_run/enabled。
# 固定 priv key → 稳定 peerID（供 builder op-node 静态连）；关 discv5、内存 peerstore（本地仅静态互联）。
SEQ_P2P_KEY="${_CALLER_SEQ_P2P_KEY:-$BASE_PATH/data/op-node/p2p_priv.txt}"
mkdir -p "$(dirname "$SEQ_P2P_KEY")"
[ -f "$SEQ_P2P_KEY" ] || op-node p2p genkey | tail -1 > "$SEQ_P2P_KEY"
p2p_flags="--p2p.no-discovery --p2p.listen.ip=0.0.0.0 --p2p.listen.tcp=${SEQ_P2P_TCP_PORT:-9222} --p2p.advertise.ip=127.0.0.1 --p2p.advertise.tcp=${SEQ_P2P_TCP_PORT:-9222} --p2p.priv.path=$SEQ_P2P_KEY --p2p.discovery.path=memory --p2p.peerstore.path=memory"

base_flags="--log.level=info --rpc.addr=0.0.0.0 --rpc.port=${OP_ROLLUP_PORT:-9545} --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s $p2p_flags --rpc.enable-admin --p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=$OP_NODE_ROLLUP_FILE --l1.beacon.ignore --safedb.path=$SAFEDB_PATH"
flags="$base_flags $misc_flags $node_flags"

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node $flags"

exec op-node $flags
