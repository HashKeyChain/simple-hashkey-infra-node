#!/bin/bash

source .envrc

safedb=${SAFEDB_PATH:-$BASE_PATH/data/op-node/safedb}

# Clean up safedb.

base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=${L1_RPC_URL} --l1.rpckind=${L1_RPC_KIND} --l2=http://localhost:8651 --l2.jwt-secret=${BASE_PATH}/data/op-geth/jwt.txt"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s --p2p.disable --rpc.enable-admin --p2p.sequencer.key=${GS_SEQUENCER_PRIVATE_KEY} --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=${OP_NODE_ROLLUP_FILE} --l1.beacon.ignore --safedb.path=${safedb}"
flags="$base_flags $misc_flags $node_flags"

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node $flags"

op-node $flags
