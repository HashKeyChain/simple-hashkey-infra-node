#!/bin/bash
#
# Deploy a chain and advance it to a specified fork in one command (Jovian by default).
#
# Background: support for deploying directly at the Jovian fork has not been developed, so a Jovian genesis
# cannot be generated directly. The only viable path is the runbook's time-based activation flow:
#   deploy a Fjord baseline -> start the chain -> schedule future activation times for Granite through Jovian ->
#   stop the chain / synchronize rollup.json / restart (op-geth assembles --override.* at runtime) ->
#   after wall-clock activation times arrive, advance through successive hardforks over several blocks
#   until the target fork. This script condenses that flow into one command, making it easy to repeatedly build
#   a chain at the same fork as mainnet/testnet for Flashblocks integration.
#
# .envrc FORK_*_TIME remains the sole source of truth for fork times. This script calculates them from the current
# L2 time, writes them back to .envrc, and reuses chain-setup / chain-start / activate-fork without introducing
# another source of truth.
#
# Usage:
#   bash scripts/deploy-chain/deploy-jovian-chain.sh [local|remote] [options]
#
# Options:
#   --reset          Run chain-reset first (stop the chain + delete data/ + delete config/<ctx>/ + clear the CGT address)
#                    to deploy a fresh chain. Redeploying over an existing chain requires --reset or the script refuses.
#   --pace=SEC       Seconds between adjacent fork activations (default: 2).
#   --lead=SEC       Lead time from the current L2 time to the first pending fork (default: 30; must exceed restart time).
#   --target=FORK    Final fork to activate: granite | holocene | isthmus | jovian (default: jovian).
#   -y, --yes        Pass to chain-reset to skip its irreversible-action confirmation.
#
# If env is omitted, detect it from L1_RPC_URL (localhost/127.0.0.1 is treated as local).
#
# On completion, the chain has activated <target>. The script waits and verifies activation,
# with an additional GasPriceOracle check for Jovian/Isthmus.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

CHAIN_OPS_DIR="$BASE_PATH/scripts/chain-ops"
GAS_PRICE_ORACLE="0x420000000000000000000000000000000000000F"
ALL_FORKS=(granite holocene isthmus jovian)

usage() {
  echo "Usage: bash scripts/deploy-chain/deploy-jovian-chain.sh [local|remote] [--reset] [--pace=SEC] [--lead=SEC] [--target=granite|holocene|isthmus|jovian] [-y|--yes]" >&2
}

# ---------- Parse arguments ----------
CHAIN_ENV=""
DO_RESET=0
ASSUME_YES=0
PACE=2
LEAD=30
TARGET=jovian
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --reset)      DO_RESET=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --pace=*)     PACE="${arg#*=}" ;;
    --lead=*)     LEAD="${arg#*=}" ;;
    --target=*)   TARGET="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2; usage; exit 1 ;;
  esac
done

# Numeric validation (compatible with Bash 3.2; do not use ${v,,})
case "$PACE" in ''|*[!0-9]*) echo "Error: --pace must be a nonnegative integer; received '$PACE'" >&2; exit 1 ;; esac
case "$LEAD" in ''|*[!0-9]*) echo "Error: --lead must be a nonnegative integer; received '$LEAD'" >&2; exit 1 ;; esac

# Validate target
TARGET_IDX=-1
for i in "${!ALL_FORKS[@]}"; do
  [ "${ALL_FORKS[$i]}" = "$TARGET" ] && TARGET_IDX=$i
done
if [ "$TARGET_IDX" -lt 0 ]; then
  echo "Error: invalid --target: ${TARGET} (valid values: ${ALL_FORKS[*]})" >&2
  exit 1
fi

# ---------- Resolve the runtime environment ----------
if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi
if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  usage; exit 1
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

# L2 RPC (op-geth HTTP port is 8645 in both local and remote modes)
L2_RPC="${L2_RPC_URL:-http://localhost:8645}"

