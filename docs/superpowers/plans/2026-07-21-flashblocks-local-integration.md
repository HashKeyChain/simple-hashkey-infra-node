# Flashblocks Local Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use hsk-superpowers:subagent-driven-development (recommended) or hsk-superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Flashblocks (rollup-boost + op-rbuilder + ws-proxy + an op-reth RPC replica) into the deployed local Jovian chain (`local-mainnet`) using the reversible off → dry_run → enabled modes, and pass the local validation gates.

**Architecture:** Reuse the existing chain and `config/local-mainnet/` **without redeploying**. Add one build script and five pure component launchers under `scripts/chain-ops/`, and patch `chain-start.sh`, `chain-stop.sh`, `run-op-node.sh`, `build-binaries.sh`, `chain-reset.sh`, and `.envrc`. The three Rust components (rollup-boost / op-rbuilder / reth) are already root-level submodules and are built from source into `bin/`. Use `FLASHBLOCKS_MODE` in `.envrc` as the initial startup mode, with rollup-boost `debug set-execution-mode` for runtime hot switching.

**Tech Stack:** Bash + direnv (`.envrc`), Git submodules, Rust/Cargo (rollup-boost@v0.7.11 / op-rbuilder@v0.2.13 / op-reth from reth@v1.9.3), OP Stack (op-node cgt-jovian/v1.16.5, op-geth v1.101605.0), and Foundry `cast` for validation. Target: local Anvil L1 + `local-mainnet` L2 (Jovian generation, CGT, Fault Proof).

**Authoritative design source:** `doc/flashblocks_local_impl.md` (the single source of truth for components, ports, topology, and validation gates). This plan decomposes it into executable, bite-sized tasks.

**Important constraints (read before implementation):**
- **Lock the generation to Jovian**: Pin the submodules to `v0.7.11 / v0.2.13 / v1.9.3`; never use main (it is already on the Karst generation and uses Engine API V5, which is incompatible with op-node v1.16.5).
- **Use `--help` from each submodule's pinned tag as the authority for flag names**. The flags in this plan are representative values; validate every launcher against `--help` during implementation, especially reth-family `--flashblocks*` flags and rollup-boost `--flashblocks*`/`--debug-server-port`.
- **No unit test framework**: "Tests" in this plan consist of script syntax checks (`bash -n`), binary `--help` smoke tests, and runtime validation gates (P0–P5 `cast`/log assertions).
- **Reuse `data/op-geth/jwt.txt` across the entire path**.
- **All commits are manual**: Every `git add`/`git commit` step in this plan is for reference only. **The implementation agent must not commit automatically**; after making and validating changes, stop and let the user commit.

---

## Prerequisite: The Jovian Chain Is Ready (Not Deployed by This Plan)

This plan **reuses** an existing local chain already running Jovian and does not deploy it. Chain startup entry point (one-command script, added in `8d36a55`, accidentally deleted by the `0395bf3` "style" commit, and now restored from Git):

```bash
bash scripts/build-binaries.sh                                    # Build (skip if bin/ is already populated)
FLASHBLOCKS_MODE=off bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

Internally, the script performs: `chain-reset → reset to pure Fjord → chain-setup → chain-start → compute Granite through Jovian activation times from the L2 wall clock and write them back to .envrc → activate-fork → wait and assert isJovian()==true`. It supports `--target=` (default: Jovian), `--pace=`, and `--lead=`.

> Equivalent manual procedure (when not using the one-command script; see `doc/chain-lifecycle.md` for the authoritative procedure): `chain-reset.sh` → `chain-setup.sh` → `chain-ops/chain-start.sh`. Note that the one-command script uses the "pure Fjord deployment + timed activation" path instead of baking all fork times directly into the deployment.

**Readiness criteria** (all must pass before Task 1):
- `config/local-mainnet/{genesis.json,rollup.json,artifact.json}` all exist.
- The block number from `cast bn --rpc-url http://localhost:8645` is increasing (the chain is producing blocks in `off` mode).
- The chain is on Jovian: `cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645` returns `true`, and Fault Proof components (proposer/challenger) show no errors.

---

## File Structure (Define the Boundary First)

