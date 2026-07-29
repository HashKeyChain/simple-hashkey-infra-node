#!/bin/bash
#
# 纯组件启动器：仅负责用正确 flags 启动 op-geth（本组件 flags 的唯一真源）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试/重启。
#
# 单独运行前提：已执行 chain-setup 生成配置、datadir 已初始化（op-geth init）、JWT 已生成。
# 注：datadir 初始化由 chain-start.sh 幂等负责，本脚本不再执行 op-geth init。
#

source .envrc

# 允许被 chain-start 编排层通过 _CALLER_* 覆盖；单独运行时回落到 .envrc / 默认值。
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

# 硬分叉时间：由 activate-fork.sh 烘入 genesis.json（源自 .envrc FORK_*_TIME），
# geth 从 genesis 读分叉，不再用 --override.*（reth 无 override，二者用同一份 genesis 保持一致）。
flags="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=${OP_GETH_HTTP_PORT:-8645} --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=${OP_GETH_WS_PORT:-8646} --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=${OP_GETH_AUTHRPC_PORT:-8651} --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash"

echo "Starting op-geth ..."
echo "op-geth $flags"

exec op-geth $flags
