#!/bin/bash

source .envrc

# Build and deploy contracts.
cd $CONTRACTS_BEDROCK_PATH && git checkout $HK_VERSE_BRANCH

# Init deployment config.
sh scripts/getting-started/config.sh

# Build and deploy contracts.
forge install && forge build
forge script scripts/deploy/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --slow --skip-simulation

# Create l2chain genesis state and load in file.
export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()'

# Init rollup config and genesis file.
cd $OP_NODE_PATH
go run cmd/main.go genesis l2 \
--deploy-config $DEPLOY_CONFIG_PATH \
--l1-deployments $DEPLOYMENT_OUTFILE \
--l2-allocs $STATE_DUMP_PATH \
--l1-rpc $L1_RPC_URL \
--outfile.l2 $OP_GETH_GENESIS_FILE \
--outfile.rollup $OP_NODE_ROLLUP_FILE

# start anvil auto mine block
curl "$L1_RPC_URL" \
-H 'Content-Type: application/json' \
-d '{
    "jsonrpc": "2.0",
    "method": "evm_setIntervalMining",
    "params": [12],
    "id": 67
}'

git checkout develop && cd $BASE_PATH
