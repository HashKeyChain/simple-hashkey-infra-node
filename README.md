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

## Download Submodules

Pull submodules first, then build binaries (the build depends on submodule sources).

```shell
git submodule update --init --recursive
```

## Build binaries

```shell
bash scripts/build-binaries.sh
```

> If `USE_FAULT_PROOFS=true`, the script additionally builds the fault-proof
> dependencies `cannon` and `op-program`, and generates `prestate.json` /
> `prestate-proof.json` via `reproducible-prestate` (**requires Docker**, pulls
> the official `golang` image). Its `.pre` must equal the deploy-config's
> `faultGameAbsolutePrestate`, otherwise op-challenger cannot participate in the
> deployed dispute game.

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
bash scripts/chain-setup.sh remote
```

## Run individual components (`run-op-*.sh`)

`scripts/run-op-<component>.sh` is the single source of truth for each
component's flags. It is both invoked by the `chain-start.sh` orchestration and
can be run standalone for debugging/restarting. Before running standalone, first
run `bash scripts/chain-setup.sh <local|remote>` to generate the config, and make
sure the op-geth datadir is initialized and the JWT is generated (done
idempotently by `chain-start.sh` on first run; or initialize manually following
the `op-geth init` step in `chain-start.sh`).

```shell
# op-geth (does not run `op-geth init`; datadir must already be initialized)
bash scripts/run-op-geth.sh

# op-node
bash scripts/run-op-node.sh

# op-batcher
bash scripts/run-op-batcher.sh

# op-proposer
bash scripts/run-op-proposer.sh
```

## Run op-challenger

When `USE_FAULT_PROOFS=true`, `chain-start.sh` **automatically starts**
op-challenger after bringing up the chain (skip with
`SKIP_CHALLENGER=1 bash scripts/chain-start.sh`). It can also be run standalone:

```shell
bash scripts/run-op-challenger.sh              # foreground
bash scripts/run-op-challenger.sh --background # background, writes data/pids, data/logs
```

Prerequisites and key points:

- Fault-proof binaries are built: `bin/cannon`, `bin/op-program`, `bin/prestate.json`
  (built by `build-binaries.sh` when `USE_FAULT_PROOFS=true`).
- `trace-type` follows `GAME_TYPE`: `1`→`permissioned`, `0`→`cannon`, kept consistent
  with `respectedGameType` at deploy time and op-proposer's `--game-type`.
- prestate consistency: before starting, the script checks whether the `.pre` of
  `bin/prestate-proof.json` equals the deploy-config's `faultGameAbsolutePrestate`;
  it exits with an error if they differ.
- L1 Beacon: `--l1-beacon` is required. Local anvil has no Beacon API and falls back
  to the L1 RPC by default; under calldata DA, blob requests are usually not
  triggered. If beacon fails to start, point it to a real Beacon or run a fake
  beacon and override with `L1_BEACON_URL`.
- In permissioned mode the challenger address must be the challenger authorized at
  deploy time; override the default private key with `OP_CHALLENGER_PRIVATE_KEY`.

## Version Configuration

Each component can be configured with its own version/branch/commit:

| Variable | Description | Example |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth version | `v1.101411.1` |
| `OP_NODE_REF` | op-node version | `v1.9.5` |
| `OP_BATCHER_REF` | op-batcher version | `v1.9.5` |
| `OP_PROPOSER_REF` | op-proposer version | `v1.9.5` |
| `OP_CHALLENGER_REF` | op-challenger version (same branch as op-node, must recognize the latest L1 head) | `cgt-jovian/v1.16.5` |
| `OP_PROGRAM_REF` | op-program version (tracks the same source as contracts) | `op-contracts/v2.0.0-beta.3` |
| `CANNON_REF` | cannon version (tracks the same source as contracts) | `op-contracts/v2.0.0-beta.3` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `op-contracts/v2.0.0-beta.3` |

> The refs of the fault-proof components (`op-challenger`/`op-program`/`cannon`)
> should point to the **same monorepo commit** as `OP_CONTRACTS_REF`, so that the
> MIPS implementation and prestate match the deployed contracts. Note that the
> official tag snapshots do not include this chain's CGT/Jovian execution
> customizations; to compute correct state roots for the customized chain, use an
> op-program that contains the same customizations.
