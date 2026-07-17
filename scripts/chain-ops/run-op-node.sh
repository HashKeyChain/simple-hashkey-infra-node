#!/bin/bash
#
# 纯组件启动器：仅负责用正确 flags 启动 op-node（本组件 flags 的唯一真源）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试/重启。
#
# 单独运行前提：op-geth 已在 :8651 提供 engine RPC、JWT 已生成、rollup.json 已生成。
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

base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=http://localhost:8651 --l2.jwt-secret=$JWT_FILE"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s --p2p.disable --rpc.enable-admin --p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=$OP_NODE_ROLLUP_FILE --l1.beacon.ignore --safedb.path=$SAFEDB_PATH"
flags="$base_flags $misc_flags $node_flags"

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node $flags"

exec op-node $flags
