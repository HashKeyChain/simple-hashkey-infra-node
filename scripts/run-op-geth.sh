#!/bin/bash

source .envrc

export OP_GETH_DATA_PATH=$BASE_PATH/data/op-geth

# Init l2geth datadir.
init_flags="--state.scheme=hash --datadir=${OP_GETH_DATA_PATH} $OP_GETH_GENESIS_FILE"
echo "op-geth init $init_flags"
op-geth init $init_flags

# Start l2geth.
base_flags="--verbosity=3 --datadir=${OP_GETH_DATA_PATH} --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner"
geth_flags="--syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=${OP_GETH_DATA_PATH}/jwt.txt --state.scheme=hash"
flags="$base_flags $geth_flags"

echo "Starting op-geth ..."
echo "op-geth $flags"

op-geth $flags
