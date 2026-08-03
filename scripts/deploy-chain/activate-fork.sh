#!/bin/bash
#
# Activate a new fork by advancing hardforks on a running chain.
#
# Background: initial chain setup starts from Fjord only because the deployment tool produces a pure-Fjord baseline.
# Other FORK_*_TIME values remain empty in .envrc. To activate a new fork, .envrc FORK_*_TIME remains the single
# source of truth. This script is the only place that writes those values into configuration, then restarts the chain:
#   - *_time in rollup.json (read by op-node)             <- [2/4] sync_fork in this script
#   - config.*Time in genesis.json (shared by geth/reth)  <- [2/4] bake-genesis-forks.sh invoked by this script
#   - [3/4] then reruns geth init to update only the fork schedule while preserving chain data.
#
# Workflow:
#   1. Edit .envrc and set FORK_*_TIME for each fork to activate to its target Unix timestamp.
#      A future time such as now+60 is recommended so pre-to-post transition blocks can be observed.
#      Use 0 to activate at genesis (meaningful only for a new chain); leave empty to keep a fork inactive.
#   2. Run this script. It automatically stops L2 -> synchronizes rollup.json -> restarts L2
#      (chain-start bakes genesis and reruns geth init).
#      Note: this script neither restarts anvil nor deletes the op-geth datadir. geth init only updates the fork
#      schedule, so the chain continues from its current height and activates the fork at the target time.
#
# Usage:
#   bash scripts/activate-fork.sh [local|remote]
#
# If omitted, the environment is detected automatically from L1_RPC_URL (localhost/127.0.0.1 is treated as local).
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

# ---------- Resolve the runtime environment: local | remote ----------
CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi
if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  echo "Usage: bash scripts/activate-fork.sh [local|remote]"
  exit 1
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

ROLLUP_FILE="$BASE_PATH/config/$DEPLOYMENT_CONTEXT/rollup.json"
if [ ! -f "$ROLLUP_FILE" ]; then
  echo "Error: rollup.json does not exist: $ROLLUP_FILE" >&2
  echo "       Run bash scripts/chain-setup.sh $CHAIN_ENV first to generate the configuration." >&2
  exit 1
fi

# ---------- Print the fork configuration to apply (source: .envrc FORK_*_TIME) ----------
echo "============================================"
echo "  Activate fork ($CHAIN_ENV)"
echo "============================================"
echo "Fork times (source: .envrc FORK_*_TIME; empty=inactive):"
printf '  %-9s %s\n' fjord    "${FORK_FJORD_TIME:-<unset>}"
printf '  %-9s %s\n' granite  "${FORK_GRANITE_TIME:-<unset>}"
printf '  %-9s %s\n' holocene "${FORK_HOLOCENE_TIME:-<unset>}"
printf '  %-9s %s\n' isthmus  "${FORK_ISTHMUS_TIME:-<unset>}"
printf '  %-9s %s\n' jovian   "${FORK_JOVIAN_TIME:-<unset>}"
echo ""

# ---------- Soft validation: monotonic order and past timestamps ----------
# Warn without blocking: fork times should increase in the order
# fjord<=granite<=holocene<=isthmus<=jovian. If a target time is earlier than the current L1 time,
# the fork activates immediately in the next block after restart, so no transition block can be observed.
NOW=$(cast block latest --rpc-url "$L1_RPC_URL" -j 2>/dev/null | jq -r '.timestamp' 2>/dev/null | xargs printf '%d\n' 2>/dev/null || echo "")
prev=""
for pair in "fjord:${FORK_FJORD_TIME:-}" "granite:${FORK_GRANITE_TIME:-}" \
            "holocene:${FORK_HOLOCENE_TIME:-}" "isthmus:${FORK_ISTHMUS_TIME:-}" \
            "jovian:${FORK_JOVIAN_TIME:-}"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [ -z "$val" ] && continue
  if [ -n "$prev" ] && [ "$val" -lt "$prev" ]; then
    echo "WARN: ${name}=${val} is earlier than the previous fork time ${prev}; fork times should increase monotonically."
  fi
  prev="$val"
  if [ -n "$NOW" ] && [ "$val" != "0" ] && [ "$val" -lt "$NOW" ]; then
    echo "WARN: ${name}=${val} is earlier than the current L1 time ${NOW}; it will activate immediately after restart with no transition block."
  fi
