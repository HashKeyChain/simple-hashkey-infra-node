# Flashblocks Surgical Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use hsk-superpowers:executing-plans to execute this plan task by task. Track steps with `- [ ]` checkboxes.

**Goal:** Surgically switch a running Jovian chain in `off` mode (node + geth) to Flashblocks `dry_run`: start op-rbuilder only once and keep it running throughout; the switch only transfers Engine control (builder op-node → rollup-boost) and reroutes the primary op-node.

**Architecture:** Three-phase lifecycle: OFF (op-geth + directly connected op-node) → SYNC (+op-rbuilder + builder op-node, with builder op-node driving op-rbuilder to catch up) → FLASHBLOCKS (op-geth + op-rbuilder + rollup-boost + op-node through rollup-boost, with rollup-boost driving op-rbuilder and builder op-node stopped). The switch uses `admin_stopSequencer` to freeze the height for a clean handoff. op-geth and op-rbuilder remain untouched throughout; only the primary op-node is restarted to change its `--l2` target.

**Tech Stack:** Bash orchestration scripts, OP Stack (op-geth / op-node cgt-jovian v1.16.5), Flashblocks (rollup-boost v0.7.11 / op-rbuilder v0.2.13 / op-reth v1.9.3), Foundry `cast`, and direnv `.envrc`.

---

## Design Invariants

1. **The op-rbuilder Engine (auth RPC = `RBUILDER_AUTHRPC_PORT=8661`) may have only one consensus driver at a time.**
   - SYNC phase: builder op-node (`--l2=http://localhost:8661`).
   - FLASHBLOCKS phase: rollup-boost (`--builder-url 127.0.0.1:8661`).
   - They **must not coexist** → stop builder op-node before rollup-boost takes control.
2. **Start op-rbuilder only once and never stop it during the switch** (the defining property of the surgical approach, as opposed to a full restart).
3. **Leave op-geth untouched throughout** (after the switch, rollup-boost calls its Engine instead of op-node calling it directly).
4. **Set `FLASHBLOCKS_MODE` in `.envrc` to `dry_run` before starting rollup-boost or restarting op-node**, because `run-rollup-boost.sh` and `run-op-node.sh` both run `source .envrc` and use it to select the execution mode and `--l2` target.
5. **Failures are recoverable**: If any step fails, restore the stopped sequencer where possible and stop newly started synchronization processes so the chain returns to `off` without remaining in a partial state.

## Phase, Component, and Driver Matrix

| Phase | Components | op-rbuilder Driver | op-node --l2 |
|---|---|---|---|
| OFF | op-geth, op-node | — (no op-rbuilder) | op-geth :8651 |
| SYNC | +op-rbuilder, +builder op-node | builder op-node | op-geth :8651 |
| FLASHBLOCKS(dry_run) | op-geth, op-rbuilder, rollup-boost, op-node | rollup-boost | rollup-boost :8551 |

## Port Reference (from `.envrc`)

- op-geth: L2 RPC 8645, Engine 8651
- op-node: RPC 9545 (`--rpc.enable-admin`), CL p2p TCP 9222
- op-rbuilder: authrpc 8661, HTTP 8663, flashblocks-out WebSocket 1111, RLPx 30313
- builder op-node: RPC 9565, CL p2p TCP 9223
- rollup-boost: Engine 8551, Flashblocks broadcast 1112, debug 5555

## File Structure

- **Modify**: `scripts/flashblocks/switch-to-flashblocks-dryrun.sh` — rewrite from full restart to surgical switch (core change).
- **Verify (completed in earlier changes; validation only)**:
  - `scripts/flashblocks/start-sequencer-side.sh` — the Flashblocks topology starts only op-rbuilder + rollup-boost (no builder op-node).
  - `scripts/chain-ops/chain-start.sh` — sources the preceding script when `mode!=off`.
  - `scripts/chain-ops/chain-stop.sh` — the stop list includes op-rbuilder-opnode / op-rbuilder / rollup-boost.
- **Modify**: `doc/flashblocks_local_impl.md` — add the phase matrix, driver handoff, and surgical switch procedure.

---

## Task 1: Validate Existing Flashblocks Topology Script Consistency (No Builder op-node)

