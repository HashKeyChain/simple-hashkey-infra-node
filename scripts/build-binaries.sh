#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# build verse-geth
if [ ! -f $BASE_PATH/bin/op-geth ]; then
  cd $BASE_PATH/verse-geth && git checkout $HK_GETH_BRANCH
  make geth
  cp build/bin/geth $BASE_PATH/bin/op-geth
fi

# build verse-node
if [ ! -f $BASE_PATH/bin/op-node ]; then
  cd $OP_NODE_PATH && git checkout $HK_VERSE_BRANCH
  just op-node
  cp $OP_NODE_PATH/bin/op-node $BASE_PATH/bin/op-node
fi

# build verse-proposer
if [ ! -f $BASE_PATH/bin/op-proposer ]; then
  cd $BASE_PATH/verse/op-proposer && git checkout $HK_VERSE_BRANCH
  just op-proposer
  cp $BASE_PATH/verse/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer
fi

# build verse-batcher
if [ ! -f $BASE_PATH/bin/op-batcher ]; then
  cd $BASE_PATH/verse/op-batcher && git checkout $HK_VERSE_BRANCH
  just op-batcher
  cp $BASE_PATH/verse/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher
fi

# build verse-challenger
if [ ! -f $BASE_PATH/bin/op-challenger ]; then
  cd $BASE_PATH/verse/op-challenger && git checkout $HK_VERSE_BRANCH
  just op-challenger
  cp $BASE_PATH/verse/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger
fi

# build verse-withdrawal
if [ ! -f $BASE_PATH/bin/op-withdrawal ]; then
  cd $BASE_PATH/verse/op-chain-ops && git checkout $HK_VERSE_BRANCH
  just op-withdrawal
  cp $BASE_PATH/verse/op-chain-ops/bin/op-withdrawal $BASE_PATH/bin/op-withdrawal
fi

# build verse-deployer
if [ ! -f $BASE_PATH/bin/op-deployer ]; then
  cd $BASE_PATH/verse/op-deployer && git checkout $HK_VERSE_BRANCH
  just build
  cp $BASE_PATH/verse/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer
fi

# build verse-program
if [ ! -f $BASE_PATH/bin/op-program ]; then
  cd $BASE_PATH/verse/op-program && git checkout $HK_VERSE_BRANCH
  make op-program && make reproducible-prestate
  cp $BASE_PATH/verse/op-program/bin/op-program $BASE_PATH/bin/op-program
  cp $BASE_PATH/verse/op-program/bin/prestate*.gz $BASE_PATH/bin/
  cp $BASE_PATH/verse/op-program/bin/prestate*.json $BASE_PATH/bin/
fi

# build cannon
if [ ! -f $BASE_PATH/bin/cannon ]; then
  cd $BASE_PATH/verse/cannon && git checkout $HK_VERSE_BRANCH
  make cannon
  cp $BASE_PATH/verse/cannon/bin/cannon $BASE_PATH/bin/cannon
fi

# return base path
cd $BASE_PATH
