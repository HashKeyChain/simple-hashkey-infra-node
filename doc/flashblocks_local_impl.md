# Local Flashblocks Integration Plan (simple project)

> Scope: **local private-network verification only**. Start from the Jovian chain deployed with
> `scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y`, reuse its `config/local-mainnet/`, and **do not redeploy the chain**.
> Use `scripts/chain-ops/chain-start.sh` to start services, integrate rollup-boost + op-rbuilder +
> flashblocks-websocket-proxy + flashblocks-aware RPC locally, and verify the complete system.
> Existing op-node, op-geth, and contract code remain unchanged.
>
> **Flashblocks does not redeploy the chain**: it changes only which services run and where op-node's `--l2` points. Startup flow:
> `build-flashblocks.sh` (build) → set `FLASHBLOCKS_MODE` in `.envrc` → `chain-ops/chain-stop.sh && chain-ops/chain-start.sh local`.
>
> **Local-to-production parity principle**: the components, topology, data flow, and activation sequence (off→dry_run→enabled)
> match the future production rollout exactly; only the scale differs (single host, single Sequencer, no op-conductor/HA).
> Therefore, **flashblocks-websocket-proxy is retained** even with only one local RPC consumer, preserving the complete
> `op-rbuilder → rollup-boost → ws-proxy → flashblocks-aware RPC` path.
> This ensures local validation exercises the production design. op-conductor is required only for production HA and does not alter this data flow.

---

## 1. Goal

Under the premise of keeping the existing chain unchanged (Legacy CGT, Jovian fork, 2s canonical block, single Sequencer, Fault Proof):

1. Use rollup-boost as the Engine API proxy between op-node and execution layer.
2. Use op-rbuilder (reth-based) as the Flashblocks block builder, producing ~200ms preconfirmations.
3. Keep existing **op-geth as canonical fallback + payload verification baseline**.
4. Progress through `off → dry_run → enabled` until users can observe preconfirmations through `pending`.

Final local target architecture:

```text
Sequencer side                                  User-facing layer (RPC replica, production-equivalent)
                  ┌─ op-geth(8651) canonical fallback + VALID verification
op-node ─Engine─> rollup-boost(8551)
                  └─ op-rbuilder(8661) builder + 200ms flashblocks
                         │ flashblocks export ws(1111)
                         ▼
                  rollup-boost broadcast(1112) ─> ws-proxy(1113) ─> op-reth(8745, --flashblocks-url)
                                                                    ▲ Engine(8751)
                                                                    │
                                                          verifier op-node(9555, does not produce blocks)
                                                                    │
                                                              Users query pending
```

---

## 2. Current State: Existing Ports and Connections (Do Not Change)

| components | port | Description |
|---|---|---|
| anvil (L1) | 8545 | Local L1 |
| op-geth HTTP | 8645 | `L2_RPC_URL` |
| op-geth WS | 8646 | |
| op-geth Engine (authrpc) | 8651 | op-node currently points to `--l2` here |
| op-node rollup RPC | 9545 | `OP_ROLLUP_PORT` |
| op-batcher RPC | 9645 | |
| op-proposer RPC | 8560 | |

Existing critical wiring (`scripts/chain-ops/run-op-node.sh` line 22):

```text
op-node --l2=http://localhost:8651  --l2.jwt-secret=$JWT_FILE
```

**Flashblocks integration changes only this connection**: point op-node's `--l2` from op-geth (8651) to rollup-boost (8551); leave all other components unchanged.

---

## 3. Target: New Components and Port Allocation

Add a new port (can be customized locally, just avoid already used ports):

| new components | port | Description |
|---|---|---|
| rollup-boost Engine (op-node is connected here) | 8551 | Expose Engine API to upstream op-node |
| rollup-boost flashblocks broadcast WS | 1112 | External flashblocks stream |
| op-rbuilder Engine (authrpc) | 8661 | builder-url for rollup-boost |
| op-rbuilder HTTP | 8663 | reth RPC (for synchronization/debugging/control) |
| op-rbuilder WS | 8664 | |
| op-rbuilder flashblocks export WS | 1111 | op-rbuilder → rollup-boost |
| flashblocks-websocket-proxy external endpoint | 1113 | User/RPC subscription endpoint |
| flashblocks-aware RPC (op-reth) HTTP | 8745 | Provide `pending` pre-confirmation to users |
| flashblocks-aware RPC (op-reth) Engine authrpc | 8751 | driven by its verifier op-node |
| RPC replica verifier op-node RPC | 9555 | Drives the op-reth instance above (synchronization only; no block production) |

**The entire path reuses the same JWT** at `data/op-geth/jwt.txt`: op-node ↔ rollup-boost ↔ (op-geth, op-rbuilder).
The RPC replica's verifier op-node ↔ op-reth connection uses it as well.

