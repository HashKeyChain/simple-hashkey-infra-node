# Simple Hashkey Infra Node

One-click OP Stack L2 chain launcher. Supports both local development (Anvil L1) and remote deployment (e.g. Sepolia).

## Prerequisites

- [Go](https://go.dev/dl/) 1.21+
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)
- [Node.js](https://nodejs.org/) 16+
- [jq](https://jqlang.github.io/jq/download/)
- Git with submodules initialized (`git submodule update --init --recursive`)

## Quick Start

### 1. Configure environment

```bash
cp .envrc.example .envrc
```

Edit `.envrc` — key fields to change:

| Field | Description |
|-------|-------------|
| `DEPLOY_ADDRESS` / `DEPLOY_PRIVATE_KEY` | Account that deploys contracts (unused in local mode, Anvil funds automatically) |
| `GS_ADMIN_ADDRESS` / `GS_ADMIN_PRIVATE_KEY` | Chain admin, owns the ProxyAdmin Safe |
| `GS_BATCHER_*` / `GS_PROPOSER_*` / `GS_SEQUENCER_*` | Operational accounts |
| `L1_RPC_URL` | L1 endpoint. `localhost:8545` = local Anvil; remote URL = server mode |
| `L1_RPC_KIND` | RPC provider type. Use `basic` for Anvil or unknown providers |
| `L1_BLOCK_TIME` | Must match the actual L1 block time (12 for Ethereum/Sepolia) |
| `USE_CUSTOM_GAS_TOKEN` | `true` to use an ERC-20 as L2 gas token |
| `USE_FAULT_PROOFS` | **Must be `false` for initial deployment.** Upgrade later. |

### 2. Launch the chain

```bash
# Local mode — starts Anvil as L1, deploys contracts, launches all L2 services
bash scripts/chain-up.sh local

# Server mode — uses L1_RPC_URL from .envrc, deploys contracts, launches L2 services
bash scripts/chain-up.sh server
```

If you omit the argument, the script auto-detects mode from `L1_RPC_URL`:
```bash
bash scripts/chain-up.sh    # auto-detect
```

### 3. Stop the chain

```bash
bash scripts/chain-stop.sh
```

### 4. Restart (without re-deploying contracts)

```bash
bash scripts/chain-start.sh local   # or server
```

## What `chain-up.sh` Does

```
chain-up.sh [local|server]
  │
  ├── Step 1: build-components.sh
  │     Build op-geth / op-node / op-batcher / op-proposer from source
  │     using *_REF versions in .envrc. Binaries go to bin/.
  │     Skip: SKIP_BUILD=1
  │
  ├── Step 2: chain-setup.sh  (only if config missing or env changed)
  │     ├── [local] Start Anvil if not running
  │     ├── deploy-contracts.sh → deploy L1 contracts via forge
  │     └── Generate genesis.json, rollup.json, artifact.json
  │     Force: FORCE_SETUP=1
  │
  └── Step 3: chain-start.sh
        ├── op-geth   (L2 execution engine)
        ├── op-node   (L2 consensus / derivation)
        ├── op-batcher (submit L2 batches to L1)
        └── op-proposer (submit output roots / dispute games to L1)
```

The script saves an environment marker in `data/.last_chain_env`. If the mode or `L1_RPC_URL` changes between runs, it automatically re-runs `chain-setup.sh`.

## Server Mode (Sepolia / Production L1)

For deploying to a real L1 like Sepolia:

1. **Fund accounts** — the admin, batcher, and proposer accounts need ETH on L1. The script will check balances and prompt you if insufficient.

2. **Set `.envrc`** for your target network:
   ```bash
   export L1_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
   export L1_RPC_KIND=alchemy   # or infura, basic, etc.
   export L1_CHAIN_ID=11155111
   export USE_FAULT_PROOFS=false
   ```

3. **Run**:
   ```bash
   bash scripts/chain-up.sh server
   ```

4. **Logs** are in `data/logs/` — check `op-node.log`, `op-batcher.log`, `op-proposer.log` for status.

## Upgrading to Fault Proofs

After the chain is running with L2OutputOracle, upgrade to PermissionedDisputeGame:

1. Update `.envrc`:
   ```bash
   export USE_FAULT_PROOFS=true
   export GAME_TYPE=1
   ```

2. Run the upgrade script:
   ```bash
   bash scripts/upgrade-to-fault-proofs.sh
   ```

This upgrades OptimismPortal → OptimismPortal2, deploys AnchorStateRegistry, and switches op-proposer to submit dispute games instead of output roots.

## Component Versions

All versions are defined in `.envrc` and used by `build-components.sh`:

| Component | Variable | Example |
|-----------|----------|---------|
| op-geth | `OP_GETH_REF` | `v1.101605.0` |
| op-node | `OP_NODE_REF` | `feature/upgrade_cgt` |
| op-batcher | `OP_BATCHER_REF` | `op-batcher/v1.16.3` |
| op-proposer | `OP_PROPOSER_REF` | `op-proposer/v1.10.0` |
| contracts | `OP_CONTRACTS_REF` | `op-contracts/v2.0.0-beta.2` |

`build-components.sh` uses `git worktree` to build monorepo components from their respective refs without affecting the contract source tree.

## Directory Structure

```
.
├── .envrc              # Environment config (copy from .envrc.example)
├── scripts/
│   ├── chain-up.sh     # One-click launcher
│   ├── chain-setup.sh  # Deploy contracts + generate config
│   ├── chain-start.sh  # Start all L2 services
│   ├── chain-stop.sh   # Stop all services
│   ├── build-components.sh      # Build binaries from source
│   ├── deploy-contracts.sh      # L1 contract deployment
│   ├── upgrade-to-fault-proofs.sh  # L2OO → Fault Proofs upgrade
│   └── initialize-anchorState.sh   # AnchorStateRegistry init helper
├── bin/                # Built binaries (op-geth, op-node, etc.)
├── config/             # Generated chain config per deployment context
│   ├── local/          # Config for local mode
│   └── getting-started/ # Config for server mode (default context)
├── data/
│   ├── logs/           # Service logs
│   ├── pids/           # PID files for running services
│   └── op-geth/        # op-geth chain data
├── optimism/           # OP Stack monorepo (git submodule)
└── op-geth/            # op-geth repo (git submodule)
```

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `SKIP_BUILD` | `0` | Set `1` to skip building binaries |
| `FORCE_BUILD` | `0` | Set `1` to force rebuild all components |
| `FORCE_SETUP` | `0` | Set `1` to force re-deploy contracts |
| `CLEAN_OP_GETH_DATADIR` | `0` | Set `1` to wipe op-geth data on start |
| `SKIP_GIT_CHECKOUT` | `0` | Set `1` to skip `git checkout` in deploy-contracts (preserves local contract modifications) |
| `GOPROXY` | (system) | Go module proxy, e.g. `https://goproxy.cn,direct` |

## Troubleshooting

**`safedb: resource temporarily unavailable`** — orphaned op-node process. Run `bash scripts/chain-stop.sh` then retry.

**`Scheduled sequencer action delta` keeps growing** — L1_BLOCK_TIME mismatch. Ensure it matches the actual L1 block time (12 for mainnet/Sepolia, or your Anvil config). Requires re-deployment (`FORCE_SETUP=1`).

**`Method not found` from op-node** — set `L1_RPC_KIND=basic` in `.envrc`.

**`call to non-contract address` during deployment** — `USE_FAULT_PROOFS` is `true`. Set to `false` for initial deployment.

**Forge sandbox write error** — the upgrade script copies artifacts to a forge-writable location automatically. If issues persist, check `foundry.toml` `fs_permissions`.
