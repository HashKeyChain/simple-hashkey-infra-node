#!/bin/bash

source .envrc

echo "Starting op-proposer ..."

echo "op-proposer --log.level=debug --poll-interval=12s --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --l2oo-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy) --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL --num-confirmations=3"

op-proposer \
  --log.level=debug \
  --poll-interval=12s \
  --rpc.port=8560 \
  --rollup-rpc=$OP_NODE_RPC_URL \
  --l2oo-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy) \
  --private-key=$GS_PROPOSER_PRIVATE_KEY \
  --l1-eth-rpc=$L1_RPC_URL \
  --num-confirmations=3