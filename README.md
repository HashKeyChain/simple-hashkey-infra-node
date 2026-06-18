# Simple OP Stack Infra Node

A simplified setup for deploying and running an OP Stack L2 on either a local
L1 (Anvil) or an existing remote/testnet L1 RPC.

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
# Local Anvil L1 config
cp .envrc.local.example .envrc

# Or remote/testnet L1 config
cp .envrc.testnet.example .envrc

# Edit .envrc to configure versions for each component
source .envrc
```

## Runbooks

- Local Anvil L1: `doc/local_cgt_jovian_upgrade_runbook.md`
- Remote/testnet L1: `doc/remote_l1_cgt_jovian_deploy_runbook.md`

## Run Anvil (Local L1)

```shell
bash scripts/run-anvil.sh
```

## Deploy Contracts

```shell
# Local Anvil L1
bash scripts/chain-setup.sh local

# Existing remote/testnet L1
bash scripts/chain-setup.sh server
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