> **Why the RPC replica pairs op-node with op-reth**: op-reth is an execution client and cannot derive the chain from L1 itself.
> It must be driven by an op-node (verifier mode, not producing blocks) through the Engine API to synchronize the canonical chain;
> op-reth then overlays the Flashblocks stream to calculate `pending`. Production Flashblocks RPC nodes use this structure,
> so the local setup reproduces it for parity.

---

## 4. Components and versions (Jovian era locked)

The Rust components must be fetched and compiled separately; `bin/` currently contains only Go components.

**Delivery strategy: fork all components into `HSKChain` and build them from source** for an independently controlled and auditable supply chain.
**The three forks are git submodules at the repository root**: `rollup-boost` / `op-rbuilder` / `reth`,
alongside the existing `optimism` / `op-geth` submodules. The table's "upstream source" column identifies each fork's origin.
Builds enter the relevant submodule, run `fetch_and_checkout $REF`, and then run `cargo build` (matching `build-binaries.sh`); they do not use `git clone`.

**Component versions must match this chain's fork era**: this chain is **Jovian, not Karst** (op-node `cgt-jovian/v1.16.5`,
op-geth `v1.101605.0`). All new components are **pinned to Jovian-era releases**. Current releases have moved to
Karst / Engine API V5 (`getPayloadV5`) and require op-node ≥ v1.19.1, which is incompatible with this chain.

| components | upstream source → fork repository | Version(tag) | Why this version |
|---|---|---|---|
| rollup-boost | `flashbots/rollup-boost` → `HSKChain/rollup-boost` | **v0.7.11** | The official Jovian (Upgrade 17) version; the internal reth dependency is upgraded to 1.9.3, and the payload id calculation under Jovian is corrected. Not using v0.7.16 (Karst/PayloadVersion V5). |
| op-rbuilder | `flashbots/op-rbuilder` → `HSKChain/op-rbuilder` (reth-based) | **v0.2.13** | Official Jovian-pinned version; v0.2.11 is incompatible with Jovian (its Flashblocks payload omits blob gas used), v0.2.12 added Jovian support, and v0.2.13 is recommended. Do not use 0.4.x (reth 2.3.x/Karst). |
| flashblocks-aware RPC (op-reth) | `paradigmxyz/reth` → `HSKChain/reth` | **v1.9.3** | The official Jovian matrix specifies v1.9.2 for standard nodes and **v1.9.3 for Flashblocks**. Flashblocks support is **built into op-reth** (`--flashblocks-url`), so no Base fork is required. op-reth is a reth binary target (`--bin op-reth`). Do not use v2.3.x (Karst/getPayloadV5). |
| flashblocks-websocket-proxy | Same as `HSKChain/rollup-boost` (`crates/websocket-proxy` in repository) | **v0.7.11** (same repository and tag as rollup-boost) | ⚠️ **Do not use `base/flashblocks-websocket-proxy`**: The independent repository 2025-05 has been archived and the code has been merged into the base/node monorepo. Use the websocket-proxy crate that comes with rollup-boost, which is the same version in the same repository, actively maintained by Flashbots, and naturally aligned. |