| Action | Path | Responsibility |
|---|---|---|
| Modify | `.envrc` | Append Flashblocks port/mode/REF variables |
| Create | `scripts/flashblocks/build-flashblocks.sh` | Build Rust components from the three submodules into `bin/` |
| Modify | `scripts/build-binaries.sh` | Optionally invoke build-flashblocks near the end when `FLASHBLOCKS_MODE != off` |
| Create | `scripts/flashblocks/run-op-rbuilder.sh` | Pure launcher: op-rbuilder (builder) |
| Create | `scripts/flashblocks/run-rollup-boost.sh` | Pure launcher: rollup-boost (including debug server) |
| Create | `scripts/flashblocks/run-flashblocks-proxy.sh` | Pure launcher: ws-proxy |
| Create | `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh` | Pure launcher: op-reth (Flashblocks RPC) |
| Create | `scripts/flashblocks/run-flashblocks-rpc-op-node.sh` | Pure launcher: verifier op-node (drives op-reth) |
| Modify | `scripts/chain-ops/run-op-node.sh:22` | Switch `--l2` between 8651 and 8551 based on `FLASHBLOCKS_MODE` |
| Modify | `scripts/chain-ops/chain-start.sh` | Start new components according to the mode |
| Modify | `scripts/chain-ops/chain-stop.sh` | Add five new components to the stop list |
| Modify | `scripts/deploy-chain/chain-reset.sh` | Make `--reset` clear `data/op-rbuilder` and `data/op-reth` |

**Common launcher template** (follow the existing `run-op-node.sh`): `source .envrc` → `_CALLER_*` overrides with fallback to `.envrc`/defaults → `exec <bin> ...`; do not compute `BASE_PATH` locally.

---

## Task 1: Append Flashblocks Variables to `.envrc`

**Files:**
- Modify: `.envrc` (append at the end)

- [ ] **Step 1: Append the variable block**

Append the following to `.envrc`:

```bash
# ===== Flashblocks (local validation) =====
# off / dry_run / enabled — initial startup value (determines which components start + rollup-boost's initial execution mode)
export FLASHBLOCKS_MODE=off

export RB_ENGINE_PORT=8551          # rollup-boost Engine (op-node connects here)
export RB_FLASHBLOCKS_WS_PORT=1112  # rollup-boost external Flashblocks broadcast
export RB_DEBUG_PORT=5555           # rollup-boost debug server (set-execution-mode hot switch)
export RBUILDER_AUTHRPC_PORT=8661
export RBUILDER_HTTP_PORT=8663
export RBUILDER_WS_PORT=8664
export RBUILDER_FB_WS_PORT=1111     # Flashblocks output from op-rbuilder → rollup-boost
export FB_PROXY_PORT=1113           # External ws-proxy port
export FB_RPC_HTTP_PORT=8745        # User-facing op-reth port
export FB_RPC_AUTHRPC_PORT=8751     # op-reth Engine (driven by verifier op-node)
export FB_RPC_OPNODE_PORT=9555      # verifier op-node RPC

# Rust components (submodules, pinned tags)
export ROLLUP_BOOST_REF=v0.7.11
export OP_RBUILDER_REF=v0.2.13
export OP_RETH_REF=v1.9.3
```

- [ ] **Step 2: Validate direnv loading**

Run: `cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node && source .envrc && echo "$FLASHBLOCKS_MODE $RB_ENGINE_PORT $RB_DEBUG_PORT $OP_RETH_REF"`
Expected: `off 8551 5555 v1.9.3`

- [ ] **Step 3: Check for port conflicts**

Run: `for p in 8551 1112 5555 8661 8663 8664 1111 1113 8745 8751 9555; do lsof -iTCP:$p -sTCP:LISTEN -n -P >/dev/null 2>&1 && echo "PORT $p BUSY" || true; done; echo done`
Expected: `done` (no BUSY lines; if any appear, change the corresponding variable to avoid the conflict)

- [ ] **Step 4: Leave the commit to the user (note that `.envrc` is gitignored)**

`.envrc` is listed in `.gitignore` because it contains private keys, so local changes **will not and must not enter version control**. To share these Flashblocks variables with the team, copy the variable block into the tracked `.envrc.local.example` and commit it **yourself**; `.envrc` remains local-only. Do not perform any Git operation in this step.

