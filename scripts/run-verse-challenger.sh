#!/bin/bash

echo "Starting verse-challenger ..."
cannon_flags="--cannon-rollup-config=config/$DEPLOYMENT_CONTEXT/rollup.json --cannon-l2-genesis=config/$DEPLOYMENT_CONTEXT/genesis.json --cannon-bin=bin/cannon --cannon-server=bin/op-program --cannon-prestate=bin/prestate-mt64.bin.gz"

echo "verse-challenger --datadir=data/verse-challenger --l1-eth-rpc=$L1_RPC_URL --l1-beacon=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rollup-rpc=$OP_NODE_RPC_URL --private-key=data/verse-geth/keyfile.json --trace-type=permissioned --game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactory) --num-confirmations=1 $cannon_flags"

op-challenger \
  --datadir=data/verse-challenger \
  --l1-eth-rpc=$L1_RPC_URL \
  --l1-beacon=$L1_RPC_URL \
  --l2-eth-rpc=$L2_RPC_URL \
  --rollup-rpc=$OP_NODE_RPC_URL \
  --private-key=data/verse-geth/keyfile.json \
  --trace-type=permissioned \
  --game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactory) \
  --num-confirmations=1 \
  $cannon_flags