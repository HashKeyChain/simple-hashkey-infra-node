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
bash scripts/run-anvil.sh
```

# Create accounts and configs
```shell
bash scripts/create-accounts.sh
```

# Deploy L1 contracts
```shell
bash scripts/deploy-contracts.sh
```

# Create l2chain genesis file and rollup file.
```shell
bash scripts/init-l2chain.sh
```

# Init and run op-geth
```shell
# Init and run l2geth.
bash scripts/run-l2geth.sh
```

# Start op-node
```shell
bash scripts/run-op-node.sh
```

# Start op-proposer
```shell
bash scripts/run-op-proposer.sh
```
