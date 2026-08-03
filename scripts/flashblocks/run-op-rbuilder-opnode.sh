#!/bin/bash
#
# Component-only launcher for op-rbuilder's builder op-node, matching the mainnet
# topology (builder-op-node -> builder in the rollup-boost architecture diagram).
# It is not a sequencer and does not produce blocks. Through the Engine API, it drives
# the op-rbuilder instance from run-op-rbuilder.sh to sync the canonical chain:
#   - derives history from L1 (anvil), from genesis through the safe head, without
#     relying on op-geth EL P2P;
#   - connects statically over CL P2P to the primary (sequencer) op-node and follows
#     unsafe-block gossip to the unsafe head.
# Orchestrated by chain-start.sh (requires _CALLER_SEQ_P2P_MULTIADDR); it can also run
# independently for debugging.
#
# Confirm flags against the local op-node (cgt-jovian/v1.16.5) `--help`.
#
source .envrc

L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"

# The builder op-node has its own P2P identity and working directory, separate from the
# primary op-node to avoid conflicts between files at default relative paths.
OPNODE_DIR="$BASE_PATH/data/op-rbuilder-opnode"
mkdir -p "$OPNODE_DIR"
P2P_KEY="$OPNODE_DIR/p2p_priv.txt"
[ -f "$P2P_KEY" ] || op-node p2p genkey | tail -1 > "$P2P_KEY"

# Connect statically to the primary (sequencer) op-node. Prefer the multiaddress supplied
# by chain-start. When run independently for manual warm-up in off mode, derive the
# multiaddress and peer ID from the primary op-node's fixed P2P key, which run-op-node.sh
# generates on first startup.
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
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$RBUILDER_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$RBUILDER_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" \
  --p2p.no-discovery \
  --p2p.listen.ip=0.0.0.0 --p2p.listen.tcp="${RBUILDER_OPNODE_P2P_TCP_PORT:-9223}" \
  --p2p.priv.path="$P2P_KEY" \
  --p2p.discovery.path=memory --p2p.peerstore.path=memory \
  $STATIC_FLAG
