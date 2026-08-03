# Chain Lifecycle Operations Guide

This guide provides copy-and-paste commands for:

1. Deploying, starting, stopping, and rebuilding the chain.
2. Switching Flashblocks through `off → dry_run → enabled`.
3. Running the P0–P5 verification stages.

Unless stated otherwise, run every command from the repository root. The examples use
the local Anvil environment. For a remote L1, replace `local` with `remote`.

> `chain-setup`, `chain-reset`, and `deploy-jovian-chain --reset` modify or delete chain
> data. Do not run them when you only need to restart an existing chain.

---

## Command Reference

All routine commands are collected in this section. Copy only the subsection required
for the current operation; do not execute this entire section at once.

### A. Initial Setup and Build

```bash
# Enter the repository root.
cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node

# Initialize submodules.
git submodule update --init --recursive

# Create .envrc without overwriting an existing file.
[ -f .envrc ] || cp .envrc.local.example .envrc
$EDITOR .envrc
source .envrc

# Start and check Docker Desktop on macOS.
open -a Docker
docker info

# Build OP Stack and Flashblocks binaries.
bash scripts/build-binaries.sh
bash scripts/flashblocks/build-flashblocks.sh
```

### B. Deploy, Start, and Stop the Chain

```bash
# DESTRUCTIVE: delete the old chain, redeploy, and advance to Jovian.
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y

# Deploy only a Fjord baseline.
bash scripts/deploy-chain/chain-setup.sh local
bash scripts/chain-ops/chain-start.sh local

# Start an existing chain using FLASHBLOCKS_MODE from .envrc.
bash scripts/chain-ops/chain-start.sh local

# Stop L2 services without deleting chain data.
bash scripts/chain-ops/chain-stop.sh

# Stop the local L1 Anvil container.
docker stop anvil-chain

# Check L1, canonical L2, and op-node.
cast bn --rpc-url http://localhost:8545
cast bn --rpc-url http://localhost:8645
cast rpc optimism_syncStatus --rpc-url http://localhost:9545
```

### C. Switch `off → dry_run → enabled`, Then Run P4

If the chain is already running normally in off mode, copy these commands:

```bash
# 1. Safely synchronize op-rbuilder and switch off → dry_run.
# This also starts ws-proxy, op-reth, and verifier op-node in shadow mode.
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local

# 2. Switch dry_run → enabled live. No component is restarted.
bash scripts/flashblocks/switch-dryrun-to-flashblocks-enabled.sh

# 3. Run the user-facing preconfirmation verification.
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=3
```

The equivalent shorter form is:

```bash
bash scripts/flashblocks/switch-off-to-flashblocks-enabled.sh local
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=3
```

The switching scripts do not invoke any verification script. Run P2 and P3 separately
only when their specific gates are required:

```bash
# Run while still in dry_run, before switching to enabled.
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=30

# Run after switching to enabled.
bash scripts/flashblocks/verify/p3-enabled.sh --watch=30
```

### D. Switch `enabled → off`

```bash
sed -i.bak \
  's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=off/' \
  .envrc && rm -f .envrc.bak

bash scripts/chain-ops/chain-stop.sh
bash scripts/chain-ops/chain-start.sh local

# Query twice to confirm that off mode continues producing blocks.
cast bn --rpc-url http://localhost:8645
sleep 4
cast bn --rpc-url http://localhost:8645
```

After running in off mode, re-enter Flashblocks through the complete
`off → dry_run → enabled` sequence. Do not switch directly to enabled.

### E. Verification Commands

```bash
# Automatically select stages for the current Flashblocks mode.
bash scripts/flashblocks/verify/run-all.sh --watch=30

# Quick check; P4 sends no transactions in enabled mode.
bash scripts/flashblocks/verify/run-all.sh --quick

# P0: binaries, versions, genesis, and static configuration.
bash scripts/flashblocks/verify/p0-genesis.sh

# P1: op-rbuilder shadow synchronization.
bash scripts/flashblocks/verify/p1-shadow.sh

# P2: dry_run payload validity and delivery rate.
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=30

# P3: enabled builder adoption, Flashblock production, and broadcast.
bash scripts/flashblocks/verify/p3-enabled.sh --watch=30

# P4: user RPC preconfirmation; sends three test transactions.
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=3

# P4 RPC-only check; sends no transactions.
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=0

# P5: complete local acceptance with a Markdown report.
bash scripts/flashblocks/verify/p5-acceptance.sh --watch=60 --samples=3
```