echo "============================================"
echo "  Deploy chain → activate up to '$TARGET'"
echo "============================================"
echo "  CHAIN_ENV = $CHAIN_ENV"
echo "  reset     = $([ "$DO_RESET" = 1 ] && echo yes || echo no)"
echo "  pace      = ${PACE}s (interval between adjacent forks)"
echo "  lead      = ${LEAD}s (lead time for the first fork)"
echo "  target    = $TARGET"
echo "  L2 RPC    = $L2_RPC"
echo ""

# ---------- Helper for writing fork times to .envrc ----------
# Usage: set_fork_times "0" "" "" "" ""  # Fjord, Granite, Holocene, Isthmus, Jovian; empty string clears the value
set_fork_times() {
  _FJORD="$1" _GRANITE="$2" _HOLOCENE="$3" _ISTHMUS="$4" _JOVIAN="$5" \
  python3 - <<'PY'
import os, re
from pathlib import Path

vals = {
    "FJORD":    os.environ["_FJORD"],
    "GRANITE":  os.environ["_GRANITE"],
    "HOLOCENE": os.environ["_HOLOCENE"],
    "ISTHMUS":  os.environ["_ISTHMUS"],
    "JOVIAN":   os.environ["_JOVIAN"],
}
path = Path(".envrc")
text = path.read_text()
for name, v in vals.items():
    pat = re.compile(rf'^export FORK_{name}_TIME=.*$', re.M)
    repl = f'export FORK_{name}_TIME={v}'
    if pat.search(text):
        text = pat.sub(repl, text)
    else:
        text = text.rstrip("\n") + "\n" + repl + "\n"
path.write_text(text)
PY
}

# ---------- [1/7] Optional reset ----------
DATA_DIR="$BASE_PATH/data"
CONFIG_DIR="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
if [ "$DO_RESET" = "1" ]; then
  echo "[1/7] Resetting old chain state..."
  reset_args=("$CHAIN_ENV")
  [ "$ASSUME_YES" = "1" ] && reset_args+=(--yes)
  bash "$SCRIPT_DIR/chain-reset.sh" "${reset_args[@]}"
else
  echo "[1/7] Skipping reset (--reset was not provided)"
  if [ -d "$DATA_DIR" ] || [ -d "$CONFIG_DIR" ]; then
    echo "Error: existing chain state detected:" >&2
    [ -d "$DATA_DIR" ]   && echo "         $DATA_DIR" >&2
    [ -d "$CONFIG_DIR" ] && echo "         $CONFIG_DIR" >&2
    echo "       Add --reset to deploy a fresh chain (this clears the directories above)." >&2
    exit 1
  fi
fi
echo ""

# ---------- [2/7] Reset fork times to guarantee deployment from a pure-Fjord baseline ----------
# Set Fjord=0 (active at genesis) and clear Granite through Jovian so later forks are not written to rollup.json during deployment.
echo "[2/7] Configuring .envrc: fjord=0; granite..jovian cleared (pure-Fjord baseline)"
set_fork_times "0" "" "" "" ""
echo ""

# ---------- [3/7] Deploy contracts and generate configuration ----------
echo "[3/7] Deploying contracts and generating genesis/rollup (chain-setup)..."
bash "$SCRIPT_DIR/chain-setup.sh" "$CHAIN_ENV"
echo ""

# ---------- [4/7] Start the chain (pure Fjord) ----------
echo "[4/7] Starting L2 (pure Fjord, chain-start)..."
bash "$CHAIN_OPS_DIR/chain-start.sh" "$CHAIN_ENV"
echo ""

