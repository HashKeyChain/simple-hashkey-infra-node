#!/bin/bash

source .envrc

# Init the anchor state before starting challenger.
if [ "$USE_FAULT_PROOFS" = "true" ]; then
  sh scripts/initialize-anchorState.sh
fi

base_flags="--log.level=debug --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL"

export proposer_flags=""
if [ "$USE_FAULT_PROOFS" = "true" ]; then
  proposer_flags="--game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) --proposal-interval=${PROPOSAL_INTERVAL:-30s} --game-type=${GAME_TYPE:-0}"
else
  # 部分 op-proposer 二进制不支持 --l2oo-address，用环境变量
  export OP_PROPOSER_L2OO_ADDRESS=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy)
  proposer_flags=""
fi

misc_flags="--poll-interval=30s --network-timeout=600s --num-confirmations=1 --wait-node-sync=${WAIT_NODE_SYNC:-true}"
flags="$base_flags $proposer_flags $misc_flags"

echo "Starting op-proposer ..."
echo "op-proposer $flags"

op-proposer $flags
