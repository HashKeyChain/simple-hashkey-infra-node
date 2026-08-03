#!/bin/bash
#
# Component-only launcher: starts op-node with the correct flags (the single source of truth for this component's flags).
# Orchestrated by chain-start.sh; it can also be run independently for debugging or restarts.
#
# Prerequisites for standalone use: op-geth is serving the Engine RPC on :$OP_GETH_AUTHRPC_PORT,
# and both the JWT and rollup.json have been generated.
#

source .envrc

# Allow the chain-start orchestration layer to override values via _CALLER_*; fall back to .envrc/defaults when run independently.
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# Always read rollup.json from config/<context>/ (the canonical, Git-tracked configuration patched by the runbook),
# rather than the raw build output under optimism/.../deployments/ referenced by .envrc by default.
OP_NODE_ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"
SAFEDB_PATH="${_CALLER_SAFEDB_PATH:-${SAFEDB_PATH:-$BASE_PATH/data/op-node/safedb}}"

mkdir -p "$(dirname "$SAFEDB_PATH")"

# Switch the L2 Engine target by mode: off -> connect directly to op-geth (OP_GETH_AUTHRPC_PORT);
# dry_run/enabled -> connect through rollup-boost (RB_ENGINE_PORT).
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:${OP_GETH_AUTHRPC_PORT:-8651}"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi

# Keep CL P2P enabled in every mode, including off: the primary (sequencer) op-node gossips unsafe blocks
# to the builder op-node so op-rbuilder can pre-sync to the unsafe head while off, enabling a smooth switch to dry_run/enabled.
# A fixed private key provides a stable peer ID for the builder op-node's static connection; disable discv5 and use
# an in-memory peerstore because local peers are connected statically only.
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
