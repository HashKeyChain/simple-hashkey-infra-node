#!/bin/bash

source .envrc

# Check if already initialized.
superchainConfig=$(cast call --rpc-url $L1_RPC_URL $(jq -r .AnchorStateRegistryProxy $DEPLOYMENT_OUTFILE) "superchainConfig()(address)")
if [ "$superchainConfig" != "0x0000000000000000000000000000000000000000" ]; then
  exit 0
fi

# Get L2 output root.
blockNumber=$(jq -r .faultGameGenesisBlock $DEPLOY_CONFIG_PATH)
faultGameGenesisBlock=$(printf '0x%x' $blockNumber)
result=$(curl $OP_NODE_RPC_URL -H 'Content-Type: application/json' -d "{\"jsonrpc\": \"2.0\",\"method\": \"optimism_outputAtBlock\",\"params\": [\"${faultGameGenesisBlock}\"],\"id\": 67}")
export FAULT_GAME_GENESIS_OUTPUT_ROOT=$(echo $result | jq -r .result.outputRoot)

echo "faultGameGenesisOutputRoot: $FAULT_GAME_GENESIS_OUTPUT_ROOT"

# Init deployment config again.
cd $CONTRACTS_BEDROCK_PATH && git checkout $OP_CONTRACTS_REF
sh scripts/getting-started/config.sh

export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --sig "initializeAnchorStateRegistry()" --skip-simulation

cp $DEPLOY_CONFIG_PATH $DEPLOYMENT_CONFIG_PATH

# Back to the base path.
cd $BASE_PATH
