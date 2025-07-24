#!/bin/bash

source .envrc

# build geth
cd $BASE_PATH/op-geth && git checkout v1.101503.4
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $OP_NODE_PATH && git checkout v1.13.2
just op-node
cp $OP_NODE_PATH/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/optimism/op-proposer && git checkout v1.13.2
just op-proposer
cp $BASE_PATH/optimism/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/optimism/op-batcher && git checkout v1.13.2
just op-batcher
cp $BASE_PATH/optimism/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/optimism/op-challenger && git checkout v1.13.2
just op-challenger
cp $BASE_PATH/optimism/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

cd $BASE_PATH/op-geth && git checkout optimism
cd $BASE_PATH/optimism && git checkout develop

# return base path
cd $BASE_PATH
