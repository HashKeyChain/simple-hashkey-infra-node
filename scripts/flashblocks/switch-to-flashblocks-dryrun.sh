#!/bin/bash
#
# One-command surgical switch of a running node+geth chain in off mode to Flashblocks
# dry_run. The key invariant is that op-rbuilder starts once and is never killed during
# the process; switching only transfers Engine control and reroutes op-node.
#
# Phases and op-rbuilder Engine control:
#   OFF        : op-geth + op-node (connected directly to geth :8651)
#   SYNC       : + op-rbuilder + builder op-node (the builder op-node drives
#                op-rbuilder synchronization)
#   FLASHBLOCKS: op-geth + op-rbuilder + rollup-boost + op-node + user-facing shadow RPC
#                (through rollup-boost :8551). rollup-boost takes control of op-rbuilder,
#                and the builder op-node stops to avoid competing for the same auth RPC.
#
# Flow:
#   [1] Preflight, including op-node restart safety: the chain must pass the Holocene
#       boundary plus one channel_timeout.
#   [2] Start synchronization nodes (op-rbuilder + builder op-node).
#   [3] Catch up approximately.
#   [4] Freeze height H with admin_stopSequencer.
#   [5] Catch up exactly to H.
#   [6] Stop the builder op-node.
#   [7] Write dry_run to .envrc.
#   [8] Start rollup-boost.
#   [9] Restart only op-node to reroute it.
#   [10] Start the user-facing shadow topology.
#   [11] Verify.
#
# Usage:
#   bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC] [--no-wait]
# Options:
#   --lag=N        Catch-up threshold (default: 2).
#   --timeout=SEC  Maximum seconds to wait for catch-up or the safe op-node restart
#                  window (default: 1800).
#   --no-wait      Fail immediately if the restart-safety window is not ready instead
#                  of polling (polling is the default).
#
# Prerequisites: Rust components are built into bin/ using
# bash scripts/flashblocks/build-flashblocks.sh, and the chain is running in off mode.
#
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"
source .envrc

FB_DIR="$BASE_PATH/scripts/flashblocks"
# shellcheck source=scripts/flashblocks/envrc-mode.sh
source "$FB_DIR/envrc-mode.sh"
CHAIN_OPS_DIR="$BASE_PATH/scripts/chain-ops"
DATA_DIR="$BASE_PATH/data"
LOG_DIR="$DATA_DIR/logs"
PID_DIR="$DATA_DIR/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# ---------- Arguments ----------
CHAIN_ENV=""; LAG=2; TIMEOUT=1800; NO_WAIT=0
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --lag=*)      LAG="${arg#*=}" ;;
    --timeout=*)  TIMEOUT="${arg#*=}" ;;
    --no-wait)    NO_WAIT=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC] [--no-wait]" >&2
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

