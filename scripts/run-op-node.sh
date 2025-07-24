#!/bin/bash

source .envrc

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node --l2=http://localhost:8651 --l2.jwt-secret=${BASE_PATH}/data/jwt.txt --sequencer.enabled --sequencer.l1-confs=5 --verifier.l1-confs=4 --rollup.config=${OP_NODE_ROLLUP_FILE} --rpc.addr=0.0.0.0 --p2p.disable --rpc.enable-admin --p2p.sequencer.key=${GS_SEQUENCER_PRIVATE_KEY} --l1=${L1_RPC_URL} --l1.rpckind=${L1_RPC_KIND} --l1.beacon.ignore"

bin/op-node \
  --l2=http://localhost:8651 \
  --l2.jwt-secret=${BASE_PATH}/data/jwt.txt \
  --sequencer.enabled \
  --sequencer.l1-confs=5 \
  --verifier.l1-confs=4 \
  --rollup.config=$OP_NODE_ROLLUP_FILE \
  --rpc.addr=0.0.0.0 \
  --p2p.disable \
  --rpc.enable-admin \
  --p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY \
  --l1=$L1_RPC_URL \
  --l1.rpckind=$L1_RPC_KIND \
  --l1.beacon.ignore