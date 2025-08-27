#!/bin/bash

source .envrc


base_flags="--log.level=debug --rpc.addr=0.0.0.0 --l1=${L1_RPC_URL} --l1.rpckind=${L1_RPC_KIND} --l2=http://localhost:8651 --l2.jwt-secret=${BASE_PATH}/data/verse-geth/jwt.txt"
misc_flags="--sequencer.enabled --p2p.disable --rpc.enable-admin --p2p.sequencer.key=${GS_SEQUENCER_PRIVATE_KEY} --sequencer.l1-confs=5 --verifier.l1-confs=4"
flags="$base_flags $misc_flags --rollup.config=${OP_NODE_ROLLUP_FILE} --l1.beacon.ignore"

echo "Starting verse-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "verse-node $flags"

op-node $flags