# Find the first L1 block whose timestamp is >= $1 by binary search over [$2, $3].
# Return 1 if no such block exists in the interval.
l1_first_block_at_or_after() {
  local target="$1" lo="$2" hi="$3" mid ts ans=""
  ts=$(cast block "$hi" -f timestamp --rpc-url "$L1_RPC_URL" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ts" -ge "$target" ] || return 1
  while [ "$lo" -le "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    ts=$(cast block "$mid" -f timestamp --rpc-url "$L1_RPC_URL" 2>/dev/null)
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$ts" -ge "$target" ]; then ans="$mid"; hi=$(( mid - 1 )); else lo=$(( mid + 1 )); fi
  done
  [ -n "$ans" ] || return 1
  echo "$ans"
}

# Step [9] restarts the primary op-node. On startup, its derivation pipeline moves the L1
# read origin back by one channel_timeout (50 L1 blocks after Granite, 300 before it),
# stopping at L1 genesis if necessary. If that origin precedes Holocene activation,
# BatchMux installs the pre-Holocene BatchQueue. While replaying an old batch, validation
# returns BatchPast because the batch's L1 block is already after Holocene. BatchQueue
# does not recognize that value, exits critically, and repeats the failure on every
# restart. This check blocks the switch in advance when the chain is too young.
#
# Probe once and print one result line to stdout, distinguished by return code:
#   0  ok    <safe_origin> <bound> <ct>          Ready to switch.
#   1  wait  <safe_origin> <bound> <ct> <need>   Not ready; advancing safe head will satisfy it.
#   1  retry <reason>                             Data unavailable this round; retry.
#   2  skip  <reason>                             Not required or indeterminate; allow the switch.
probe_opnode_restart_safe() {
  local rollup_json="$DEPLOYMENT_CONFIG_PATH/rollup.json"
  [ -f "$rollup_json" ] || { echo "skip cannot find $rollup_json"; return 2; }

  local holocene_t granite_t
  holocene_t=$(jq -r '.holocene_time // empty' "$rollup_json" 2>/dev/null)
  granite_t=$(jq -r '.granite_time // empty' "$rollup_json" 2>/dev/null)
  # If inactive or active at genesis, L1 genesis itself is after Holocene, so a full
  # rollback is safe.
  case "$holocene_t" in ''|null|0) echo "skip Holocene is inactive or active at genesis"; return 2 ;; esac

  local genesis_l1
  genesis_l1=$(jq -r '.genesis.l1.number' "$rollup_json" 2>/dev/null)
  case "$genesis_l1" in ''|null|*[!0-9]*) echo "skip cannot read genesis.l1.number"; return 2 ;; esac

  local safe_origin l1_head
  safe_origin=$(cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" 2>/dev/null | jq -r '.safe_l2.l1origin.number // empty')
  case "$safe_origin" in ''|null|*[!0-9]*) echo "retry cannot read the L1 origin of safe_l2"; return 1 ;; esac
  l1_head=$(get_bn "$L1_RPC_URL")
  [ "$l1_head" -ge 0 ] || { echo "retry cannot read L1 height"; return 1; }

  # The rollback origin must be after the Holocene boundary. channel_timeout is 50 only
  # when Granite is also active, so the origin must also be after Granite; otherwise,
  # the timeout changes back to 300 during rollback and moves the origin farther back.
  local bound ct=300 hol_blk gra_blk
  hol_blk=$(l1_first_block_at_or_after "$holocene_t" "$genesis_l1" "$l1_head") \
    || { echo "retry L1 has no block with timestamp >= holocene_time($holocene_t)"; return 1; }
  bound="$hol_blk"
  if [ -n "$granite_t" ] && [ "$granite_t" != null ] && [ "$granite_t" != 0 ]; then
    if gra_blk=$(l1_first_block_at_or_after "$granite_t" "$genesis_l1" "$l1_head"); then
      [ "$gra_blk" -gt "$bound" ] && bound="$gra_blk"
      ct=50
    fi
  fi

  if [ $(( safe_origin - ct )) -lt "$bound" ]; then
    echo "wait $safe_origin $bound $ct $(( bound + ct ))"; return 1
  fi
  echo "ok $safe_origin $bound $ct"; return 0
}

# Poll until the condition is met by default, up to ${TIMEOUT}; with --no-wait, check
# once and exit if it is not met. Use ${VAR} when a variable is followed immediately by
# non-ASCII punctuation: Bash 3.2 under a UTF-8 locale may absorb the punctuation's first
# byte into the variable name and exit with "unbound variable" under set -u.
check_opnode_restart_safe() {
  local deadline=$(( $(date +%s) + TIMEOUT )) announced=0 out st
  while :; do
    out=$(probe_opnode_restart_safe); st=$?
    # set -- changes positional parameters only within this function.
    set -- $out
    case "$st" in
      2) echo "  op-node restart safety: check skipped (${*:2})"; return 0 ;;
      0) echo "  op-node restart safety: safe_origin=$2  channel_timeout=$4  rollback_origin=$(( $2 - $4 ))  required >= $3"; return 0 ;;
    esac

    local detail secs=""
    if [ "$1" = "wait" ]; then
      secs=$(( ($5 - $2) * ${L1_BLOCK_TIME:-12} ))
      detail="safe_origin=$2 must reach $5 (rollback origin $(( $2 - $4 )) < boundary $3), approximately ${secs}s remaining"
    else
      detail="${*:2}"
    fi

    if [ "$NO_WAIT" = 1 ]; then
      echo "Error: switching now would crash op-node when it restarts in step [9] (derivation crit: unknown batch validity type: 4)." >&2
      echo "       $detail" >&2
      echo "       Remove --no-wait to wait automatically; if safe head remains stalled, check whether op-batcher is submitting." >&2
      return 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Error: op-node restart-safety window was still unavailable after ${TIMEOUT}s: $detail" >&2
      echo "       safe head may be stalled; check whether op-batcher is submitting (data/logs/op-batcher.log)." >&2
      return 1
    fi
    if [ "$announced" = 0 ]; then
      echo "  op-node restart safety: condition not met; waiting up to ${TIMEOUT}s (--no-wait fails immediately)"
      announced=1
    fi
    echo "    $detail"
    sleep 10
  done
}

