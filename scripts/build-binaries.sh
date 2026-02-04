#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# build op-geth
cd $BASE_PATH/op-geth && git checkout $OP_GETH_REF
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $OP_NODE_PATH && git checkout $OP_MONOREPO_REF
just op-node
cp $OP_NODE_PATH/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/optimism/op-proposer && git checkout $OP_MONOREPO_REF
just op-proposer
cp $BASE_PATH/optimism/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/optimism/op-batcher && git checkout $OP_MONOREPO_REF
just op-batcher
cp $BASE_PATH/optimism/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/optimism/op-challenger && git checkout $OP_MONOREPO_REF
just op-challenger
cp $BASE_PATH/optimism/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

# build op-deployer
cd $BASE_PATH/optimism/op-deployer && git checkout $OP_MONOREPO_REF
just build
cp $BASE_PATH/optimism/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer

# build op-program
cd $BASE_PATH/optimism/op-program && git checkout $OP_MONOREPO_REF
make op-program && make reproducible-prestate
cp $BASE_PATH/optimism/op-program/bin/op-program $BASE_PATH/bin/op-program
cp $BASE_PATH/optimism/op-program/bin/prestate*.gz $BASE_PATH/bin/
cp $BASE_PATH/optimism/op-program/bin/prestate*.json $BASE_PATH/bin/

# build cannon
cd $BASE_PATH/optimism/cannon && git checkout $OP_MONOREPO_REF
make cannon
cp $BASE_PATH/optimism/cannon/bin/cannon $BASE_PATH/bin/cannon

# return base path
cd $BASE_PATH
