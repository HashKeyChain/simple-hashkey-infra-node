#!/bin/bash
#
# 纯组件启动器：仅负责用正确 flags 启动 op-proposer（本组件 flags 的唯一真源）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试/重启。
#
# 单独运行前提：op-node 已提供 rollup RPC、合约已部署（artifact.json 就绪）。
# 注：anchor 已在部署时用非零 faultGameGenesisOutputRoot(0xdead…) 种入 AnchorStateRegistry，
#     proposer 首次即可建 game，无需再单独初始化 anchor。
#

source .envrc

# 允许被 chain-start 编排层通过 _CALLER_* 覆盖；单独运行时回落到 .envrc。
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
# artifact.json 统一取 config/<context>/（git 跟踪、经 runbook patch 的规范配置），
# 而非 .envrc 默认指向的 optimism/.../deployments/（构建原始产物）。
DEPLOYMENT_OUTFILE="${_CALLER_DEPLOYMENT_OUTFILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/artifact.json}"

base_flags="--log.level=debug --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL"

proposer_flags=""
if [ "$USE_FAULT_PROOFS" = "true" ]; then
  # GAME_TYPE 缺省 1（PERMISSIONED_CANNON，permissioned 起步，与部署时 respectedGameType 一致）。
  proposer_flags="--game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) --proposal-interval=${PROPOSAL_INTERVAL:-30s} --game-type=${GAME_TYPE:-1}"
else
  proposer_flags="--l2oo-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy)"
fi

misc_flags="--poll-interval=30s --network-timeout=600s --num-confirmations=1 --wait-node-sync=${WAIT_NODE_SYNC:-true}"
flags="$base_flags $proposer_flags $misc_flags"

echo "Starting op-proposer ..."
echo "op-proposer $flags"

exec op-proposer $flags