Do not add destructive drill options to P3 or P5 during routine acceptance. Those drills
intentionally break builder synchronization.

### F. Rebuild and Fork Operations

```bash
# DESTRUCTIVE: stop the chain and delete its data; asks for confirmation.
bash scripts/deploy-chain/chain-reset.sh local

# DESTRUCTIVE: skip confirmation.
bash scripts/deploy-chain/chain-reset.sh local -y

# Activate forks after editing FORK_*_TIME in .envrc.
bash scripts/deploy-chain/activate-fork.sh local

# DESTRUCTIVE: rebuild and advance directly to Jovian.
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

---

## 1. Initial Setup

### 1.1 Initialize Submodules

```bash
git submodule update --init --recursive
```

### 1.2 Create the Local Environment Configuration

```bash
[ -f .envrc ] || cp .envrc.local.example .envrc
$EDITOR .envrc
source .envrc
```

Configure the disposable local test accounts:

```text
DEPLOY_ADDRESS / DEPLOY_PRIVATE_KEY
GS_ADMIN_ADDRESS / GS_ADMIN_PRIVATE_KEY
GS_BATCHER_ADDRESS / GS_BATCHER_PRIVATE_KEY
GS_PROPOSER_ADDRESS / GS_PROPOSER_PRIVATE_KEY
GS_SEQUENCER_ADDRESS / GS_SEQUENCER_PRIVATE_KEY
PRIVATE_KEY
```

Never use production private keys. `.envrc` is ignored by Git.

For a new local chain, keep:

```bash
export CUSTOM_GAS_TOKEN_ADDRESS=
export FORK_FJORD_TIME=0
export FORK_GRANITE_TIME=
export FORK_HOLOCENE_TIME=
export FORK_ISTHMUS_TIME=
export FORK_JOVIAN_TIME=
export FLASHBLOCKS_MODE=off
```

Do not prepend a downloaded user-local Go toolchain:

```bash
export PATH=$HOME/.local-go-toolchains/.../bin:$PATH
```

macOS may block binaries from that directory and display an authorization dialog. Use a
system Go installation:

```bash
command -v go
go version
```

### 1.3 Check Dependencies

Local deployment requires Docker Desktop, Foundry, Go, Rust, make, jq, and openssl.

```bash
open -a Docker

docker info
forge --version
cast --version
go version
rustc --version
jq --version
```

`docker info` must succeed before running a local deployment.

---

## 2. Build Components

### 2.1 Build OP Stack Go Components

```bash
bash scripts/build-binaries.sh
```

The output under `bin/` includes:

```text
op-geth
op-node
op-batcher
op-proposer
op-challenger
cannon / op-program when USE_FAULT_PROOFS=true
```

### 2.2 Build Flashblocks Rust Components

```bash
bash scripts/flashblocks/build-flashblocks.sh
```

The output under `bin/` includes:

```text
rollup-boost
flashblocks-websocket-proxy
op-rbuilder
op-reth
```

---

## 3. Deploy the Chain

### 3.1 Recommended: Rebuild and Advance to Jovian

The following command stops the old chain and deletes `data/` and
`config/<context>/`. Run it only when a full rebuild is intended:

```bash
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

It performs:

```text
chain-reset
→ start Anvil
→ deploy L1 contracts and CGT
→ generate Fjord genesis and rollup configuration
→ start L2
→ activate Granite, Holocene, Isthmus, and Jovian
→ verify the target fork
```

Confirm Jovian:

```bash
cast call 0x420000000000000000000000000000000000000F \
  "isJovian()(bool)" \
  --rpc-url http://localhost:8645
```

Expected result:

```text
true
```

### 3.2 Deploy Only the Fjord Baseline

```bash
bash scripts/deploy-chain/chain-setup.sh local
bash scripts/chain-ops/chain-start.sh local
```

`chain-setup` starts local Anvil, deploys the contracts, and generates:

```text
config/<context>/artifact.json
config/<context>/genesis.json
config/<context>/rollup.json
config/<context>/state-dump-latest.json
```

