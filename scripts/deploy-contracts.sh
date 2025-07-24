#!/bin/bash

source .envrc

# Build and deploy contracts
cd $CONTRACTS_BEDROCK_PATH
git checkout op-contracts/v2.0.0-beta.2
forge install && forge build
forge script scripts/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --slow

# Create l2chain genesis state and load in file.
export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()'

cd $BASE_PATH