**Files:**
- Verify: `scripts/flashblocks/start-sequencer-side.sh`
- Verify: `scripts/chain-ops/chain-start.sh:148-150`
- Verify: `scripts/chain-ops/chain-stop.sh`

- [ ] **Step 1: Confirm that start-sequencer-side.sh starts only op-rbuilder + rollup-boost**

Run: `grep -nE 'run-op-rbuilder-opnode|run-op-rbuilder\.sh|run-rollup-boost' scripts/flashblocks/start-sequencer-side.sh`
Expected: Only `run-op-rbuilder.sh` and `run-rollup-boost.sh` appear; `run-op-rbuilder-opnode.sh` **does not appear**.

- [ ] **Step 2: Confirm that chain-stop can still clean up a residual builder op-node**

Run: `grep -n 'op-rbuilder-opnode' scripts/flashblocks/stop-flashblocks.sh`
Expected: A match is found (PID list + `--rpc.port=${RBUILDER_OPNODE_PORT}` matching).

## Task 2: Rewrite switch-to-flashblocks-dryrun.sh as a Surgical Switch

**Files:**
- Modify: `scripts/flashblocks/switch-to-flashblocks-dryrun.sh` (replace the entire file)

- [ ] **Step 1: Write the complete script below** (see "Complete Script" below)

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/flashblocks/switch-to-flashblocks-dryrun.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Smoke test argument parsing and early preflight exit (without actually starting the chain)**

Run: `bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh --lag=abc 2>&1 | head -1`
Expected: Prints `Error: --lag must be a non-negative integer` and exits with a nonzero status.

### Complete Script