# ---------- [5/7] Wait for L2 blocks and read the current L2 time ----------
echo "[5/7] Waiting for L2 blocks..."
L2_TS=""
for i in $(seq 1 60); do
  raw=$(cast block latest --rpc-url "$L2_RPC" --json 2>/dev/null | jq -r '.timestamp' 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    L2_TS=$(( raw ))   # Supports hexadecimal (0x...) and decimal values
    if [ "$L2_TS" -gt 0 ]; then break; fi
  fi
  sleep 1
done
if [ -z "$L2_TS" ] || [ "$L2_TS" -le 0 ]; then
  echo "Error: failed to read a valid L2 block timestamp from $L2_RPC within 60s; L2 may not have started correctly." >&2
  echo "       Check data/logs/op-geth.log and data/logs/op-node.log" >&2
  exit 1
fi
echo "  Current L2 timestamp: $L2_TS"

# Calculate fork activation times: base = L2_now + lead; add pace for each fork from Granite through target;
# leave forks after target empty. Bash 3.2 has no associative arrays, so use flat FT_<fork> variables and eval.
BASE=$(( L2_TS + LEAD ))
FT_granite=""; FT_holocene=""; FT_isthmus=""; FT_jovian=""
t=$BASE
idx=0
for fork in "${ALL_FORKS[@]}"; do
  if [ "$idx" -le "$TARGET_IDX" ]; then
    eval "FT_${fork}=$t"
    t=$(( t + PACE ))
  fi
  idx=$(( idx + 1 ))
done
echo "  Planned fork times (fjord=0, active at genesis):"
printf '    %-9s %s\n' granite  "${FT_granite:-<inactive>}"
printf '    %-9s %s\n' holocene "${FT_holocene:-<inactive>}"
printf '    %-9s %s\n' isthmus  "${FT_isthmus:-<inactive>}"
printf '    %-9s %s\n' jovian   "${FT_jovian:-<inactive>}"
echo ""

# ---------- [6/7] Write back to .envrc and activate forks (stop chain -> sync rollup -> restart) ----------
echo "[6/7] Writing back to .envrc and running activate-fork..."
set_fork_times "0" "$FT_granite" "$FT_holocene" "$FT_isthmus" "$FT_jovian"
bash "$SCRIPT_DIR/activate-fork.sh" "$CHAIN_ENV"
echo ""

# ---------- [7/7] Wait for and verify target-fork activation ----------
eval "TARGET_TIME=\$FT_${TARGET}"
# Timeout budget: lead time + all fork intervals + restart/derivation buffer.
TIMEOUT=$(( LEAD + PACE * ${#ALL_FORKS[@]} + 150 ))
echo "[7/7] Waiting up to ${TIMEOUT}s for wall-clock time to reach the $TARGET activation time ($TARGET_TIME) and produce a block..."
reached=0
for i in $(seq 1 "$TIMEOUT"); do
  raw=$(cast block latest --rpc-url "$L2_RPC" --json 2>/dev/null | jq -r '.timestamp' 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    cur=$(( raw ))
    if [ "$cur" -ge "$TARGET_TIME" ]; then reached=1; break; fi
  fi
  sleep 1
done

if [ "$reached" != "1" ]; then
  echo "WARN: timed out before observing L2 time pass the $TARGET activation point. Check data/logs/op-node.log." >&2
else
  echo "  L2 time has passed the $TARGET activation point."
fi

# Assert GasPriceOracle for queryable forks. Skip Granite/Holocene because the predeploy has no corresponding is* methods.
verify_oracle() {  # $1=method name, such as isJovian
  local method="$1" out
  out=$(cast call "$GAS_PRICE_ORACLE" "${method}()(bool)" --rpc-url "$L2_RPC" 2>/dev/null || echo "")
  echo "$out"
}
case "$TARGET" in
  jovian)  m=isJovian  ;;
  isthmus) m=isIsthmus ;;
  *)       m="" ;;
esac
if [ -n "$m" ]; then
  val=$(verify_oracle "$m")
  echo "  GasPriceOracle.${m}() = ${val:-<query failed>}"
  if [ "$val" != "true" ]; then
    echo "  WARN: ${m}() is not true yet; wait another block or two, or verify that the fork activated correctly." >&2
  fi
fi

echo ""
echo "=== Complete ==="
echo "  Chain advanced to the planned fork: $TARGET"
echo "  Fork-time source of truth: .envrc FORK_*_TIME (written by this script)"
echo "  L2 RPC:     $L2_RPC"
echo "  Rollup RPC: ${OP_NODE_RPC_URL:-http://localhost:9545}"
echo "  Logs:       data/logs/*.log"
echo ""
echo "Verify the fork flag:"
echo "  cast call $GAS_PRICE_ORACLE \"isJovian()(bool)\" --rpc-url $L2_RPC"
