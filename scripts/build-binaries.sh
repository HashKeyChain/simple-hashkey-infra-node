#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# Helper function to fetch and checkout a ref (works with shallow clones)
fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin $ref 2>/dev/null || git fetch --depth 1 origin tag $ref 2>/dev/null || true
  git checkout $ref
}

# build op-geth
cd $BASE_PATH/op-geth
fetch_and_checkout $OP_GETH_REF
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $BASE_PATH/optimism
fetch_and_checkout $OP_NODE_REF
just op-node
cp $BASE_PATH/optimism/op-node/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/optimism
fetch_and_checkout $OP_PROPOSER_REF
just op-proposer
cp $BASE_PATH/optimism/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/optimism
fetch_and_checkout $OP_BATCHER_REF
just op-batcher
cp $BASE_PATH/optimism/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/optimism
fetch_and_checkout $OP_CHALLENGER_REF
just op-challenger
cp $BASE_PATH/optimism/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

# # build op-deployer
# cd $BASE_PATH/optimism
# fetch_and_checkout $OP_DEPLOYER_REF
# just op-deployer
# cp $BASE_PATH/optimism/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer

# # build op-program
# cd $BASE_PATH/optimism
# fetch_and_checkout $OP_PROGRAM_REF
# make op-program && make reproducible-prestate
# cp $BASE_PATH/optimism/op-program/bin/op-program $BASE_PATH/bin/op-program
# cp $BASE_PATH/optimism/op-program/bin/prestate*.gz $BASE_PATH/bin/
# cp $BASE_PATH/optimism/op-program/bin/prestate*.json $BASE_PATH/bin/

# # build cannon
# cd $BASE_PATH/optimism
# fetch_and_checkout $CANNON_REF
# make cannon
# cp $BASE_PATH/optimism/cannon/bin/cannon $BASE_PATH/bin/cannon

# return base path
cd $BASE_PATH