To activate later forks, edit `FORK_*_TIME` in `.envrc`, then run:

```bash
bash scripts/deploy-chain/activate-fork.sh local
```

---

## 4. Daily Start and Stop

### 4.1 Start Using the Current Mode

```bash
bash scripts/chain-ops/chain-start.sh local
```

`FLASHBLOCKS_MODE` selects the topology:

```text
off      : op-node connects directly to op-geth
dry_run  : the full topology runs in shadow mode, but op-geth payloads remain canonical
enabled  : the same topology runs, and builder payloads are adopted
```

### 4.2 Basic Health Checks

```bash
# L1
cast bn --rpc-url http://localhost:8545

# Canonical L2 / op-geth
cast bn --rpc-url http://localhost:8645

# op-node
cast rpc optimism_syncStatus --rpc-url http://localhost:9545
```

Additional checks in enabled mode:

```bash
# Flashblocks user RPC / op-reth
cast bn --rpc-url http://localhost:8745

# Current Flashblocks pending block
cast rpc eth_getBlockByNumber pending true \
  --rpc-url http://localhost:8745
```

### 4.3 Stop L2

```bash
bash scripts/chain-ops/chain-stop.sh
```

Local Anvil remains running by default. Stop it separately if required:

```bash
docker stop anvil-chain
```

---

## 5. Flashblocks Mode Switching

### 5.1 Required Transition Order

Do not switch a chain that has been running in off mode directly to enabled.

While Flashblocks is off, op-rbuilder does not continuously follow the chain head. A
direct switch can cause repeated `Unknown payload` errors and fallback to op-geth.
Always use:

```text
off → switch-to-flashblocks-dryrun → verify dry_run → full enabled restart
```

`disabled` is not a lossless rollback mode. It stops op-rbuilder from receiving Engine
updates, after which the missing history is not backfilled. Do not use it for routine
rollback or testing.

### 5.2 Switch `off → dry_run`

```bash
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local
```

The script:

```text
starts op-rbuilder and a temporary builder op-node
→ waits for op-rbuilder to reach the chain head
→ pauses the sequencer
→ catches up exactly to the frozen height
→ stops the builder op-node
→ starts rollup-boost in dry_run mode
→ reconnects the primary op-node through rollup-boost
→ starts ws-proxy, op-reth, and verifier op-node
→ resumes block production
```

If Jovian or Holocene was recently activated, the script may wait for the safe op-node
restart window before switching. The chain continues producing blocks in off mode during
this wait. The default maximum wait is 1,800 seconds.

The user-facing topology is already running in dry_run so the later enabled transition
does not require a restart. However, op-reth serves shadow builder previews in dry_run;
do not route production user traffic to port 8745 until the mode is enabled.

Verify dry_run:

```bash
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=30
```

### 5.3 Switch `dry_run → enabled`

```bash
bash scripts/flashblocks/switch-dryrun-to-flashblocks-enabled.sh
```

This changes the rollup-boost execution mode live and persists
`FLASHBLOCKS_MODE=enabled` in `.envrc`. All Flashblocks components keep running.

Verify both paths:

```bash
bash scripts/flashblocks/verify/p3-enabled.sh --watch=30
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=3
```

P4 uses `DEPLOY_PRIVATE_KEY`, submits test transactions through op-reth, and requires:

```text
transaction appears in op-reth pending
→ transaction later receives a canonical op-geth receipt
→ pending observation occurs in less than one second
```

Run an RPC-only P4 check without sending transactions:

```bash
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=0
```

### 5.4 Switch `off → enabled` in One Command

```bash
bash scripts/flashblocks/switch-off-to-flashblocks-enabled.sh local
```

This reuses the complete off-to-dry_run synchronization procedure and then performs the
live dry_run-to-enabled switch. It does not run P2, P3, or P4.

### 5.5 Switch `enabled → off`

```bash
sed -i.bak \
  's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=off/' \
  .envrc && rm -f .envrc.bak

bash scripts/chain-ops/chain-stop.sh
bash scripts/chain-ops/chain-start.sh local
```

Confirm continued block production:

```bash
cast bn --rpc-url http://localhost:8645
sleep 4
cast bn --rpc-url http://localhost:8645
```

