# Clone optimism and checkout branch
```shell
git submodule update optimism
```

# Edit .envrc
```shell
# Based on `optimism` root folder.
cp .envrc.example .envrc

# vim .envrc
L1_CHAIN_ID=11155111
L1_BLOCK_TIME=12
L1_RPC_KIND=alchemy
L1_RPC_URL=http://localhost:8545
L2_CHAIN_ID=42069
L2_BLOCK_TIME=2
DEPLOYMENT_CONTEXT=getting-started

# load environment variables
source .envrc
```

# Run anvil
```shell
sh scripts/run-anvil.sh
```

# Create accounts and configs
```shell
cd $CONTRACTS_BEDROCK_PATH
git checkout op-contracts/v2.0.0-beta.2
sh scripts/getting-started/wallets.sh >> $BASE_PATH/.envrc
cd $BASE_PATH && source .envrc && cd -
sh scripts/getting-started/config.sh
```

# Send some ether to the accounts
```shell
# Based on `packages/contracts-bedrock` folder.
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_ADMIN_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_BATCHER_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_PROPOSER_ADDRESS --value 2ether --rpc-url http://localhost:8545
cast send --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 $GS_SEQUENCER_ADDRESS --value 2ether --rpc-url http://localhost:8545
```

# Build and deploy contracts
```shell
cd $CONTRACTS_BEDROCK_PATH
git checkout op-contracts/v2.0.0-beta.2
forge install && forge build
forge script scripts/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --slow
```

# Create l2chain genesis state and load in file.
```shell
cd $CONTRACTS_BEDROCK_PATH
export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()'
```

# Create l2chain genesis file and rollup file.
```shell
# Use v1.13.2 branch and go to op-node folder in the same terminal.
cd $OP_NODE_PATH
git checkout v1.13.2
go run cmd/main.go genesis l2 \
--deploy-config $DEPLOY_CONFIG_PATH \
--l1-deployments $DEPLOYMENT_OUTFILE \
--l2-allocs $STATE_DUMP_PATH \
--l1-rpc $L1_RPC_URL \
--outfile.l2 $OP_GETH_GENESIS_FILE \
--outfile.rollup $OP_NODE_ROLLUP_FILE
```

# Init and run op-geth
```shell
# Init and run l2geth.
cd $BASE_PATH && sh scripts/run-l2geth.sh
```

# Start op-node
```shell
cd $BASE_PATH && sh scripts/run-op-node.sh
```

# Start op-proposer
```shell
cd $BASE_PATH && sh scripts/run-op-proposer.sh
```
