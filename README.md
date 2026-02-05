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

# Edit .envrc to configure versions for each component
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

Each component can be configured with its own version/branch/commit:

| Variable | Description | Example |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth version | `v1.101411.1` |
| `OP_NODE_REF` | op-node version | `v1.9.5` |
| `OP_BATCHER_REF` | op-batcher version | `v1.9.5` |
| `OP_PROPOSER_REF` | op-proposer version | `v1.9.5` |
| `OP_CHALLENGER_REF` | op-challenger version | `v1.9.5` |
| `OP_PROGRAM_REF` | op-program version | `v1.9.5` |
| `CANNON_REF` | cannon version | `v1.9.5` |
| `OP_DEPLOYER_REF` | op-deployer version | `v1.9.5` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `v1.9.5` |