After running in off mode, always re-enter Flashblocks through `off → dry_run → enabled`.

---

## 6. Verification

Automatically select the appropriate stages:

```bash
bash scripts/flashblocks/verify/run-all.sh --watch=30
```

Run a quick check:

```bash
bash scripts/flashblocks/verify/run-all.sh --quick
```

Run the stages individually:

```bash
bash scripts/flashblocks/verify/p0-genesis.sh
bash scripts/flashblocks/verify/p1-shadow.sh
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=30
bash scripts/flashblocks/verify/p3-enabled.sh --watch=30
bash scripts/flashblocks/verify/p4-user-facing.sh --samples=3
bash scripts/flashblocks/verify/p5-acceptance.sh --watch=60 --samples=3
```

P2 and P3 normally observe for 30 seconds. A longer window such as `--watch=300` is
useful for stability testing but is not required for routine acceptance.

Do not run this during routine verification:

```bash
bash scripts/flashblocks/verify/p3-enabled.sh --fallback-drill
```

The drill intentionally causes op-rbuilder to fall behind. Restoring it requires the
complete `off → dry_run` synchronization flow.

---

## 7. Rebuild the Chain

Stop while preserving data:

```bash
bash scripts/chain-ops/chain-stop.sh
```

Destructively reset the chain:

```bash
bash scripts/deploy-chain/chain-reset.sh local
```

Skip confirmation:

```bash
bash scripts/deploy-chain/chain-reset.sh local -y
```

Rebuild and advance to Jovian:

```bash
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

---

## 8. Troubleshooting

### 8.1 Docker Daemon Is Not Running

Error:

```text
Cannot connect to the Docker daemon
```

Resolution:

```bash
open -a Docker
docker info
```

Retry deployment only after `docker info` succeeds.

### 8.2 macOS Displays a Go Authorization Dialog

The blocked path usually resembles:

```text
~/.local-go-toolchains/go1.22.12/bin/go
```

Do not authorize that downloaded binary. Remove the `.envrc` entry that prepends it,
then select a system Go installation:

```bash
export PATH="/usr/local/go/bin:/opt/homebrew/bin:$PATH"
unset GOROOT
hash -r

command -v go
go version
```

`deploy-contracts.sh` already selects a usable system Go executable automatically.

### 8.3 op-node Reports `unknown batch validity type: 4`

After Holocene activation, an op-node restart rewinds one `channel_timeout`. The safe
head's L1 origin must move beyond the fork boundary plus 50 L1 blocks.

With:

```text
L1_BLOCK_TIME=6
MAX_CHANNEL_DURATION=5
```

the restart window normally opens after approximately five to six minutes.
`switch-to-flashblocks-dryrun.sh` waits automatically; other restart paths require a
manual wait.

### 8.4 op-rbuilder Repeatedly Reports `Unknown payload`

This normally means op-rbuilder fell behind while Flashblocks was off, disabled, or
partially restarted. Missing history is not backfilled.

Recover through off mode and a complete dry_run synchronization:

```bash
sed -i.bak \
  's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=off/' \
  .envrc && rm -f .envrc.bak

bash scripts/chain-ops/chain-stop.sh
bash scripts/chain-ops/chain-start.sh local
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local
```

### 8.5 Anvil Container Name Conflict

```bash
docker rm -f anvil-chain
```

Then rerun `chain-setup` or `chain-start`.

---

## 9. Common Ports

```text
8545  Anvil L1 RPC
8645  op-geth canonical HTTP RPC
8651  op-geth Engine API
9545  primary op-node RPC
8551  rollup-boost Engine / transaction proxy
5555  rollup-boost debug RPC; trusted local access only
8661  op-rbuilder Engine API
8663  op-rbuilder HTTP RPC
1111  op-rbuilder Flashblocks output
1112  rollup-boost Flashblocks broadcast
1113  ws-proxy Flashblocks broadcast
8745  op-reth user HTTP RPC
8751  op-reth Engine API
9555  verifier op-node RPC
```

Never expose management or Engine API ports to the public internet. Restrict them with
a firewall or private network in production.

For architecture and verification details, see:

```text
doc/flashblocks_local_impl.md
scripts/flashblocks/verify/README.md
```
