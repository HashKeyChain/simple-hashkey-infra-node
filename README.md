# required relate tools

* install build tools

```shell
brew install just make jq
```

* install foundry tool

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup --install stable
```

* build binaries

```shell
bash scripts/build-binaries.sh
```

# Download submodules

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

# Deploy contracts

```shell
bash scripts/deploy-contracts.sh
```

# Run verse-geth

```shell
# Init and run l2geth.
bash scripts/run-verse-geth.sh
```

# Run verse-node

```shell
bash scripts/run-verse-node.sh
```

# Run verse-proposer

```shell
bash scripts/run-verse-proposer.sh
```

# Run verse-batcher

```shell
bash scripts/run-verse-batcher.sh
```