---

## Task 2: `scripts/flashblocks/build-flashblocks.sh` (Build from Submodule Source)

**Files:**
- Create: `scripts/flashblocks/build-flashblocks.sh`

- [ ] **Step 1: Confirm that the submodules are initialized and pinned to tags**

Run: `git submodule status rollup-boost op-rbuilder reth`
Expected: Three lines, each showing the corresponding tag (`v0.7.11` / `v0.2.13` / `v1.9.3`) or its commit. If a line starts with `-` (not initialized), first run `git submodule update --init rollup-boost op-rbuilder reth`.

- [ ] **Step 2: Write the script** (based on Section 6.2 of `doc/flashblocks_local_impl.md`)

```bash
#!/bin/bash
# Build Flashblocks-related Rust components into bin/ (requires a Rust toolchain). The first build is slow because reth has heavy dependencies.
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy (same submodule and tag)
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/websocket-proxy "$BASE_PATH/bin/flashblocks-ws-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# op-reth (a binary target in the reth submodule)
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"

"$BASE_PATH/bin/op-reth" node --help | grep -q flashblocks && echo "op-reth: flashblocks flag OK"
cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
```

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/flashblocks/build-flashblocks.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Run the build (long-running; execute in the background)**

Run: `chmod +x scripts/flashblocks/build-flashblocks.sh && bash scripts/flashblocks/build-flashblocks.sh`
Expected: The final output includes `op-reth: flashblocks flag OK` and `Flashblocks binaries built into bin/`; `rollup-boost`, `flashblocks-ws-proxy`, `op-rbuilder`, and `op-reth` appear under `bin/`.
> If `cargo build` reports flag or dependency errors, the tag likely does not match the local Rust version. Install the toolchain specified by the submodule's `rust-toolchain.toml`.

- [ ] **Step 5: Smoke-test all four binaries**

Run: `for b in rollup-boost flashblocks-ws-proxy op-rbuilder op-reth; do echo "== $b =="; bin/$b --help >/dev/null 2>&1 && echo ok || echo FAIL; done`
Expected: All four report `ok`.

- [ ] **Step 6: Commit**

```bash
git add scripts/flashblocks/build-flashblocks.sh
git commit -m "feat(flashblocks): add build-flashblocks.sh (submodule source build)"
```

---

## Task 3: Optional Integration with `build-binaries.sh`

**Files:**
- Modify: `scripts/build-binaries.sh` (before `cd $BASE_PATH` near the end)

- [ ] **Step 1: Add the integration**

Insert the following before `# return base path` near the end of `scripts/build-binaries.sh`:

```bash
# ---------- Flashblocks Rust components (only when FLASHBLOCKS_MODE != off) ----------
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  bash "$BASE_PATH/scripts/flashblocks/build-flashblocks.sh"
fi
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/build-binaries.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Confirm that off mode does not trigger the build**

Run: `FLASHBLOCKS_MODE=off bash -c 'source .envrc; grep -q flashblocks scripts/build-binaries.sh && echo hooked'`
Expected: `hooked` (only confirms that the code exists; it is not invoked in off mode)

- [ ] **Step 4: Commit**

```bash
git add scripts/build-binaries.sh
git commit -m "feat(flashblocks): optionally build rust comps from build-binaries"
```

---

## Task 4: `scripts/flashblocks/run-op-rbuilder.sh`

**Files:**
- Create: `scripts/flashblocks/run-op-rbuilder.sh`

- [ ] **Step 1: Write the launcher** (based on implementation Section 6.3; validate flags against `bin/op-rbuilder node --help`)

```bash
#!/bin/bash
# op-rbuilder: a reth-family Flashblocks builder. Uses the same genesis as op-geth.
# No separate builder op-node is required; rollup-boost forwards Engine calls from the primary op-node to drive it.
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/genesis.json}"
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

- [ ] **Step 2: Syntax check + flag validation**

