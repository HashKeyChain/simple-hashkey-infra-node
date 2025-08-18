#!/bin/bash

source .envrc

echo "Starting verse-challenger ..."
cannon_flags="--cannon-rollup-config=$DEPLOYMENT_CONFIG_PATH/rollup.json --cannon-l2-genesis=$DEPLOYMENT_CONFIG_PATH/genesis.json --cannon-bin=$BASE_PATH/bin/cannon --cannon-server=$BASE_PATH/bin/op-program --cannon-prestate=$BASE_PATH/bin/prestate-mt64.bin.gz"


# private-key is the second test account from anvil, the address is 0x70997970C51812dc3A010C7d01b50e0d17dc79C8.
private_key=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

echo "verse-challenger --log.level=debug --datadir=$BASE_PATH/data/verse-challenger --l1-eth-rpc=$L1_RPC_URL --l1-beacon=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rollup-rpc=$OP_NODE_RPC_URL --private-key=$private_key --trace-type=permissioned --game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) --num-confirmations=1 $cannon_flags"

op-challenger \
  --log.level=debug \
  --datadir=$BASE_PATH/data/verse-challenger \
  --l1-eth-rpc=$L1_RPC_URL \
  --l1-beacon=$L1_RPC_URL \
  --l2-eth-rpc=$L2_RPC_URL \
  --rollup-rpc=$OP_NODE_RPC_URL \
  --private-key=$private_key \
  --trace-type=permissioned \
  --game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) \
  --num-confirmations=1 \
  $cannon_flags