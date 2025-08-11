#!/bin/bash

source .envrc

# Start Anvil with the specified timeout to get the state of deployed contracts.
nohup anvil --chain-id=$L1_CHAIN_ID --accounts=20 --dump-state config/$DEPLOYMENT_CONTEXT.json &

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

# Stop Anvil process.
sleep 1
pkill -f anvil

git checkout develop && cd $BASE_PATH