```bash
#!/bin/bash
#
# One command: surgically switch a running node+geth (off) chain to Flashblocks dry_run.
# Core principle: start op-rbuilder once and never stop it; only hand off Engine control and reroute op-node.
#
# Phases and op-rbuilder Engine control:
#   OFF        : op-geth + op-node (direct connection to geth :8651)
#   SYNC       : + op-rbuilder + builder op-node (builder op-node drives op-rbuilder to catch up)
#   FLASHBLOCKS: op-geth + op-rbuilder + rollup-boost + op-node (through rollup-boost :8551)
#                rollup-boost takes control of op-rbuilder; builder op-node stops (otherwise both contend for the same auth RPC)
#
# Procedure:
#   [1] Preflight  [2] Start sync nodes (op-rbuilder + builder op-node)  [3] Approximate catch-up
#   [4] Freeze at height H with admin_stopSequencer  [5] Exact catch-up to H  [6] Stop builder op-node
#   [7] Write dry_run to .envrc  [8] Start rollup-boost  [9] Restart only op-node (reroute)  [10] Validate
#
# Usage:
#   bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC]
# Options:
#   --lag=N        Catch-up threshold (default: 2)  --timeout=SEC Maximum wait for catch-up in seconds (default: 1800)
#
# Prerequisites: Rust components are built in bin/ (bash scripts/flashblocks/build-flashblocks.sh), and the chain is running in off mode.
#
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"
source .envrc

FB_DIR="$BASE_PATH/scripts/flashblocks"
CHAIN_OPS_DIR="$BASE_PATH/scripts/chain-ops"
DATA_DIR="$BASE_PATH/data"
LOG_DIR="$DATA_DIR/logs"
PID_DIR="$DATA_DIR/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# ---------- Arguments ----------
CHAIN_ENV=""; LAG=2; TIMEOUT=1800
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --lag=*)      LAG="${arg#*=}" ;;
    --timeout=*)  TIMEOUT="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC]" >&2
       exit 1 ;;
  esac
done
case "$LAG" in ''|*[!0-9]*) echo "Error: --lag must be a non-negative integer" >&2; exit 1 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "Error: --timeout must be a non-negative integer" >&2; exit 1 ;; esac
if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then CHAIN_ENV=local; else CHAIN_ENV=remote; fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
RB_RPC="http://localhost:${RBUILDER_HTTP_PORT:-8663}"
OPNODE_RPC="${OP_NODE_RPC_URL:-http://localhost:9545}"
SEQ_P2P_KEY="$DATA_DIR/op-node/p2p_priv.txt"

get_bn() { local n; n=$(cast bn --rpc-url "$1" 2>/dev/null || echo ""); case "$n" in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac; }

# Stop an individual component using its PID file (only if present)
stop_pidfile() {
  local name="$1" f="$PID_DIR/$1.pid" pid
  [ -f "$f" ] || return 0
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$f"
}
# Stop residual processes by command-line signature (without terminating Cursor helper processes)
stop_match() {
  local needle1="$1" needle2="$2" pid command
  while read -r pid command; do
    [ -z "$pid" ] && continue
    case "$command" in *"$needle1"*) : ;; *) continue ;; esac
    case "$command" in *"$needle2"*) : ;; *) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done < <(ps axww -o pid= -o command=)
}
stop_builder_opnode() { stop_pidfile op-rbuilder-opnode; stop_match "op-node " "--rpc.port=${RBUILDER_OPNODE_PORT:-9565}"; }
stop_main_opnode()    { stop_pidfile op-node;            stop_match "op-node " "--safedb.path=$DATA_DIR/op-node/safedb"; }

# Cleanup after synchronization process startup fails (stop op-rbuilder + builder op-node started by this script and return the chain to off)
cleanup_sync_nodes() {
  stop_builder_opnode
  stop_pidfile op-rbuilder; stop_match "op-rbuilder " "$DATA_DIR/op-rbuilder"
}

echo "============================================"
echo "  Surgical switch off → flashblocks dry_run ($CHAIN_ENV)"
echo "============================================"
echo "  op-geth      = $L2_RPC   (Engine :8651)"
echo "  op-node      = $OPNODE_RPC (admin)"
echo "  op-rbuilder  = $RB_RPC"
echo "  rollup-boost = :${RB_ENGINE_PORT:-8551}"
echo "  lag/timeout  = ${LAG} / ${TIMEOUT}s"
echo ""

# ---------- [1] Preflight ----------
echo "[1] Preflight..."
[ "${FLASHBLOCKS_MODE:-off}" = "off" ] || echo "  WARN: Current .envrc FLASHBLOCKS_MODE=$FLASHBLOCKS_MODE (expected off)."
[ "$(get_bn "$L2_RPC")" -ge 0 ] || { echo "Error: op-geth is unreachable ($L2_RPC). Confirm that the chain is running in off mode." >&2; exit 1; }
if ! cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 && ! cast bn --rpc-url "$OPNODE_RPC" >/dev/null 2>&1; then
  echo "Error: op-node is unreachable ($OPNODE_RPC)." >&2; exit 1
fi
[ -x "$BASE_PATH/bin/op-rbuilder" ]  || { echo "Error: bin/op-rbuilder is missing. Run bash scripts/flashblocks/build-flashblocks.sh first." >&2; exit 1; }
[ -x "$BASE_PATH/bin/rollup-boost" ] || { echo "Error: bin/rollup-boost is missing. Run bash scripts/flashblocks/build-flashblocks.sh first." >&2; exit 1; }
if ! (exec 3<>"/dev/tcp/127.0.0.1/${SEQ_P2P_TCP_PORT:-9222}") 2>/dev/null; then
  echo "Error: Primary op-node CL p2p port ${SEQ_P2P_TCP_PORT:-9222} is not listening; builder op-node cannot receive unsafe gossip." >&2
  echo "       First restart the off-mode chain so op-node enables p2p: bash $CHAIN_OPS_DIR/chain-stop.sh && bash $CHAIN_OPS_DIR/chain-start.sh $CHAIN_ENV" >&2
  exit 1
fi
exec 3>&- 2>/dev/null || true
echo "  OK."
echo ""

# ---------- [2] Start synchronization nodes ----------
echo "[2] Starting synchronization nodes: op-rbuilder + builder op-node..."
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
export _CALLER_OP_GETH_GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
if [ -f "$SEQ_P2P_KEY" ]; then
  SEQ_PEER_ID=$(op-node p2p priv2id < "$SEQ_P2P_KEY" | tail -1)
  export _CALLER_SEQ_P2P_MULTIADDR="/ip4/127.0.0.1/tcp/${SEQ_P2P_TCP_PORT:-9222}/p2p/${SEQ_PEER_ID}"
  echo "  Sequencer static multiaddress: $_CALLER_SEQ_P2P_MULTIADDR"
else
  echo "  WARN: $SEQ_P2P_KEY not found; builder op-node falls back to L1-only derivation (up to the safe head)."
fi
nohup bash "$FB_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder.pid"
echo "  op-rbuilder started (pid $(cat "$PID_DIR/op-rbuilder.pid"))"
sleep 3
nohup bash "$FB_DIR/run-op-rbuilder-opnode.sh" >> "$LOG_DIR/op-rbuilder-opnode.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder-opnode.pid"
echo "  builder op-node started (pid $(cat "$PID_DIR/op-rbuilder-opnode.pid"))"
echo ""

# ---------- [3] Approximate catch-up ----------
echo "[3] Waiting for op-rbuilder to approximately catch up with op-geth (|Δ| ≤ $LAG, ≤ ${TIMEOUT}s)..."
caught=0
for i in $(seq 1 "$TIMEOUT"); do
  g=$(get_bn "$L2_RPC"); r=$(get_bn "$RB_RPC")
  if [ "$r" -ge 0 ] && [ "$g" -ge 0 ] && [ "$r" -gt 0 ]; then
    d=$(( g - r )); [ "$d" -lt 0 ] && d=$(( -d ))
    { [ $(( i % 5 )) -eq 0 ] || [ "$d" -le "$LAG" ]; } && echo "  op-geth=$g op-rbuilder=$r Δ=$d"
    [ "$d" -le "$LAG" ] && { caught=1; break; }
  else
    [ $(( i % 5 )) -eq 0 ] && echo "  Waiting for op-rbuilder RPC to become ready... (op-rbuilder=$r)"
  fi
  sleep 1
done
if [ "$caught" != 1 ]; then
  echo "Error: Approximate catch-up did not complete within ${TIMEOUT}s. Rolling back by stopping synchronization processes; the chain remains off." >&2
  cleanup_sync_nodes
  exit 1
fi
echo "  Approximate catch-up OK."
echo ""

# ---------- [4] Freeze height ----------
echo "[4] Freezing primary op-node block production with admin_stopSequencer..."
STOP_HASH=$(cast rpc admin_stopSequencer --rpc-url "$OPNODE_RPC" 2>/dev/null | tr -d '"')
if [ -z "$STOP_HASH" ]; then
  echo "Error: admin_stopSequencer failed (admin is not enabled on op-node, or op-node is not the sequencer). Rolling back by stopping synchronization processes." >&2
  cleanup_sync_nodes
  exit 1
fi
echo "  Paused; frozen head hash=$STOP_HASH"
echo ""

# Rollback: resume the sequencer + stop synchronization processes (used if [5] fails)
rollback_resume() {
  echo "  Rollback: resuming block production with admin_startSequencer..." >&2
  cast rpc admin_startSequencer "$STOP_HASH" --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 || true
  cleanup_sync_nodes
}

# ---------- [5] Exact catch-up to H ----------
H=$(get_bn "$L2_RPC")
echo "[5] Waiting for op-rbuilder to catch up exactly to frozen height H=$H (≤ 120s)..."
exact=0
for i in $(seq 1 120); do
  r=$(get_bn "$RB_RPC")
  [ "$r" -ge "$H" ] && { exact=1; echo "  op-rbuilder=$r ≥ H=$H; target reached."; break; }
  [ $(( i % 5 )) -eq 0 ] && echo "  op-rbuilder=$r / H=$H"
  sleep 1
done
if [ "$exact" != 1 ]; then
  echo "Error: op-rbuilder did not reach H=$H within 120s. Rolling back." >&2
  rollback_resume
  exit 1
fi
echo ""

# ---------- [6] Stop builder op-node (release the op-rbuilder Engine) ----------
echo "[6] Stopping builder op-node (releasing control of the op-rbuilder Engine)..."
stop_builder_opnode
sleep 2
echo ""

# ---------- [7] Write dry_run to .envrc ----------
echo "[7] Writing FLASHBLOCKS_MODE=dry_run to .envrc"
python3 - <<'PY'
import re; from pathlib import Path
p=Path(".envrc"); t=p.read_text()
pat=re.compile(r'^export FLASHBLOCKS_MODE=.*$', re.M)
t=pat.sub('export FLASHBLOCKS_MODE=dry_run', t) if pat.search(t) else t.rstrip("\n")+"\nexport FLASHBLOCKS_MODE=dry_run\n"
p.write_text(t); print("  done")
PY
export FLASHBLOCKS_MODE=dry_run
echo ""

# ---------- [8] Start rollup-boost (take control of op-rbuilder) ----------
echo "[8] Starting rollup-boost (dry-run)..."
export _CALLER_OP_GETH_DATA_PATH="$DATA_DIR/op-geth"
export _CALLER_JWT_FILE="$DATA_DIR/op-geth/jwt.txt"
nohup bash "$FB_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
echo $! > "$PID_DIR/rollup-boost.pid"
echo "  rollup-boost started (pid $(cat "$PID_DIR/rollup-boost.pid"))"
sleep 3
echo ""

# ---------- [9] Restart only op-node (reroute to rollup-boost) ----------
echo "[9] Restarting primary op-node (--l2 → rollup-boost :${RB_ENGINE_PORT:-8551})..."
stop_main_opnode
sleep 2
export _CALLER_OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
nohup bash "$CHAIN_OPS_DIR/run-op-node.sh" >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat "$PID_DIR/op-node.pid"))"
echo ""

# ---------- [10] Validate ----------
echo "[10] Validating block production progress..."
b0=$(get_bn "$L2_RPC"); ok=0
for i in $(seq 1 30); do
  sleep 2; b1=$(get_bn "$L2_RPC")
  [ "$b1" -gt "$b0" ] && { ok=1; echo "  Block production advanced from $b0 → $b1; switch succeeded."; break; }
done
[ "$ok" = 1 ] || echo "  WARN: No block production progress after 30 iterations; check $LOG_DIR/op-node.log and rollup-boost.log. If op-node did not resume block production automatically, run cast rpc admin_startSequencer <hash> --rpc-url $OPNODE_RPC"
echo ""
echo "=== Complete: switched to dry_run ==="
echo "  Validate builder payloads: tail -f $LOG_DIR/rollup-boost.log (all should be VALID)"
echo "  Switch to enabled: set FLASHBLOCKS_MODE=enabled in .envrc, then run chain-stop && chain-start $CHAIN_ENV"
echo "            (or hot-switch: rollup-boost debug set-execution-mode enabled, connecting to RB_DEBUG_PORT=${RB_DEBUG_PORT:-5555})"
```