> Description:
> - **Fork list (3 source repositories)**: `flashbots/rollup-boost@v0.7.11`, `flashbots/op-rbuilder@v0.2.13`,
>   `paradigmxyz/reth@v1.9.3`, forked to `HSKChain/rollup-boost`, `HSKChain/op-rbuilder`, and `HSKChain/reth` respectively.
>   websocket-proxy is in the rollup-boost repository (`crates/websocket-proxy`) and is not forked separately.
> - **op-reth self-compiled from source code**: The real source code of op-reth is in **`paradigmxyz/reth`**, `cargo build --release --bin op-reth`.
>   ⚠️ **Don’t go to `ethereum-optimism/optimism` monorepo to find v1.9.3** - there is no v1.9.3 tag in this monorepo.
>   (The op-reth moved into the monorepo after the Karst era. The set in the monorepo is the Karst era v2.3.x, which cannot be used in this chain).
> - flashblocks is a native feature of op-reth (upstream reth PR #18094), an `--flashblocks-url` flag is enough, no base/node packaging is required.
>   After building, confirm the flag exists with `op-reth node --help | grep flashblocks`.
> - websocket-proxy: `v0.7.11` tag contains `crates/websocket-proxy` (also contains `flashblocks-rpc`),
>   It has the same origin and version as rollup-boost, **use it first** (use tag, don’t use main - main is already the Karst era).
>   The alternative is `crates/infra/websocket-proxy` in the base/base (BaseHub) monorepo, which adds production features such as Brotli compression,
>   API key authentication, and rate limiting. It is actively maintained and can serve as a protocol-compatible replacement, but requires cloning the monorepo separately. The archived standalone Base repository is no longer used.
> - **Licensing**: rollup-boost = MIT; op-rbuilder/reth = MIT OR Apache-2.0. All may be forked, modified, built into container images, and offered as external services;
>   After forking, retain the LICENSE and copyright statement (Apache also retains NOTICE and marks modifications), provide it under its own brand name, and do not imply official endorsement.
> - **Decision**: use v1.16.5 with the Flashbots repositories and **do not rebase onto the latest release**. Migrating to the OP monorepo (Karst era) and
>   completing the broader Karst upgrade are separate future tasks. Once selected, pin identical versions in private-network and production deployments and record each commit.

Unified into `bin/` (consistent with the existing Go binary): `bin/rollup-boost`, `bin/op-rbuilder`, `bin/flashblocks-ws-proxy`, `bin/op-reth` (for flashblocks RPC).

---

## 5. Prerequisite: chain-spec / genesis consistency (the most critical step)

op-rbuilder (reth) and the Flashblocks RPC (op-reth) must use exactly the same genesis as op-geth; otherwise comparisons are meaningless.

- The existing op-geth uses `$DEPLOYMENT_CONFIG_PATH/genesis.json` (i.e. `config/$DEPLOYMENT_CONTEXT/genesis.json`,
  Current `DEPLOYMENT_CONTEXT=local-mainnet`; `chain-ops/chain-start.sh` exported as `OP_GETH_GENESIS_FILE`) initialized.
- op-reth/op-rbuilder directly `--chain <this genesis.json>` loads OP genesis.

> ⚠️ **chain spec load compatibility (P0 primary sub-gate)**: `--chain` of reth system (op-reth/op-rbuilder) requires OP genesis.
> **First verify that it can directly parse this chain `genesis.json`** - If the reported format/field is wrong, you need to confirm whether to convert (op genesis dump format difference),
> If this gate fails, stop: no meaningful genesis-hash comparison is possible afterward.

Acceptance point (gate of P0):

```bash
# op-geth genesis hash
cast block 0 --rpc-url http://localhost:8645 -f hash
# op-rbuilder genesis hash (after starting op-rbuilder)
cast block 0 --rpc-url http://localhost:8663 -f hash
# Both must be exactly the same
```

If the genesis hash is inconsistent → stop, resolve the genesis parsing differences first (common in CGT/preset contracts alloc, extraData).

---

## 6. Script modification list (to fit the existing arrangement)

Existing orchestration style: `scripts/chain-ops/chain-start.sh` passes variables through `_CALLER_*`, while each `scripts/chain-ops/run-op-*.sh` is a pure component launcher. Preserve this pattern:

- **Add 5 launchers under `scripts/chain-ops/`** (alongside `run-op-geth.sh`, etc.): `run-op-rbuilder.sh` / `run-rollup-boost.sh` / `run-flashblocks-proxy.sh` / `run-flashblocks-rpc-op-reth.sh` / `run-flashblocks-rpc-op-node.sh`. Each follows the minimal `run-op-node.sh` template (`source .envrc` + `_CALLER_*` overrides + `exec`) and does not calculate `BASE_PATH`.
- **1 build script is placed in `scripts/flashblocks/build-flashblocks.sh`** (parallel with `build-binaries.sh`, dedicated to Rust; at the end of `build-binaries.sh`, it can be optionally called when `FLASHBLOCKS_MODE != off` is used to achieve "single-command full build").
- **`chain-ops/chain-start.sh` adds lightweight `FLASHBLOCKS_MODE` branch** (only decides "whether to add a few more components"), **`chain-ops/run-op-node.sh` cuts `--l2`** according to mode, and `chain-ops/chain-stop.sh` stops the list to complete new components.
- **Mode switching (decision C)**: `.envrc` provides the **startup value** of `FLASHBLOCKS_MODE`, determining which components start and rollup-boost's initial execution mode. At runtime, switch `dry_run↔enabled` through rollup-boost's `debug set-execution-mode` endpoint (`RB_DEBUG_PORT`) without interrupting the chain; the hard rollback remains "edit `.envrc` + restart."

### 6.1 `.envrc` added

```bash
# ===== Flashblocks (local verification) =====
# off: Flashblocks disabled; topology remains unchanged (default)
# dry_run: op-node uses rollup-boost; the canonical block is still generated by op-geth, and the builder payload is only used for verification and comparison.
# enabled: adopt op-rbuilder blocks and produce 200ms Flashblocks
export FLASHBLOCKS_MODE=off

export RB_ENGINE_PORT=8551          # rollup-boost Engine (op-node is connected here)
export RB_FLASHBLOCKS_WS_PORT=1112  # rollup-boost external flashblocks broadcast
export RB_DEBUG_PORT=5555           # rollup-boost debug server (live debug set-execution-mode switching)
export RBUILDER_AUTHRPC_PORT=8661   # op-rbuilder Engine
export RBUILDER_HTTP_PORT=8663
export RBUILDER_WS_PORT=8664
export RBUILDER_FB_WS_PORT=1111     # op-rbuilder → flashblocks export for rollup-boost
export FB_PROXY_PORT=1113           # ws-proxy External
export FB_RPC_HTTP_PORT=8745        # flashblocks-aware RPC(op-reth) for users
export FB_RPC_AUTHRPC_PORT=8751     # op-reth Engine (driven by verifier op-node)
export FB_RPC_OPNODE_PORT=9555      # RPC replica verifier op-node RPC

# Rust component: added as submodule (rollup-boost/op-rbuilder/reth), self-compiled from submodule source code, locked tag
export ROLLUP_BOOST_REF=v0.7.11    # rollup-boost submodule (including crates/websocket-proxy, compiled together)
export OP_RBUILDER_REF=v0.2.13     # op-rbuilder submodule; Jovian ready (v0.2.11 is not compatible with Jovian)
export OP_RETH_REF=v1.9.3          # --bin op-reth of reth submodule; built-in flashblocks, must be v1.9.3
# Note: websocket-proxy is not forked separately - directly use crates/websocket-proxy in rollup-boost submodule (ROLLUP_BOOST_REF)
# Note: The submodule pointer is pinned to the tag above; REF is only a fallback validation input for fetch_and_checkout during builds.
```

### 6.2 New `scripts/flashblocks/build-flashblocks.sh`

```bash
#!/bin/bash
# Compile flashblocks related Rust components to bin/ (requires rust toolchain)
# The three components are already submodules. They are self-compiled from the source code in the submodule directory and locked with tags. The first compilation is slow (reth has heavy dependencies, ≥16C/32G is recommended).
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

# Same as build-binaries.sh: fetch specified tag in shallow submodule and checkout
fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

# Make sure the submodule is checked out (you can git submodule update --init for the first time)
git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy (same submodule, same tag, compiled together)
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/websocket-proxy "$BASE_PATH/bin/flashblocks-ws-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# (websocket-proxy has been compiled with rollup-boost and does not require a separate repository; do not use the archived base/flashblocks-websocket-proxy)

# op-reth (flashblocks-aware RPC): a binary target in the reth submodule; build only this target.
# ⚠️ Don't look for v1.9.3 from the ethereum-optimism/optimism monorepo - the tag is not there (the monorepo is the Karst era v2.3.x).
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"
# Verify that Flashblocks support is included
"$BASE_PATH/bin/op-reth" node --help | grep -q flashblocks && echo "op-reth: flashblocks flag OK"

cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
```

> - To enable a single-command full build, append `[ "${FLASHBLOCKS_MODE:-off}" != "off" ] && bash "$BASE_PATH/scripts/flashblocks/build-flashblocks.sh"` to `build-binaries.sh`. Run this script directly when rebuilding only one Rust component.
> - The flag/subcommand name is based on the `--help` of the tag corresponding to each submodule. The values given in this article are representative values.

### 6.3 New `scripts/flashblocks/run-op-rbuilder.sh`

> **No separate builder op-node is required** (verified assumption): rollup-boost forwards the primary op-node's
> Engine calls (FCU/newPayload/getPayload) to drive op-rbuilder, so no builder-side op-node is needed.
> (Only the downstream op-reth RPC replica needs its own verifier op-node because it cannot connect to rollup-boost; see §6.6b.)

```bash
#!/bin/bash
# op-rbuilder: reth flashblocks builder. Use the same genesis as op-geth.
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT/genesis.json}"
DATADIR="$BASE_PATH/data/op-rbuilder"
mkdir -p "$DATADIR"

exec op-rbuilder node \
  --chain "$GENESIS" \
  --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$RBUILDER_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$RBUILDER_HTTP_PORT" --http.api eth,web3,net,debug,txpool \
  --ws --ws.addr 0.0.0.0 --ws.port "$RBUILDER_WS_PORT" \
  --port "${RBUILDER_P2P_PORT:-30313}" \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks.enabled --flashblocks.addr 0.0.0.0 --flashblocks.port "$RBUILDER_FB_WS_PORT" \
  --flashblocks.block-time 250
```

### 6.4 New `scripts/flashblocks/run-rollup-boost.sh`

```bash
#!/bin/bash
# rollup-boost: Engine proxy between op-node and (op-geth fallback + op-rbuilder builder).
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

# FLASHBLOCKS_MODE as "startup initial value" (decision C): dry_run → builder only checks but does not use; enabled → uses builder block.
# After startup, use debug_setExecutionMode on the debug server (RB_DEBUG_PORT) for live, uninterrupted switching.
EXEC_MODE_FLAG=""
[ "$FLASHBLOCKS_MODE" = "dry_run" ] && EXEC_MODE_FLAG="--execution-mode=dry-run"
[ "$FLASHBLOCKS_MODE" = "enabled" ] && EXEC_MODE_FLAG="--execution-mode=enabled"

exec rollup-boost \
  --rpc-addr 0.0.0.0 --rpc-port "$RB_ENGINE_PORT" \
  --jwt-path "$JWT_FILE" \
  --l2-url  http://localhost:8651 \
  --l2-jwt-path "$JWT_FILE" \
  --builder-url http://localhost:"$RBUILDER_AUTHRPC_PORT" \
  --builder-jwt-path "$JWT_FILE" \
  --flashblocks --flashblocks-builder-url ws://localhost:"$RBUILDER_FB_WS_PORT" \
  --flashblocks-addr 0.0.0.0 --flashblocks-port "$RB_FLASHBLOCKS_WS_PORT" \
  --debug-server-port "$RB_DEBUG_PORT" \
  $EXEC_MODE_FLAG
```

> The above is an early design draft. **Use `scripts/flashblocks/run-rollup-boost.sh` as the source of truth for actual flags** (v0.7.11 uses
> `--rpc-host` / `--flashblocks-host`, and `--l2-url` / `--builder-url` must carry `http://` scheme).
>
> Live switching (v0.7.11 **does not** have a `rollup-boost debug` subcommand; use the debug server's JSON-RPC endpoint):
>
> ```bash
> curl -s -X POST -H 'Content-Type: application/json' \
>   --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
>   http://localhost:$RB_DEBUG_PORT
> # Query: debug_getExecutionMode (params is [])
> ```
>
> Note that the case style is inconsistent: CLI flag is kebab-case (`--execution-mode=dry-run`), JSON-RPC is
> snake_case (`"dry_run"`).

### 6.5 New `scripts/flashblocks/run-flashblocks-proxy.sh`

```bash
#!/bin/bash
# Subscribe to rollup-boost's flashblocks broadcast and fan out to the user-facing side.
source .envrc
exec flashblocks-ws-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
```

### 6.6 Added `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh` (op-reth, subscribe to ws-proxy)

Flashblocks is a **native op-reth feature**. Use `--flashblocks-url` to subscribe to ws-proxy (**not** directly to rollup-boost,
to preserve production parity). Use cleartext `ws://` locally to avoid missing `wss://` TLS support in some op-reth builds.

```bash
#!/bin/bash
# flashblocks-aware RPC: op-reth subscribes to ws-proxy Flashblocks and exposes pending state.
# run-flashblocks-rpc-op-node.sh (verifier op-node) drives canonical-chain synchronization through the Engine API.
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="$BASE_PATH/config/$DEPLOYMENT_CONTEXT/genesis.json"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

exec op-reth node \
  --chain "$GENESIS" --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" \
  --http.api eth,web3,net,debug \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
  # Add --flashblock-consensus to let this replica advance directly from Flashblocks (disabled locally by default; the verifier op-node below drives it)
```

### 6.6b Added `scripts/flashblocks/run-flashblocks-rpc-op-node.sh` (the verifier op-node that drives the op-reth instance above)

```bash
#!/bin/bash
# RPC replica verifier op-node: does not produce blocks; it only drives op-reth canonical-chain synchronization through the Engine API.
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT/rollup.json}"

exec op-node \
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$FB_RPC_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$FB_RPC_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" --p2p.disable
# Note: Do not add --sequencer.enabled (this is a read-only replica and does not produce blocks)
```

### 6.7 Change `scripts/chain-ops/run-op-node.sh`: Switch `--l2` by Mode

Change the fixed `--l2=http://localhost:8651` in line 22 to the `FLASHBLOCKS_MODE` selection:

```bash
# FLASHBLOCKS_MODE=off → connect directly to op-geth(8651); dry_run/enabled → use rollup-boost(RB_ENGINE_PORT)
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:8651"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
```

### 6.8 Change `scripts/chain-ops/chain-start.sh`: Start New Components by Mode

After starting op-geth and before starting op-node, insert (when the mode is not off):

```bash
# ---------- Flashblocks component (FLASHBLOCKS_MODE != off) ----------
export _CALLER_OP_GETH_GENESIS_FILE="$OP_GETH_GENESIS_FILE"
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  echo "Starting op-rbuilder..."
  nohup bash "$SCRIPT_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
  echo $! > "$PID_DIR/op-rbuilder.pid"
  sleep 3
  echo "Starting rollup-boost (mode=$FLASHBLOCKS_MODE)..."
  nohup bash "$SCRIPT_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
  echo $! > "$PID_DIR/rollup-boost.pid"
  sleep 2
fi
```

At the end, append the complete user-facing path in dry_run and enabled modes:
ws-proxy → op-reth (RPC) → its verifier op-node. In dry_run, this path exposes shadow
builder previews for testing and must not receive production user traffic.
**Local and production topologies match; the proxy is retained.**

```bash
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  echo "Starting flashblocks ws-proxy..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-proxy.sh" >> "$LOG_DIR/fb-proxy.log" 2>&1 &
  echo $! > "$PID_DIR/fb-proxy.pid"
  sleep 1
  echo "Starting flashblocks-aware RPC (op-reth)..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-reth.sh" >> "$LOG_DIR/fb-rpc-reth.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-reth.pid"
  sleep 2
  echo "Starting flashblocks RPC verifier op-node..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-node.sh" >> "$LOG_DIR/fb-rpc-opnode.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-opnode.pid"
fi
```

### 6.9 Change `scripts/chain-ops/chain-stop.sh`: Stop All Components

Add new components to the `for name in ...` list and `stop_matching_processes`:

```bash
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder op-challenger op-proposer op-batcher op-node op-geth; do
  ...
done
stop_matching_processes "fb-rpc-opnode"    "op-node "      "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "fb-rpc-reth"       "op-reth "      "--datadir=$DATA_DIR/op-reth"
stop_matching_processes "op-rbuilder"  "op-rbuilder "  "--datadir=$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost" "rollup-boost " "--rpc-port=${RB_ENGINE_PORT:-8551}"
```

---

## 7. Step-by-step implementation and verification gate (local)

> Each step is a reversible stable state. Do not proceed until the previous step's verification gate passes.

### P0 — compile + chain spec load + genesis alignment
1. `bash scripts/flashblocks/build-flashblocks.sh` generates 4 Rust binaries into `bin/`.
2. **Verify that the reth system can parse the genesis of this chain** (§5 primary sub-gate): `op-rbuilder`/`op-reth` can be started normally with `--chain genesis.json` and no format error will be reported.
3. Start op-rbuilder alone and compare genesis hashes (see §5).
- **Gate**: reth system successfully loaded genesis; `op-rbuilder` genesis hash == `op-geth` genesis hash.
- **Data directories**: add `data/op-rbuilder` and `data/op-reth` to the cleanup scope of `deploy-chain/chain-reset.sh` so `--reset` removes both and stale state cannot contaminate comparisons.

### P1 — op-rbuilder shadow synchronization (surgical switching)

**Three-phase life cycle and op-rbuilder engine driver rights** (core invariant: op-rbuilder's Engine=auth RPC `RBUILDER_AUTHRPC_PORT` can only have one consensus driver at the same time):

| Phase | components | op-rbuilder driver | op-node `--l2` |
|---|---|---|---|
| OFF | op-geth, op-node | — (without op-rbuilder) | op-geth :8651 |
| SYNC | +op-rbuilder, +builder op-node | **builder op-node** (`--l2=…:8661`) | op-geth :8651 |
| FLASHBLOCKS(dry_run/enabled) | op-geth, op-rbuilder, rollup-boost, op-node | **rollup-boost** (`--builder-url …:8661`) | rollup-boost :8551 |

> Both builder op-node and rollup-boost are connected to the same auth RPC of op-rbuilder and cannot coexist - when switching, the builder op-node must be stopped first, and then rollup-boost takes over. The builder op-node is only used in the off phase for "specialized synchronization".

Synchronization mechanism: the builder op-node (`run-op-rbuilder-opnode.sh`) drives op-rbuilder, derives history from L1 (Anvil) from genesis to the safe head, and follows unsafe gossip to the unsafe head through a static CL P2P connection (`--p2p.static`) to the primary (sequencer) op-node. The primary op-node **always enables CL P2P, including in off mode** (a fixed private key gives it a stable peer ID and is generated by `run-op-node.sh` on first startup), allowing op-rbuilder to pre-synchronize to the unsafe head while Flashblocks is off.

**Single-command surgical switching (recommended)**: while the off-mode chain is running, execute
`bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local`. **op-rbuilder starts once and remains running throughout**; the switch only transfers Engine control and reroutes op-node, while op-geth and op-rbuilder continue running. Ten steps:

1. Pre-check (off chain is running, op-geth/op-node is reachable, main op-node p2p is open, bin is ready, `[9]` restart safe window has arrived)
2. Start synchronization node: op-rbuilder + builder op-node
3. Coarse catch-up (`--lag`, default 2)
4. `admin_stopSequencer` pauses sequencing on the primary op-node (the process remains running and continues gossiping; save the head hash for rollback)
5. Catch up exactly to frozen height H
6. Stop builder op-node (hand over op-rbuilder engine driving rights)
7. Write `.envrc` `FLASHBLOCKS_MODE=dry_run` (rollup-boost/op-node reads mode accordingly)
8. Start rollup-boost (dry-run execution mode, take over the driver op-rbuilder)
9. Restart only the main op-node (`--l2`→rollup-boost)
10. Verify block advancement

Parameters: `--lag=N`/`--timeout=SEC`/`--no-wait`. If any step fails, it will be rolled back (`[3]` stops the synchronization process; after `[5]`, `admin_startSequencer` resumes block production + stops the synchronization process), and the chain will return to off, leaving no half-measures.

**`[9]` Restart-safe window**: at startup, op-node rewinds the L1 read position by one `channel_timeout` (50 L1 blocks after Granite, 300 before). If that position predates Holocene activation, `BatchMux` installs the pre-Holocene `BatchQueue`. Replaying an old batch whose L1 block is already past Holocene returns `BatchPast`; `BatchQueue` does not recognize this value and exits with `crit: unknown batch validity type: 4` on every restart. A new chain initially falls into this window. Wait until the safe head's L1 origin advances beyond `Holocene/Granite boundary + channel_timeout`. Preflight step `[1]` calculates this point and **automatically polls until it is safe** (bounded by `--timeout`, default 1800s; `--no-wait` fails immediately). Waiting occurs before any components start, so the chain remains unaffected in off mode. With `L1_BLOCK_TIME=6` and `MAX_CHANNEL_DURATION=5`, the local chain takes about 5–6 minutes to reach the safe point.

**Manual equivalent**: `[2]` manually run `run-op-rbuilder.sh` + `run-op-rbuilder-opnode.sh` and wait for catch-up → `[4]` call `cast rpc admin_stopSequencer` → stop builder op-node → run `run-rollup-boost.sh` → update `.envrc` → restart `run-op-node.sh`.

> Note: a complete `chain-start` with `FLASHBLOCKS_MODE=dry_run` uses
> `start-sequencer-side.sh` to start op-rbuilder + rollup-boost and starts the user-facing
> shadow topology, but **does not start** the builder op-node. rollup-boost/op-node Engine
> calls drive op-rbuilder synchronization. This path is for steady-state restarts, not
> the initial switch.

Block by block comparison (focus on Granite/Holocene/Isthmus/Jovian active blocks + several normal blocks).
- **Gate**: op-rbuilder reaches the chain tip; key-block `blockHash` / `stateRoot` values match op-geth; no block is invalid.
- Check the script with §8.1.

### P2 — dry_run
1. Single-command surgical switch: `bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local` (includes P1 synchronization, frozen-head catch-up, and driver handoff; op-rbuilder remains running);
   Or full restart: `FLASHBLOCKS_MODE=dry_run` + `bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local` (op-rbuilder recovers from hot datadir).
2. op-node uses rollup-boost; the canonical block is still generated by op-geth, and the builder payload is only verified.
3. Covered: ordinary transfer / contract call / failed transaction / CGT gas payment / deposit / withdrawal / L1 origin switching.
- **Gate**: all builder payloads in the rollup-boost log are `VALID`; `Invalid payload = 0`; 2-second block production remains uninterrupted; batcher, proposer, and challenger show no errors.
- Note: The transactions selected by builder and op-geth can be different. Different block hash/gas does not count as a consensus error; it only depends on whether it is VALID or not.

### P3 — enabled + flashblocks output
1. Two ways to enter (decision C):
   - **Live switch**: run `scripts/flashblocks/switch-dryrun-to-flashblocks-enabled.sh`. The dry_run topology already includes the user-facing services, so only rollup-boost's mode changes.
   - **Reboot (reproducible baseline)**: `FLASHBLOCKS_MODE=enabled` + `chain-ops/chain-stop.sh && chain-ops/chain-start.sh local`.
2. Canonical blocks use op-rbuilder; subscribe to the Flashblocks stream and verify ~250ms output (§8.2).
- **Gate**: builder blocks land reliably, Flashblocks remain continuous, and stopping op-rbuilder automatically falls back to op-geth block production (§8.3 drill).

### P4 — User-facing layer (complete production-equivalent path)
1. dry_run and enabled modes start the complete user-facing path: `ws-proxy(1113) → op-reth(8745) ← verifier op-node(9555)`. Do not expose port 8745 to production users while still in dry_run.
2. Run `scripts/flashblocks/verify/p4-user-facing.sh`. It sends transactions through op-reth (8745) and checks that each one appears in `pending` before it is sealed.
- **Gate**: Every sample receives a pre-confirmation in under one second.

### P5 — Local Acceptance
- Run a complete scenario (function + FP non-regression + fault rollback) and record it to form a local acceptance conclusion.
- Script: `scripts/flashblocks/verify/p5-acceptance.sh`. It runs the P0/P1/P3/P4 gates, then transfer / contract deployment and call / reverting transaction through the user-facing RPC, checks that the safe head and proposer keep advancing, and writes `data/verify-reports/p5-<timestamp>.md`. Both rehearsals are opt-in: `--fallback-drill` forwards to the p3 drill, and `--restart-off-drill` stops the chain, restarts it in off mode and switches back to enabled.

---

## 8. Verification method (specific script)

### 8.1 Block-by-block comparison (op-geth vs op-rbuilder)
```bash
# Compare the hash / stateRoot of the specified block
for BN in <granite> <holocene> <isthmus> <jovian> $(cast bn --rpc-url http://localhost:8645); do
  A=$(cast block $BN --rpc-url http://localhost:8645 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  B=$(cast block $BN --rpc-url http://localhost:8663 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  [ "$A" = "$B" ] && echo "OK   $BN" || echo "DIFF $BN | geth=$A | rbuilder=$B"
done
```

### 8.2 Observing the flashblocks stream
```bash
# Subscribe to rollup-boost broadcast (or ws-proxy), which should be broadcast approximately every 250ms
websocat ws://localhost:1112 | head -20
# Or subscribe to external proxy
websocat ws://localhost:1113 | head -20
```

### 8.3 pending pre-confirmation verification
```bash
TX=$(cast send <to> --value 1 --rpc-url http://localhost:8645 --private-key <k> --async)
# Check pending from flashblocks RPC immediately. You should be able to see the tx 2s before the canonical block.
cast rpc eth_getBlockByNumber pending true --rpc-url http://localhost:8745 | jq '.transactions[].hash'
```

### 8.4 Divergence debugging (when dry_run reports an invalid payload)
1. Get the invalid block number from the rollup-boost log.
2. Use §8.1 to compare `stateRoot` with op-geth vs op-rbuilder at the same height.
3. Narrow down to "which transaction/which field": give priority to suspicion
   - Jovian `extraData` / `minBaseFee` encoding;
   - CGT related preset contract (L1Block / GasPriceOracle) bytecode or gas adjustment;
   - Isthmus/Jovian upgrade transaction (type 0x7e) execution result.
4. After locating the specific differences, determine whether the op-rbuilder version does not support the fork, or the genesis/preset status is not aligned.

---

## 9. Fallback (local)

| Hierarchy | Operation | result |
|---|---|---|
| builder live downgrade (no interruption) | `rollup-boost debug set-execution-mode dry-run` (`RB_DEBUG_PORT`) | Canonical block production immediately returns to op-geth without restarting |
| builder downgrade (restart) | `FLASHBLOCKS_MODE=dry_run` + `chain-ops` restart | Canonical blocks return to op-geth; the user-facing RPC remains available as a shadow preview |
| Bypass sidecar | `FLASHBLOCKS_MODE=off` + `chain-ops` Restart | op-node is directly connected to op-geth(8651), and the architecture returns to before access. |
| Disable the user-facing layer only | `SKIP_FB_USER=1` or stop fb-proxy/fb-rpc-reth/fb-rpc-opnode | The canonical chain and Sequencer are unaffected |

Two rollback paths (decision C): use `debug set-execution-mode` for a live downgrade within seconds; change `.envrc` for a hard rollback.
`FLASHBLOCKS_MODE=off` + `chain-ops/chain-stop.sh && chain-ops/chain-start.sh` — `--l2` of op-node
The target is determined by a single point of `FLASHBLOCKS_MODE`. The rollback only changes one variable + restarts, leaving other components untouched.

---

## 10. Risks and precautions (pay close attention to the local stage)

1. **Version generation must lock Jovian** - Biggest risk. Locked rollup-boost v0.7.11 / op-rbuilder v0.2.13 / op-reth v1.9.3;
   Do not mix in the Karst era (0.4.x / 0.7.16 / 2.3.x), otherwise Engine API V5 will be introduced, which is incompatible with this chain op-node v1.16.x.
2. **CGT compatibility is not officially guaranteed** - CGT customization lives in the contracts and op-node, while op-geth is stock. P2 must prove that op-rbuilder (reth) is equally transparent by producing only VALID results in dry_run.
3. **Genesis alignment** is a prerequisite for every comparison. Do not continue unless P0 passes.
4. **JWT consistency**: op-node / rollup-boost / op-geth / op-rbuilder / and the RPC replica (op-reth + verifier op-node) must use the same JWT file.
5. **op-reth `wss://` TLS**: Some op-reth builds omit TLS support and report `TLS support not compiled in` for `wss://`.
   The local use of `ws://` will not be affected; if `wss://` is used in future production, you must use a build that has fixed this problem.
6. The flag/subcommand name will change between each repository version, and will be calibrated with the corresponding version `--help` when implemented (the values given in this article are representative values).

---

## 11. Deliverables (local verification)
- 4 Rust binaries + build commit records.
- Genesis/chain parameter consistency record (P0).
- Shadow comparison report (P1).
- dry_run VALID / Invalid payload record (P2).
- flashblocks output and pending pre-confirmation records (P3/P4).
- Failback drill record (P3).
- Local acceptance conclusion (P5).
