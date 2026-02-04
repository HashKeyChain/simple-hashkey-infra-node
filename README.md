# Simple OP Stack Infra Node

A simplified setup for running a local OP Stack network based on a local L1 (Anvil).

## Required Tools

* Install build tools

```shell
brew install just make jq
```

* Install foundry tool

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup --install stable
```

* Build binaries

```shell
bash scripts/build-binaries.sh
```

## Download Submodules

```shell
git submodule update --init --recursive
```

## Configuration

```shell
# Copy the example config
cp .envrc.example .envrc

# Edit .envrc to configure:
# - L1_CHAIN_ID, L1_BLOCK_TIME, L1_RPC_KIND, L1_RPC_URL
# - L2_CHAIN_ID, L2_BLOCK_TIME
# - OP_GETH_REF: version/branch for op-geth (e.g., v1.101411.1)
# - OP_MONOREPO_REF: version/branch for optimism monorepo (e.g., v1.9.5)
# - OP_CONTRACTS_REF: version/branch for contracts (can differ from OP_MONOREPO_REF)

# Load environment variables
source .envrc
```

## Run Anvil (Local L1)

```shell
bash scripts/run-anvil.sh
```

## Deploy Contracts

```shell
bash scripts/deploy-contracts.sh
```

## Run op-geth

```shell
# Init and run L2 geth
bash scripts/run-op-geth.sh
```

## Run op-node

```shell
bash scripts/run-op-node.sh
```

## Run op-batcher

```shell
bash scripts/run-op-batcher.sh
```

## Run op-proposer

```shell
bash scripts/run-op-proposer.sh
```

## Run op-challenger

```shell
bash scripts/run-op-challenger.sh
```

## Version Configuration

This setup allows you to specify different versions for each component:

| Variable | Description | Example |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth version/branch/commit | `v1.101411.1` |
| `OP_MONOREPO_REF` | optimism monorepo version | `v1.9.5` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `v1.9.5` |