Run: `bash -n scripts/flashblocks/run-op-rbuilder.sh && echo OK && bin/op-rbuilder node --help | grep -E 'flashblocks|sequencer-http' | head`
Expected: `OK`, with the Flashblocks/sequencer flags used by the script visible in the output (if names differ, update the script according to `--help`).

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-op-rbuilder.sh
git commit -m "feat(flashblocks): add run-op-rbuilder launcher"
```

---

## Task 5: `scripts/flashblocks/run-rollup-boost.sh`

**Files:**
- Create: `scripts/flashblocks/run-rollup-boost.sh`

- [ ] **Step 1: Write the launcher** (implementation Section 6.4; includes the debug server)

```bash
#!/bin/bash
# rollup-boost: Engine proxy between op-node and (op-geth fallback + op-rbuilder builder).
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

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

- [ ] **Step 2: Syntax check + flag validation**

Run: `bash -n scripts/flashblocks/run-rollup-boost.sh && echo OK && bin/rollup-boost --help | grep -E 'flashblocks|execution-mode|debug-server-port|builder-url' | head`
Expected: `OK`, with matching flag names (update them according to `--help` if they differ).

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-rollup-boost.sh
git commit -m "feat(flashblocks): add run-rollup-boost launcher"
```

---

## Task 6: `scripts/flashblocks/run-flashblocks-proxy.sh`

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-proxy.sh`

- [ ] **Step 1: Write the launcher** (implementation Section 6.5)

```bash
#!/bin/bash
# Subscribe to rollup-boost's Flashblocks broadcast and fan it out to users.
source .envrc
exec flashblocks-ws-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
```

- [ ] **Step 2: Syntax check + flag validation**

Run: `bash -n scripts/flashblocks/run-flashblocks-proxy.sh && echo OK && bin/flashblocks-ws-proxy --help | grep -E 'upstream|listen' | head`
Expected: `OK`, with matching flag names.

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-proxy.sh
git commit -m "feat(flashblocks): add run-flashblocks-proxy launcher"
```

---

## Task 7: `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh` (op-reth)

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh`

- [ ] **Step 1: Write the launcher** (implementation Section 6.6; `--flashblocks-url` subscribes to ws-proxy, using `ws://` locally)

```bash
#!/bin/bash
# Flashblocks-aware RPC: op-reth subscribes to Flashblocks from ws-proxy and exposes pending state externally.
# run-flashblocks-rpc-op-node.sh drives synchronization of the canonical chain through the Engine API.
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/genesis.json}"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

exec op-reth node \
  --chain "$GENESIS" --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" --http.api eth,web3,net,debug \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
```

- [ ] **Step 2: Syntax check + flag validation**

Run: `bash -n scripts/flashblocks/run-flashblocks-rpc-op-reth.sh && echo OK && bin/op-reth node --help | grep -E 'flashblocks-url|sequencer-http|authrpc' | head`
Expected: `OK`, with matching flag names.

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-rpc-op-reth.sh
git commit -m "feat(flashblocks): add run-op-reth launcher (op-reth)"
```

---

## Task 8: `scripts/flashblocks/run-flashblocks-rpc-op-node.sh` (Verifier op-node)

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-rpc-op-node.sh`

- [ ] **Step 1: Write the launcher** (implementation Section 6.6b; read-only replica, does not produce blocks, uses `--l2.enginekind=reth`)

```bash
#!/bin/bash
# Verifier op-node for the RPC replica: does not produce blocks; only drives op-reth to synchronize the canonical chain through the Engine API.
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"

exec op-node \
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$FB_RPC_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$FB_RPC_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" --p2p.disable
```

- [ ] **Step 2: Syntax check + flag validation**