# Stop one component by PID file if present.
stop_pidfile() {
  local name="$1" f="$PID_DIR/$1.pid" pid
  [ -f "$f" ] || return 0
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$f"
}
# Stop residual processes by command-line signature without killing Cursor helpers.
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

# Cleanup after synchronization startup failure: stop the op-rbuilder and builder op-node
# started by this script and return the chain to off mode.
cleanup_sync_nodes() {
  stop_builder_opnode
  stop_pidfile op-rbuilder; stop_match "op-rbuilder " "$DATA_DIR/op-rbuilder"
}
stop_rollup_boost() { stop_pidfile rollup-boost; stop_match "rollup-boost " "--rpc-port ${RB_ENGINE_PORT:-8551}"; }

# ---------- Interruption protection ----------
# Beginning with step [2], this script changes the live topology by starting
# synchronization processes, freezing block production, and modifying .envrc. If
# interrupted without cleanup by Ctrl-C, a signal, or an unexpected exit, it can leave
# synchronization processes running, the sequencer frozen, and rollup-boost absent,
# with no obvious external symptom. An EXIT trap rolls back each completed phase.
# PHASE: 0=nothing changed, 1=sync processes started, 2=block production frozen,
#        3=Engine control transferred and rollup-boost started.
PHASE=0
STOP_HASH=""
SWITCH_DONE=0

on_exit() {
  local rc=$?
  { [ "$SWITCH_DONE" = 1 ] || [ "$PHASE" = 0 ]; } && return 0
  echo "" >&2
  echo "!! Switch exited before completion (exit=${rc}, reached PHASE=${PHASE}); rolling back..." >&2
  if [ "$PHASE" -ge 3 ]; then
    echo "   Stopping rollup-boost and restoring FLASHBLOCKS_MODE=off in .envrc" >&2
    stop_rollup_boost
    set_envrc_mode off
  fi
  if [ "$PHASE" -ge 2 ]; then
    echo "   Restoring block production with admin_startSequencer" >&2
    [ -n "$STOP_HASH" ] && cast rpc admin_startSequencer "$STOP_HASH" --rpc-url "$OPNODE_RPC" >/dev/null 2>&1
  fi
  echo "   Stopping synchronization processes (op-rbuilder + builder op-node)" >&2
  cleanup_sync_nodes
  echo "!! Rollback complete; the chain is back in off mode. Confirm block production has resumed before rerunning this script." >&2
}
trap on_exit EXIT
trap 'echo "" >&2; echo "!! Received interrupt signal (Ctrl-C / SIGTERM)" >&2; exit 130' INT TERM

echo "============================================"
echo "  Surgical switch off → flashblocks dry_run ($CHAIN_ENV)"
echo "============================================"
echo "  op-geth      = $L2_RPC   (Engine :${OP_GETH_AUTHRPC_PORT:-8651})"
echo "  op-node      = $OPNODE_RPC (admin)"
echo "  op-rbuilder  = $RB_RPC"
echo "  rollup-boost = :${RB_ENGINE_PORT:-8551}"
echo "  lag/timeout  = ${LAG} / ${TIMEOUT}s"
echo ""

# ---------- [1] Preflight ----------
echo "[1] Preflight..."

# Idempotency guard: the chain may already be running in a dry_run/enabled topology,
# either after a previous successful switch or because chain-start.sh started the full
# stack with FLASHBLOCKS_MODE=dry_run. Switching again would only start a duplicate
# op-rbuilder and make the builder op-node compete with rollup-boost for Engine control.
if mode=$(curl -s --max-time 3 -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
      "http://localhost:${RB_DEBUG_PORT:-5555}" 2>/dev/null) && [ -n "$mode" ]; then
  cur=$(printf '%s' "$mode" | sed -n 's/.*"execution_mode":"\([a-z_]*\)".*/\1/p')
  echo "  Detected a running rollup-boost, execution_mode=${cur:-unknown}"
  echo "  This chain already uses the Flashblocks topology; no switch is needed."
  echo ""
  echo "  Confirm blocks: cast bn --rpc-url $L2_RPC ; cast bn --rpc-url $RB_RPC"
  echo "  Return to off: bash $CHAIN_OPS_DIR/chain-stop.sh, set FLASHBLOCKS_MODE=off in .envrc, then run chain-start.sh"
  if [ "${cur:-}" = "dry_run" ]; then
    echo "  Switch to enabled: curl -s -X POST -H 'Content-Type: application/json' \\"
    echo "                   --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_setExecutionMode\",\"params\":[{\"execution_mode\":\"enabled\"}]}' \\"
    echo "                   http://localhost:${RB_DEBUG_PORT:-5555}"
  fi
  SWITCH_DONE=1   # Suppress EXIT rollback: nothing changed.
  exit 0
