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

# Engine 端点：默认直连本机 op-geth 的 authrpc(8651)，与未设置该变量时的历史行为逐字节一致。
# 设置 L2_ENGINE_URL 可把 Engine 流量改指到中间件（如 engine-api-proxy），
# 由中间件透明转发给 op-geth，用于拦截 engine_getPayload* 计算并登记区块哈希。
# 注意：不能靠导出 op-node 自带的 OP_NODE_L2_ENGINE_RPC 来改 —— urfave/cli 的命令行
# 优先级高于 EnvVars，只要这里仍然拼出 --l2=，环境变量就会被忽略；故必须在此处组装。
L2_ENGINE_URL="${L2_ENGINE_URL:-http://localhost:8651}"

# 区块签名方式：
#   - 默认（OP_SIGNER_ENDPOINT 留空）：用本地 sequencer 私钥签名，与历史行为一致。
#   - 设置 OP_SIGNER_ENDPOINT：改用远端签名器（op-signer）。此时必须去掉
#     --p2p.sequencer.key，否则 op-node 会以 "cannot specify both a private key and a
#     remote signer for sequencer p2p" 拒绝启动（op-node/p2p/cli/load_signer.go）。
#   - 远端签名器只有 endpoint 与 address 同时非空才算启用（op-service/signer 的
#     CLIConfig.Enabled()），故两者一起下发；address 默认取本链的 sequencer 地址。
#   - --signer.tls.enabled 默认为 true，指向明文 HTTP 端点时必须显式关掉，
#     否则 op-node 会对着一个 HTTP 端口发 TLS 握手而连不上。
if [ -n "${OP_SIGNER_ENDPOINT:-}" ]; then
  signer_flags="--signer.endpoint=$OP_SIGNER_ENDPOINT --signer.address=${OP_SIGNER_ADDRESS:-$GS_SEQUENCER_ADDRESS} --signer.tls.enabled=false"
else
  signer_flags="--p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY"
fi

# --rpc.addr 绑回环：rollup RPC(9545) 的消费方（batcher/proposer/challenger）都在本机。
base_flags="--log.level=info --rpc.addr=127.0.0.1 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s --p2p.disable --rpc.enable-admin $signer_flags --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=$OP_NODE_ROLLUP_FILE --l1.beacon.ignore --safedb.path=$SAFEDB_PATH"
flags="$base_flags $misc_flags $node_flags"

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node $flags"

exec op-node $flags