Run: `bash -n scripts/flashblocks/run-flashblocks-rpc-op-node.sh && echo OK && bin/op-node --help 2>&1 | grep -E 'enginekind|beacon.ignore' | head`
Expected: `OK`; confirm that the local op-node version supports `--l2.enginekind=reth` (remove the flag if unsupported).

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-rpc-op-node.sh
git commit -m "feat(flashblocks): add run-flashblocks-rpc-op-node launcher (verifier)"
```

---

## Task 9: Modify `scripts/chain-ops/run-op-node.sh` (Switch `--l2` by Mode)

**Files:**
- Modify: `scripts/chain-ops/run-op-node.sh:22`

- [ ] **Step 1: Replace base_flags on line 22**

Replace line 22:
```bash
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=http://localhost:8651 --l2.jwt-secret=$JWT_FILE"
```
With:
```bash
# FLASHBLOCKS_MODE=off → connect directly to op-geth (8651); otherwise use rollup-boost (RB_ENGINE_PORT)
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:8651"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
```

- [ ] **Step 2: Syntax check + output for both modes**

Run: `bash -n scripts/chain-ops/run-op-node.sh && echo OK && FLASHBLOCKS_MODE=off bash -c 'source .envrc; source <(sed -n "12,25p" scripts/chain-ops/run-op-node.sh); echo off=$L2_ENGINE_URL' 2>/dev/null; FLASHBLOCKS_MODE=dry_run bash -c 'source .envrc; source <(sed -n "12,25p" scripts/chain-ops/run-op-node.sh); echo dry=$L2_ENGINE_URL' 2>/dev/null`
Expected: `OK`, `off=http://localhost:8651`, and `dry=http://localhost:8551`.
> If the script structure makes the `source <(sed …)` command impractical, inspect both branches manually instead.

- [ ] **Step 3: Verify no regression in off mode (the current chain remains healthy)**

Run: `bash scripts/chain-ops/chain-stop.sh; FLASHBLOCKS_MODE=off bash scripts/chain-ops/chain-start.sh local; sleep 8; cast bn --rpc-url http://localhost:8645`
Expected: The block number increases (the off-mode path is completely unchanged).

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/run-op-node.sh
git commit -m "feat(flashblocks): switch op-node --l2 target by FLASHBLOCKS_MODE"
```

---

## Task 10: Modify `scripts/chain-ops/chain-start.sh` (Start New Components by Mode)

**Files:**
- Modify: `scripts/chain-ops/chain-start.sh`

- [ ] **Step 1: Sequencer-side components (after op-geth, before op-node)**

Insert the following before "Starting op-node" (`echo "Starting op-node..."`):

```bash
# ---------- Flashblocks sequencer side (FLASHBLOCKS_MODE != off) ----------
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

- [ ] **Step 2: User-facing components (at the end of the script, in enabled mode)**

Insert the following before the "All services started" message:

```bash
# ---------- Flashblocks user-facing path (enabled; local mirrors production, so do not omit the proxy) ----------
if [ "${FLASHBLOCKS_MODE:-off}" = "enabled" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  echo "Starting flashblocks ws-proxy..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-proxy.sh" >> "$LOG_DIR/fb-proxy.log" 2>&1 &
  echo $! > "$PID_DIR/fb-proxy.pid"; sleep 1
  echo "Starting flashblocks-aware RPC (op-reth)..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-reth.sh" >> "$LOG_DIR/fb-rpc-reth.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-reth.pid"; sleep 2
  echo "Starting flashblocks RPC verifier op-node..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-node.sh" >> "$LOG_DIR/fb-rpc-opnode.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-opnode.pid"
fi
```

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/chain-ops/chain-start.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/chain-start.sh
git commit -m "feat(flashblocks): start rust comps by FLASHBLOCKS_MODE"
```

---

## Task 11: Modify `scripts/chain-ops/chain-stop.sh` (Stop All Components)

**Files:**
- Modify: `scripts/chain-ops/chain-stop.sh`

- [ ] **Step 1: Add new components to the PID stop list**

Replace:
```bash
for name in op-challenger op-proposer op-batcher op-node op-geth; do
```
With:
```bash
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder op-challenger op-proposer op-batcher op-node op-geth; do
```

- [ ] **Step 2: Append stop_matching_processes calls (before the op-geth line)**

```bash
stop_matching_processes "fb-rpc-opnode"    "op-node "        "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "fb-rpc-reth"       "op-reth "        "--datadir=$DATA_DIR/op-reth"
stop_matching_processes "fb-proxy"     "flashblocks-ws-proxy " "0.0.0.0:${FB_PROXY_PORT:-1113}"
stop_matching_processes "op-rbuilder"  "op-rbuilder "    "--datadir=$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost" "rollup-boost "   "--rpc-port ${RB_ENGINE_PORT:-8551}"
```
> Note: `stop_matching_processes` requires the port variables from `.envrc`. The script already runs `source .envrc` (add it at the top if absent). Base each needle on the actual process command line and verify it with `ps axww | grep` during implementation.

- [ ] **Step 3: Syntax check + smoke test**

Run: `bash -n scripts/chain-ops/chain-stop.sh && echo OK && bash scripts/chain-ops/chain-stop.sh`
Expected: `OK`, followed by normal Stopped/Done output with no errors.

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/chain-stop.sh
git commit -m "feat(flashblocks): stop rust comps in chain-stop"
```

