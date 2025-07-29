#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# build geth
cd $BASE_PATH/hk-geth && git checkout $HK_GETH_BRANCH
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $OP_NODE_PATH && git checkout $HK_VERSE_BRANCH
just op-node
cp $OP_NODE_PATH/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/verse/op-proposer && git checkout $HK_VERSE_BRANCH
just op-proposer
cp $BASE_PATH/verse/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/verse/op-batcher && git checkout $HK_VERSE_BRANCH
just op-batcher
cp $BASE_PATH/verse/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/verse/op-challenger && git checkout $HK_VERSE_BRANCH
just op-challenger
cp $BASE_PATH/verse/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

cd $BASE_PATH/op-geth && git checkout hk-geth
cd $BASE_PATH/verse && git checkout develop

# return base path
cd $BASE_PATH
