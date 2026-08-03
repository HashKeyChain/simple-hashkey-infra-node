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

> When `USE_FAULT_PROOFS=true`, the script also builds the fault-proof dependencies `cannon` and `op-program`,
> and uses `reproducible-prestate` (**Docker required**; it pulls the official `golang` image) to generate `prestate.json` /
> `prestate-proof.json`. Its `.pre` must equal `faultGameAbsolutePrestate` in the deploy-config;
> otherwise, op-challenger cannot participate in the deployed dispute game.

## Configuration

```shell
# Local Anvil L1 config
cp .envrc.local.example .envrc

# Edit .envrc to configure versions, ports and fork times for each component
source .envrc
```

There is no separate example file for a remote/testnet L1. Copy `.envrc.local.example`, then update `L1_RPC_URL`,
`L1_CHAIN_ID`, and each account's private key (remote accounts must be funded).

## Script Layout

```
scripts/deploy-chain/   Deployment and rebuild: chain-setup / activate-fork / chain-reset / deploy-jovian-chain
scripts/chain-ops/      Runtime orchestration and component launchers: chain-start / chain-stop / run-op-*
scripts/flashblocks/    Flashblocks components and phase transitions: build / run-* / switch-to-flashblocks-dryrun
scripts/jovian/         Jovian SystemConfig parameter configuration and validation
```

## Docs

- **`doc/chain-lifecycle.md` — Chain lifecycle operations manual (start here for setup from scratch, fork activation, Flashblocks integration, and rebuilds)**
- `doc/flashblocks_local_impl.md` — Local Flashblocks integration plan and validation gates
- `scripts/flashblocks/verify/README.md` — Flashblocks validation scripts (repeatable gate-by-gate execution from P0 to P3)
- `doc/LOCAL_CGT_JOVIAN_UPGRADE_RUNBOOK.md` — CGT + Jovian runbook for a local Anvil L1
- `doc/remote_l1_cgt_jovian_deploy_runbook.md` — Deployment runbook for a remote/testnet L1

## Run Anvil (Local L1)

```shell
bash scripts/chain-ops/run-anvil.sh
```

## Deploy Contracts

```shell
# Local Anvil L1
bash scripts/deploy-chain/chain-setup.sh local

# Existing remote/testnet L1
bash scripts/deploy-chain/chain-setup.sh remote
```

## Start / stop the chain

```shell
bash scripts/chain-ops/chain-start.sh local
bash scripts/chain-ops/chain-stop.sh
```

`chain-start.sh` uses `FLASHBLOCKS_MODE` in `.envrc` (`off` / `dry_run` / `enabled`) to determine
which additional Flashblocks components to start; `chain-stop.sh` stops them as well. See Section 6 of `doc/chain-lifecycle.md`.

## Run individual components (`run-op-*.sh`)

`scripts/chain-ops/run-op-<component>.sh` is the single source of truth for each component's flags. It is invoked by
`chain-start.sh` for orchestration and can also be run independently for debugging or restarts. Before running it independently,
run `bash scripts/deploy-chain/chain-setup.sh <local|remote>` to generate the configuration, and ensure that the op-geth datadir
has been initialized and the JWT has been generated (`chain-start.sh` does this idempotently on the first run; alternatively,
follow the `op-geth init` step in `chain-start.sh` to initialize it manually).

```shell
# op-geth (no longer runs op-geth init; the datadir must already be initialized)
bash scripts/chain-ops/run-op-geth.sh

# op-node
bash scripts/chain-ops/run-op-node.sh

# op-batcher
bash scripts/chain-ops/run-op-batcher.sh

# op-proposer
bash scripts/chain-ops/run-op-proposer.sh
```

## Run op-challenger

When `USE_FAULT_PROOFS=true`, `chain-start.sh` **automatically starts** op-challenger after starting the chain
(use `SKIP_CHALLENGER=1 bash scripts/chain-ops/chain-start.sh` to skip it). It can also be run independently:

