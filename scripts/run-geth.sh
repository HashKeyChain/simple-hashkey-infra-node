#!/bin/bash

source .envrc

export VERSE_GETH_PATH=$BASE_PATH/data/verse-geth
rm -rf $VERSE_GETH_PATH

# Init l2geth datadir.
init_flags="--state.scheme=hash --datadir=${VERSE_GETH_PATH} $OP_GETH_GENESIS_FILE"
echo "op-geth init $init_flags"
op-geth init $init_flags

# Start l2geth.
base_flags="--verbosity=4 --datadir=${VERSE_GETH_PATH} --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner"
geth_flags="--syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=${VERSE_GETH_PATH}/jwt.txt --state.scheme=hash"
flags="$base_flags $geth_flags"

echo "Starting verse-geth ..."
echo "op-geth $flags"

#op-geth $flags