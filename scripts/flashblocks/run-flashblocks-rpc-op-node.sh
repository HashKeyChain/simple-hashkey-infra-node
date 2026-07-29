#!/bin/bash
#
# 纯组件启动器：flashblocks RPC 副本的 verifier op-node —— 不出块（非 sequencer），
# 通过 Engine API 驱动 run-flashblocks-rpc-op-reth.sh 的 op-reth 同步 canonical 链：
#   - 从 L1(anvil) 派生补历史（创世 → safe head）；
#   - 经 CL p2p 静态连主(sequencer) op-node，收 unsafe 块 gossip 跟到 unsafe head
#     （否则 op-reth 只能到 safe head，对用户提供的 RPC 会落后于链头）。
# 由 chain-start.sh 编排调用（需 _CALLER_SEQ_P2P_MULTIADDR），也可单独调试。
#
# flag 名以本地 op-node（cgt-jovian/v1.16.5）`--help` 为准；若不支持 --l2.enginekind=reth 则去掉该 flag。
#
source .envrc

L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"

# 本 op-node 自己的 p2p 身份与工作目录（与主 op-node / builder op-node 分开，避免文件与端口冲突）。
OPNODE_DIR="$BASE_PATH/data/fb-rpc-opnode"
mkdir -p "$OPNODE_DIR"
P2P_KEY="$OPNODE_DIR/p2p_priv.txt"
[ -f "$P2P_KEY" ] || op-node p2p genkey | tail -1 > "$P2P_KEY"

# 静态连主(sequencer) op-node：优先用 chain-start 下传的多址；单独运行时从主 op-node 的固定 p2p key 现算。
STATIC_PEER="${_CALLER_SEQ_P2P_MULTIADDR:-${SEQ_P2P_MULTIADDR:-}}"
if [ -z "$STATIC_PEER" ]; then
  SEQ_KEY="${_CALLER_SEQ_P2P_KEY:-$BASE_PATH/data/op-node/p2p_priv.txt}"
  if [ -f "$SEQ_KEY" ]; then
    SEQ_PID=$(op-node p2p priv2id < "$SEQ_KEY" | tail -1)
    STATIC_PEER="/ip4/127.0.0.1/tcp/${SEQ_P2P_TCP_PORT:-9222}/p2p/${SEQ_PID}"
  fi
fi
STATIC_FLAG=""
[ -n "$STATIC_PEER" ] && STATIC_FLAG="--p2p.static=$STATIC_PEER"

exec op-node \
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$FB_RPC_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$FB_RPC_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" \
  --p2p.no-discovery \
  --p2p.listen.ip=0.0.0.0 --p2p.listen.tcp="${FB_RPC_OPNODE_P2P_TCP_PORT:-9224}" \
  --p2p.priv.path="$P2P_KEY" \
  --p2p.discovery.path=memory --p2p.peerstore.path=memory \
  $STATIC_FLAG