---

## Task 12: `chain-reset.sh` — No Changes Required (Validation Only)

**Conclusion: No code changes.** `scripts/deploy-chain/chain-reset.sh:109` runs `rm -rf "$DATA_DIR"` (the entire `data/` directory), so its `data/op-rbuilder` and `data/op-reth` subdirectories are **automatically removed** without adding them to an allowlist.

- [ ] **Step 1: Confirm that reset deletes the entire directory**

Run: `grep -n 'rm -rf' scripts/deploy-chain/chain-reset.sh`
Expected: Matches `rm -rf "$DATA_DIR"` (`DATA_DIR="$BASE_PATH/data"`). This confirms that the new data directories are covered; this task requires no changes or commit.

---

## Validation Gates (P0–P5, Pass Sequentially; Corresponds to Implementation Section 7)

> These are the plan's integration tests. Do not proceed to the next gate until the previous one passes.

## Task V0: P0 — Build + Chain Spec Loading + Genesis Alignment

- [ ] **Step 1: Confirm that all binaries exist** (produced by Task 2)

Run: `ls -1 bin/{rollup-boost,flashblocks-ws-proxy,op-rbuilder,op-reth}`
Expected: All four files exist.

- [ ] **Step 2: Confirm that reth-family components can parse this chain's genesis**

Run: `bin/op-rbuilder node --chain config/local-mainnet/genesis.json --datadir /tmp/rb-probe --http --http.port 8663 >/tmp/rb.log 2>&1 & sleep 8; cast block 0 --rpc-url http://localhost:8663 -f hash; kill %1 2>/dev/null; rm -rf /tmp/rb-probe`
Expected: Prints the genesis block hash (the component starts and parses the genesis). If a genesis format error occurs, stop and resolve parsing/conversion first.

- [ ] **Step 3: Confirm that the genesis hash matches op-geth**

Run: `echo geth=$(cast block 0 --rpc-url http://localhost:8645 -f hash); echo rbuilder=<hash from the previous step>`
Expected: The two values are identical.
- **Gate (P0)**: The reth-family component loads the genesis successfully, and its genesis hash equals op-geth's.

---

## Task V1: P1 — op-rbuilder Shadow Synchronization

- [ ] **Step 1: Ensure the chain is running in off mode and start op-rbuilder to catch up on history** (`--rollup.sequencer-http=$L2_RPC_URL`)
- [ ] **Step 2: Compare blocks individually** (implementation Section 8.1, focusing on Granite/Holocene/Isthmus/Jovian activation blocks plus a sample of ordinary blocks)

Run:
```bash
for BN in <granite> <holocene> <isthmus> <jovian> $(cast bn --rpc-url http://localhost:8645); do
  A=$(cast block $BN --rpc-url http://localhost:8645 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  B=$(cast block $BN --rpc-url http://localhost:8663 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  [ "$A" = "$B" ] && echo "OK $BN" || echo "DIFF $BN | geth=$A | rbuilder=$B"
done
```
Expected: All key and sampled blocks report `OK`; op-rbuilder catches up to the chain head; no invalid blocks occur.
- **Gate (P1)**: Zero divergence. If any `DIFF` appears, use the narrowing procedure in implementation Section 8.4.

---

## Task V2: P2 — dry_run

- [ ] **Step 1: Switch to dry_run and restart**

Run: `sed -i '' 's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=dry_run/' .envrc && source .envrc && bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local`
Expected: op-rbuilder + rollup-boost start; op-node `--l2` points to 8551; blocks are produced normally every 2 seconds.

