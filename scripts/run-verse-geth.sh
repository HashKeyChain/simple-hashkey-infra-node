#!/bin/bash

source .envrc

export VERSE_GETH_PATH=$BASE_PATH/data/verse-geth
rm -rf $VERSE_GETH_PATH

# Init l2geth datadir.
echo "Initializing l2geth datadir with genesis file: $OP_GETH_GENESIS_FILE"
op-geth init --state.scheme=hash --datadir=${VERSE_GETH_PATH} $OP_GETH_GENESIS_FILE

# Start l2geth.
echo "Starting l2geth with datadir: data"
echo "op-geth --datadir=${VERSE_GETH_PATH} --http --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine --ws --ws.port=8646 --ws.api=debug,eth,txpool,net,engine --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.jwtsecret=${VERSE_GETH_PATH}/jwt.txt"

op-geth \
  --datadir=${VERSE_GETH_PATH} \
  --http \
  --http.corsdomain="*" \
  --http.vhosts="*" \
  --http.addr=0.0.0.0 \
  --http.port=8645 \
  --http.api=web3,debug,eth,txpool,net,engine,miner \
  --ws \
  --ws.addr=0.0.0.0 \
  --ws.port=8646 \
  --ws.origins="*" \
  --ws.api=debug,eth,txpool,net,engine,miner \
  --syncmode=full \
  --gcmode=archive \
  --nodiscover \
  --maxpeers=0 \
  --networkid=42069 \
  --authrpc.vhosts="*" \
  --authrpc.addr=0.0.0.0 \
  --authrpc.port=8651 \
  --authrpc.jwtsecret=${VERSE_GETH_PATH}/jwt.txt \
  --state.scheme=hash