done
echo ""

# ---------- [1/4] Stop L2 (preserve anvil and the op-geth datadir) ----------
echo "[1/4] Stopping L2 components..."
bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh"
echo ""

# ---------- [2/4] Synchronize fork times to rollup.json + genesis.json (the sole fork-scheduling entry point) ----------
# The single source of truth for fork times is .envrc FORK_*_TIME. This script is the only place that writes them
# into configuration:
#   - *_time in rollup.json (read by op-node)
#   - config.*Time in genesis.json (shared by op-geth/reth; invokes bake-genesis-forks.sh)
# Both are updated together in one operation from the same source, preventing drift. Nonempty variables are written;
# empty variables set rollup values to null and delete genesis keys. patch-rollup-config.sh already applied the
# idempotent runtime compatibility fixes (genesis.l1.hash/da_challenge/chain_op_config) during setup, so do not repeat them.
echo "[2/4] Synchronizing fork times to rollup.json + genesis.json (source: .envrc FORK_*_TIME)..."
TMP_FILE="$ROLLUP_FILE.tmp"
sync_fork() {  # $1=fork name in rollup.json; $2=corresponding FORK_*_TIME value
  local key="$1" val="$2"
  if [ -n "$val" ]; then
    jq --argjson t "$val" ".${key}_time = \$t" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  else
    jq ".${key}_time = null" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  fi
  echo "    ${key}_time = ${val:-null}"
}
sync_fork fjord    "${FORK_FJORD_TIME:-}"
sync_fork granite  "${FORK_GRANITE_TIME:-}"
sync_fork holocene "${FORK_HOLOCENE_TIME:-}"
sync_fork isthmus  "${FORK_ISTHMUS_TIME:-}"
sync_fork jovian   "${FORK_JOVIAN_TIME:-}"
echo "  Synchronizing the fork schedule to genesis.json (shared by geth/reth)..."
bash "$BASE_PATH/scripts/chain-ops/bake-genesis-forks.sh"
echo ""

# ---------- [3/4] Re-init op-geth on the existing chain (update only the fork schedule; preserve chain data) ----------
# [2/4] has synchronized the genesis fork schedule: sync_fork wrote rollup and bake-genesis-forks.sh baked genesis.
# Only rerun geth init on the existing op-geth datadir. geth init is nondestructive for a database with a matching
# genesis hash: it writes only the fork schedule back to the database and preserves all block data. Adding future,
# unreached forks is compatible; attempting to move an already-past fork forward is blocked by geth with a mismatch error.
# The reth family shares the same genesis with geth and requires no separate handling.
echo "[3/4] Re-initializing op-geth (preserving chain data and updating only the fork schedule)..."
OP_GETH_DATA_PATH="$BASE_PATH/data/op-geth"
GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
if [ -d "$OP_GETH_DATA_PATH/geth" ]; then
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$GENESIS_FILE"
else
  echo "  The op-geth datadir is not initialized; skipping re-init (chain-start will perform the initial init)."
fi
echo ""

# ---------- [4/4] Restart L2 (geth reads the updated schedule from genesis; chain-start does not re-init) ----------
echo "[4/4] Restarting L2..."
bash "$BASE_PATH/scripts/chain-ops/chain-start.sh" "$CHAIN_ENV"

echo ""
echo "=== Fork activation complete ==="
echo "Verification: observe L2 block behavior after the fork time; see *_time in rollup.json at $ROLLUP_FILE"
