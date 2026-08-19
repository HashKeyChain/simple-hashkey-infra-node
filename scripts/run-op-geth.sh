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

# 硬分叉时间覆盖：从 .envrc 的单一真源 FORK_*_TIME 现场组装 --override.*。
# 仅对非空项生成 override；用 ${VAR:+...} 纯参数展开，不受本脚本 set 选项影响。
# 与 rollup.json 的 *_time（patch-rollup-config.sh 写入）同源，保证 geth/op-node 一致。
override_flags="${FORK_FJORD_TIME:+--override.fjord=$FORK_FJORD_TIME} ${FORK_GRANITE_TIME:+--override.granite=$FORK_GRANITE_TIME} ${FORK_HOLOCENE_TIME:+--override.holocene=$FORK_HOLOCENE_TIME} ${FORK_ISTHMUS_TIME:+--override.isthmus=$FORK_ISTHMUS_TIME} ${FORK_JOVIAN_TIME:+--override.jovian=$FORK_JOVIAN_TIME}"

# 监听地址一律绑回环：本链的消费方（op-node、op-batcher、op-proposer、op-challenger、cast）
# 都跑在本机，无需对外可达。authrpc(8651) 是 Engine API 端口，一旦对所有网卡开放，
# 同网段任何人都能驱动出块，故必须绑 127.0.0.1。
flags="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=127.0.0.1 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=127.0.0.1 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=127.0.0.1 --authrpc.port=8651 --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash $override_flags"

echo "Starting op-geth ..."
echo "op-geth $flags"

exec op-geth $flags
