#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# build verse-geth
cd $BASE_PATH/verse-geth && git checkout $HK_GETH_BRANCH
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build verse-node
cd $OP_NODE_PATH && git checkout $HK_VERSE_BRANCH
just op-node
cp $OP_NODE_PATH/bin/op-node $BASE_PATH/bin/op-node

# build verse-proposer
cd $BASE_PATH/verse/op-proposer && git checkout $HK_VERSE_BRANCH
just op-proposer
cp $BASE_PATH/verse/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build verse-batcher
cd $BASE_PATH/verse/op-batcher && git checkout $HK_VERSE_BRANCH
just op-batcher
cp $BASE_PATH/verse/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build verse-challenger
cd $BASE_PATH/verse/op-challenger && git checkout $HK_VERSE_BRANCH
just op-challenger
cp $BASE_PATH/verse/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

# build verse-deployer
cd $BASE_PATH/verse/op-deployer && git checkout $HK_VERSE_BRANCH
just build
cp $BASE_PATH/verse/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer

# build verse-program
cd $BASE_PATH/verse/op-program && git checkout $HK_VERSE_BRANCH
make op-program && make reproducible-prestate
cp $BASE_PATH/verse/op-program/bin/op-program $BASE_PATH/bin/op-program
cp $BASE_PATH/verse/op-program/bin/prestate*.gz $BASE_PATH/bin/
cp $BASE_PATH/verse/op-program/bin/prestate*.json $BASE_PATH/bin/

# build cannon
cd $BASE_PATH/verse/cannon && git checkout $HK_VERSE_BRANCH
make cannon
cp $BASE_PATH/verse/cannon/bin/cannon $BASE_PATH/bin/cannon

# return base path
cd $BASE_PATH
