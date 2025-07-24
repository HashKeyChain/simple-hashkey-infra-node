#!/bin/bash

source .envrc

# go back if unnormal exit
trap "git checkout develop && cd ${BASE_PATH}" EXIT INT KILL ERR

# Create accounts and configs
cd $CONTRACTS_BEDROCK_PATH
git checkout op-contracts/v2.0.0-beta.2
sh scripts/getting-started/wallets.sh >> $BASE_PATH/.envrc
cd $BASE_PATH && source .envrc && cd -
sh scripts/getting-started/config.sh

# Send some ether to the accounts
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_ADMIN_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_BATCHER_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_PROPOSER_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_SEQUENCER_ADDRESS --value 2ether --rpc-url http://localhost:8545

git checkout develop && cd $BASE_PATH