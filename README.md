# Clone optimism and checkout branch
```shell
git submodule update --init --recursive
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
sh scripts/create-accounts.sh
```

# Deploy L1 contracts
```shell
sh scripts/deploy-contracts.sh
```

# Create l2chain genesis file and rollup file.
```shell
sh scripts/init-l2chain.sh
```

# Init and run op-geth
```shell
# Init and run l2geth.
sh scripts/run-l2geth.sh
```

# Start op-node
```shell
sh scripts/run-op-node.sh
```

# Start op-proposer
```shell
sh scripts/run-op-proposer.sh
```
