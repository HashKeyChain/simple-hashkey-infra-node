#!/bin/bash

source .envrc

# Start L2output at default proposer address.
# L2OO_ADDRESS is L2OutputOracleProxy address, if it's not set we are using DisputeGameFactory.
L2OO_ADDRESS=${L2OO_ADDRESS:-$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy)}

base_flags="--log.level=debug --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL"

proposer_flags="--l2oo-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy) --game-type=${GAME_TYPE:-0}"
if [ -z "$L2OO_ADDRESS" ]; then
  proposer_flags="--game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) --proposal-interval=${PROPOSAL_INTERVAL:-6s}"
fi

misc_flags="--poll-interval=12s --allow-non-finalized --network-timeout=600s --num-confirmations=1"
flags="$base_flags $proposer_flags $misc_flags"

echo "Starting op-proposer ..."
echo "op-proposer $flags"

op-proposer $flags