fi

[ "${FLASHBLOCKS_MODE:-off}" = "off" ] || echo "  WARN: current .envrc FLASHBLOCKS_MODE=${FLASHBLOCKS_MODE} (expected off)."
[ "$(get_bn "$L2_RPC")" -ge 0 ] || { echo "Error: op-geth is unreachable (${L2_RPC}). Confirm the off-mode chain is running." >&2; exit 1; }
if ! cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 && ! cast bn --rpc-url "$OPNODE_RPC" >/dev/null 2>&1; then
  echo "Error: op-node is unreachable (${OPNODE_RPC})." >&2; exit 1
fi
[ -x "$BASE_PATH/bin/op-rbuilder" ]  || { echo "Error: bin/op-rbuilder is missing. First run bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
[ -x "$BASE_PATH/bin/rollup-boost" ] || { echo "Error: bin/rollup-boost is missing. First run bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
[ -x "$BASE_PATH/bin/flashblocks-websocket-proxy" ] || { echo "Error: bin/flashblocks-websocket-proxy is missing. First run bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
[ -x "$BASE_PATH/bin/op-reth" ] || { echo "Error: bin/op-reth is missing. First run bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
if ! (exec 3<>"/dev/tcp/127.0.0.1/${SEQ_P2P_TCP_PORT:-9222}") 2>/dev/null; then
  echo "Error: primary op-node CL P2P port ${SEQ_P2P_TCP_PORT:-9222} is not listening; the builder op-node cannot receive unsafe gossip." >&2
  echo "       Restart the off-mode chain once to enable op-node P2P: bash $CHAIN_OPS_DIR/chain-stop.sh && bash $CHAIN_OPS_DIR/chain-start.sh $CHAIN_ENV" >&2
  exit 1
fi
exec 3>&- 2>/dev/null || true
check_opnode_restart_safe || exit 1
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
  echo "  WARN: ${SEQ_P2P_KEY} not found; builder op-node falls back to L1-only derivation (safe head only)."
fi
PHASE=1   # From here, unexpected exits must clean up synchronization processes (see on_exit).
nohup bash "$FB_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder.pid"
echo "  op-rbuilder started (pid $(cat "$PID_DIR/op-rbuilder.pid"))"
sleep 3
nohup bash "$FB_DIR/run-op-rbuilder-opnode.sh" >> "$LOG_DIR/op-rbuilder-opnode.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder-opnode.pid"
echo "  builder op-node started (pid $(cat "$PID_DIR/op-rbuilder-opnode.pid"))"
echo ""

# ---------- [3] Approximate catch-up ----------
echo "[3] Waiting for op-rbuilder to catch up approximately to op-geth (|Δ| <= ${LAG}, <= ${TIMEOUT}s)..."
caught=0
for i in $(seq 1 "$TIMEOUT"); do
  g=$(get_bn "$L2_RPC"); r=$(get_bn "$RB_RPC")
  if [ "$r" -ge 0 ] && [ "$g" -ge 0 ] && [ "$r" -gt 0 ]; then
    d=$(( g - r )); [ "$d" -lt 0 ] && d=$(( -d ))
    { [ $(( i % 5 )) -eq 0 ] || [ "$d" -le "$LAG" ]; } && echo "  op-geth=$g op-rbuilder=$r Δ=$d"
    [ "$d" -le "$LAG" ] && { caught=1; break; }
  else
    [ $(( i % 5 )) -eq 0 ] && echo "  Waiting for op-rbuilder RPC... (op-rbuilder=$r)"
  fi
  sleep 1
done
if [ "$caught" != 1 ]; then
  echo "Error: approximate catch-up failed within ${TIMEOUT}s (op-rbuilder failed to start or synchronization stalled; inspect $LOG_DIR/op-rbuilder.log)." >&2
  exit 1
fi
echo "  Approximate catch-up OK."
echo ""

# ---------- [4] Freeze height ----------
echo "[4] Freezing primary op-node block production with admin_stopSequencer..."
STOP_HASH=$(cast rpc admin_stopSequencer --rpc-url "$OPNODE_RPC" 2>/dev/null | tr -d '"')
if [ -z "$STOP_HASH" ]; then
  echo "Error: admin_stopSequencer failed (op-node admin API is disabled or this is not a sequencer)." >&2
  exit 1
fi
PHASE=2   # Block production is frozen; unexpected exits must restore it with admin_startSequencer.
echo "  Paused at head hash=$STOP_HASH"
echo ""

# ---------- [5] Exact catch-up to H ----------
H=$(get_bn "$L2_RPC")
echo "[5] Waiting for op-rbuilder to reach frozen height H=${H} exactly (<= 120s)..."
exact=0
for i in $(seq 1 120); do
  r=$(get_bn "$RB_RPC")
  [ "$r" -ge "$H" ] && { exact=1; echo "  op-rbuilder=$r >= H=${H}; ready."; break; }
  [ $(( i % 5 )) -eq 0 ] && echo "  op-rbuilder=$r / H=$H"
  sleep 1
done
if [ "$exact" != 1 ]; then
  echo "Error: op-rbuilder did not reach frozen height H=${H} within 120s." >&2
  exit 1
fi
echo ""

# ---------- [6] Stop builder op-node (release the op-rbuilder Engine) ----------
echo "[6] Stopping builder op-node (releasing op-rbuilder Engine control)..."
stop_builder_opnode
sleep 2
echo ""

# ---------- [7] Write dry_run to .envrc ----------
echo "[7] Writing FLASHBLOCKS_MODE=dry_run to .envrc"
PHASE=3   # From here, unexpected exits must also stop rollup-boost and restore off in .envrc.
set_envrc_mode dry_run
export FLASHBLOCKS_MODE=dry_run
echo "  done"
echo ""

# ---------- [8] Start rollup-boost (take control of op-rbuilder) ----------
echo "[8] Starting rollup-boost (dry-run)..."
export _CALLER_OP_GETH_DATA_PATH="$DATA_DIR/op-geth"
export _CALLER_JWT_FILE="$DATA_DIR/op-geth/jwt.txt"
nohup bash "$FB_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
echo $! > "$PID_DIR/rollup-boost.pid"
echo "  rollup-boost started (pid $(cat "$PID_DIR/rollup-boost.pid"))"
sleep 3
if ! curl -s -m 3 -X POST -H 'Content-Type: application/json' \
     --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
     "http://localhost:${RB_DEBUG_PORT:-5555}" >/dev/null 2>&1; then
  echo "Error: rollup-boost debug port ${RB_DEBUG_PORT:-5555} is unresponsive after startup and may have crashed. Inspect $LOG_DIR/rollup-boost.log" >&2
  exit 1
fi
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

# ---------- [10] Start user-facing shadow topology ----------
echo "[10] Starting ws-proxy, op-reth, and verifier op-node..."
# dry_run exposes builder previews for testing only. Do not route production user traffic
# to op-reth until rollup-boost has switched to enabled.
source "$FB_DIR/start-user-side.sh"
# The topology switch is complete and only verification remains. Rolling back now would
# unnecessarily undo a successful switch.
SWITCH_DONE=1
echo ""

# ---------- [11] Verify ----------
echo "[11] Verifying block production progress..."
b0=$(get_bn "$L2_RPC"); ok=0
for i in $(seq 1 30); do
  sleep 2; b1=$(get_bn "$L2_RPC")
  [ "$b1" -gt "$b0" ] && { ok=1; echo "  Block production advanced $b0 → ${b1}; switch succeeded."; break; }
done
[ "$ok" = 1 ] || echo "  WARN: no block progress after 30 attempts; inspect $LOG_DIR/op-node.log and rollup-boost.log. If op-node did not resume automatically, run cast rpc admin_startSequencer <hash> --rpc-url $OPNODE_RPC"
echo ""
echo "=== Complete: switched to dry_run ==="
echo "  Verify builder payloads: tail -f $LOG_DIR/rollup-boost.log (all should be VALID)"
echo "  User-facing shadow RPC: http://localhost:${FB_RPC_HTTP_PORT:-8745} (do not expose publicly in dry_run)"
echo "  Switch live to enabled: bash $FB_DIR/switch-dryrun-to-flashblocks-enabled.sh"