## Task 3: Synchronize Documentation (Phase Matrix + Driver Handoff + Surgical Procedure)

**Files:**
- Modify: `doc/flashblocks_local_impl.md` (P1/switch-related sections)

- [ ] **Step 1: Add the phase/driver matrix and ten-step surgical procedure to the switch section** (using the "Phase, Component, and Driver Matrix" and script header from this plan).

- [ ] **Step 2: Verify that no obsolete descriptions remain**

Run: `grep -nE 'fullrestart|full chain-stop' doc/flashblocks_local_impl.md`
Expected: If full restart is still described as the recommended path, change it to surgical.

## Task 4: Full Syntax and Consistency Checks

- [ ] **Step 1:** All `bash -n` checks pass

Run: `for f in scripts/flashblocks/*.sh scripts/chain-ops/chain-start.sh scripts/chain-ops/chain-stop.sh; do bash -n "$f" && echo "OK $f"; done`
Expected: All output is `OK`.

- [ ] **Step 2:** Confirm that builder op-node and rollup-boost never connect to op-rbuilder simultaneously in the Flashblocks topology

Run: `grep -n '8661\|RBUILDER_AUTHRPC_PORT' scripts/flashblocks/run-op-rbuilder-opnode.sh scripts/flashblocks/run-rollup-boost.sh`
Expected: Both connect to 8661, confirming that the same auth RPC requires mutually exclusive phases.

---

## Rollback and Safety

- Every switch step has a rollback path: if `[3]` fails, stop synchronization processes; if `[5]` fails, use `admin_startSequencer` to resume block production and stop synchronization processes. The chain returns to `off` without remaining in a partial state.
- This is entirely local orchestration, with no external input or new network exposure; `cast rpc admin_*` targets only the local op-node.
- Before switching to `enabled`, monitor rollup-boost logs in `dry_run` and confirm that all builder payloads are `VALID`.