- [ ] **Step 2: Cover scenarios**: ordinary transfers / contract calls / failed transactions / CGT gas / deposits / withdrawals / L1 origin changes.
- [ ] **Step 3: Assert VALID**

Run: `grep -iE 'invalid payload|VALID' data/logs/rollup-boost.log | tail -50`
Expected: All builder payloads are `VALID`, `Invalid payload = 0`, and batcher/proposer/challenger show no errors.
- **Gate (P2)**: The dry_run divergence count is zero.

---

## Task V3: P3 — enabled + Flashblocks Production

- [ ] **Step 1: Enter enabled mode (choose one)**
  - Hot switch: `bin/rollup-boost debug set-execution-mode enabled` (connect to `RB_DEBUG_PORT`), or use `curl` with `debug_setExecutionMode`.
  - Restart: Set `FLASHBLOCKS_MODE=enabled` and restart through `chain-ops`.
- [ ] **Step 2: Observe the Flashblocks stream**

Run: `websocat ws://localhost:1112 | head -20` (or `ws://localhost:1113`)
Expected: Approximately one flashblock every 250 ms.

- [ ] **Step 3: Test fallback when the builder disconnects**

Run: `kill op-rbuilder independently without running bash scripts/chain-ops/chain-stop.sh; observe rollup-boost falling back to op-geth for block production without interrupting the chain; after restoring op-rbuilder, Flashblocks should recover automatically`
- **Gate (P3)**: Flashblocks are produced consistently; disconnection triggers fallback without interrupting the chain.

---

## Task V4: P4 — Basic User-facing Check

- [ ] **Step 1: Confirm that op-reth RPC is reachable**

Run: `cast bn --rpc-url http://localhost:8745`
Expected: A block number is returned.

- [ ] **Step 2: Confirm sub-second pending preconfirmations**

Run: `bash scripts/flashblocks/verify/p4-user-facing.sh`
Expected: Every sample transaction appears in `pending` before it is sealed, in under one second.
- **Gate (P4)**: All sample transactions pass the sub-second preconfirmation check.

---

## Task V5: P5 — Local Acceptance + Fallback Drill

- [ ] **Step 1: Run one complete scenario** (functionality + Fault Proof regression check: unchanged proposer/challenger behavior + failure fallback)
- [ ] **Step 2: Validate hard fallback**

Run: `sed -i '' 's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=off/' .envrc && source .envrc && bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local; sleep 8; cast bn --rpc-url http://localhost:8645`
Expected: op-node connects directly to op-geth (8651), the chain produces blocks normally, and the architecture returns to its pre-integration state.
- **Gate (P5)**: The entire acceptance checklist passes, establishing production readiness.

- [ ] **Step 3: Record the acceptance results** (implementation Section 11 deliverable) and commit the acceptance record, if any.

---

## Fallback Strategy (Available at Any Time)

| Level | Action |
|---|---|
| Hot downgrade (no chain interruption) | `rollup-boost debug set-execution-mode dry-run` (`RB_DEBUG_PORT`) |
| Downgrade (restart) | `FLASHBLOCKS_MODE=dry_run` + restart through `chain-ops` |
| Bypass the sidecar | `FLASHBLOCKS_MODE=off` + restart through `chain-ops` (op-node connects directly to 8651) |
| Disable only the user-facing path | `SKIP_FB_USER=1` or stop fb-proxy/fb-rpc-reth/fb-rpc-opnode |

---

## Notes / Risks (Monitor During Implementation; See Implementation Section 10)
- **Version generation**: Submodules must remain at `v0.7.11 / v0.2.13 / v1.9.3`; do not check out main.
- **No official CGT compatibility guarantee**: Establish compatibility empirically through `VALID` results in P2 dry_run.
- **Consistent genesis/JWT values** are prerequisites for every comparison.
- **op-reth `wss://` TLS**: Use `ws://` throughout local operation.
- **Flag names vary by version**: Validate every launcher against `--help` before implementation.
- **Commits are performed manually**: Every `git commit`/`git add` step in this plan is for reference only. The implementation agent (including subagents) **must not run any Git commit automatically**. After each task's changes and syntax/smoke checks are complete, stop and let the user commit.
