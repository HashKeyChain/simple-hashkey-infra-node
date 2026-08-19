#!/bin/bash

# This script starts op-node with hardfork config from rollup.json
# Hardfork times should be pre-configured in rollup.json before running this script

source .envrc

echo "============================================"
echo "  op-node Upgrade to Jovian"
echo "============================================"

ROLLUP_JSON=$OP_NODE_ROLLUP_FILE

# Read hardfork times from rollup.json (do NOT overwrite)
echo "Reading hardfork times from: $ROLLUP_JSON"
GRANITE_TIME=$(jq -r '.granite_time // empty' $ROLLUP_JSON)
HOLOCENE_TIME=$(jq -r '.holocene_time // empty' $ROLLUP_JSON)
ISTHMUS_TIME=$(jq -r '.isthmus_time // empty' $ROLLUP_JSON)
JOVIAN_TIME=$(jq -r '.jovian_time // empty' $ROLLUP_JSON)

echo "Hardfork times:"
echo "  granite_time:  $GRANITE_TIME"
echo "  holocene_time: $HOLOCENE_TIME"
echo "  isthmus_time:  $ISTHMUS_TIME"
echo "  jovian_time:   $JOVIAN_TIME"

# Start op-node
echo ""
echo "============================================"
echo "  Starting op-node with Jovian enabled"
echo "============================================"

safedb=${SAFEDB_PATH:-$BASE_PATH/data/op-node/safedb}

# Clean up safedb
rm -rf $safedb && mkdir -p $safedb

# --rpc.addr 绑回环，理由见 run-op-node.sh。
base_flags="--log.level=info --rpc.addr=127.0.0.1 --l1=${L1_RPC_URL} --l1.rpckind=${L1_RPC_KIND} --l2=http://localhost:8651 --l2.jwt-secret=${BASE_PATH}/data/op-geth/jwt.txt"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s --p2p.disable --rpc.enable-admin --p2p.sequencer.key=${GS_SEQUENCER_PRIVATE_KEY} --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=${OP_NODE_ROLLUP_FILE} --l1.beacon.ignore --safedb.path=${safedb}"
flags="$base_flags $misc_flags $node_flags"

echo "op-node $flags"
op-node $flags