```shell
bash scripts/chain-ops/run-op-challenger.sh              # Foreground
bash scripts/chain-ops/run-op-challenger.sh --background # Background; writes to data/pids and data/logs
```

Prerequisites and key points:

- The fault-proof binaries have been built: `bin/cannon`, `bin/op-program`, and `bin/prestate.json`
  (`build-binaries.sh` builds them when `USE_FAULT_PROOFS=true`).
- `trace-type` follows `GAME_TYPE`: `1`→`permissioned`, `0`→`cannon`. It must match the deployed `respectedGameType`
  and op-proposer's `--game-type`.
- Prestate consistency: before startup, the script verifies that `.pre` in `bin/prestate-proof.json` equals
  `faultGameAbsolutePrestate` in the deploy-config; it exits with an error if they differ.
- L1 Beacon: `--l1-beacon` is required. Local Anvil has no Beacon API, so it falls back to the L1 RPC by default.
  Calldata DA normally does not trigger blob requests. If startup fails because of the beacon, point it to a real Beacon API
  or run a fake beacon and override the URL with `L1_BEACON_URL`.
- In permissioned mode, the challenger address must be the challenger authorized at deployment. Use
  `OP_CHALLENGER_PRIVATE_KEY` to override the default private key.

## Version Configuration

Each component can be configured with its own version/branch/commit:

| Variable | Description | Example |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth version | `v1.101605.0` |
| `OP_NODE_REF` | op-node version (local CGT/Jovian custom branch) | `cgt-jovian/v1.16.5` |
| `OP_BATCHER_REF` | op-batcher version | `op-batcher/v1.16.3` |
| `OP_PROPOSER_REF` | op-proposer version | `op-proposer/v1.10.0` |
| `OP_CHALLENGER_REF` | op-challenger version (same branch as op-node; must recognize the latest L1 head) | `cgt-jovian/v1.16.5` |
| `OP_PROGRAM_REF` | op-program version (from the same source as the contracts) | `op-contracts/v2.0.0-beta.3` |
| `CANNON_REF` | cannon version (from the same source as the contracts) | `op-contracts/v2.0.0-beta.3` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `op-contracts/v2.0.0-beta.3` |

> The refs for the fault-proof components (`op-challenger`/`op-program`/`cannon`) and `OP_CONTRACTS_REF` should point to
> **the same monorepo commit**, ensuring that the MIPS implementation and prestate match the deployed contracts. Note that
> official tag snapshots do not include this chain's CGT/Jovian execution customizations. To compute the correct state root
> for the customized chain, use an op-program build that contains the same customizations.

## Flashblocks components (optional)

The Rust components are built from submodule source and are only required when running Flashblocks:

```shell
bash scripts/flashblocks/build-flashblocks.sh
```

| Variable | Description | Example |
|----------|-------------|---------|
| `ROLLUP_BOOST_REF` | rollup-boost + flashblocks-websocket-proxy (same submodule and tag) | `v0.7.11` |
| `OP_RBUILDER_REF` | op-rbuilder (Flashblocks builder) | `op-rbuilder/v0.2.13` |
| `OP_RETH_REF` | op-reth (Flashblocks-aware RPC replica) | `v1.9.3` |

Use the surgical switch script to transition from `off` to `dry_run` (op-rbuilder starts once and remains running throughout):

```shell
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local
```

See Sections 6, 8, and 10 of `doc/chain-lifecycle.md` for phase definitions, transition steps, port assignments, and troubleshooting.

Validate after the switch:

```bash
bash scripts/flashblocks/verify/run-all.sh
```

The script automatically selects the appropriate validation gates for rollup-boost's current execution mode (P0 build and
genesis alignment, P1 shadow synchronization, P2 `dry_run` reconciliation and transaction coverage, and P3 `enabled` mode
and fallback capability). See `scripts/flashblocks/verify/README.md` for each script's responsibilities and pass criteria.
