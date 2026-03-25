#!/bin/bash
#
# One-click chain launcher: build components -> deploy contracts -> start services.
#
# Usage:
#   bash scripts/chain-up.sh [local|server]
#
# Steps:
#   1. Build op-geth / op-node / op-batcher / op-proposer (skip if binaries exist in bin/)
#   2. Run chain-setup if config not yet generated (deploy L1 contracts + generate genesis/rollup)
#   3. Run chain-start (start all services)
#
# Environment variables (optional):
#   SKIP_BUILD=1     - skip build step (use existing binaries in bin/)
#   FORCE_BUILD=1    - force rebuild all components
#   FORCE_SETUP=1    - force re-deploy contracts
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  source .envrc 2>/dev/null || true
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
fi

# ---------- Step 1: Build components ----------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "=== Step 1: Building components ==="
  bash "$SCRIPT_DIR/build-components.sh"
else
  echo "=== Step 1: Skipping build (SKIP_BUILD=1) ==="
fi

source .envrc 2>/dev/null || true
if [ "$CHAIN_ENV" = "local" ]; then
  CONFIG_DIR="$BASE_PATH/config/local"
else
  CONFIG_DIR="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/getting-started}"
fi

# ---------- Step 2: Detect if setup is needed ----------
NEED_SETUP=0
ENV_MARKER="$BASE_PATH/data/.last_chain_env"
CURRENT_ENV_SIG="${CHAIN_ENV}|${L1_RPC_URL:-}"

if [ ! -f "$CONFIG_DIR/rollup.json" ] || [ ! -f "$CONFIG_DIR/genesis.json" ]; then
  echo "Config files not found in $CONFIG_DIR, setup required."
  NEED_SETUP=1
elif [ -f "$ENV_MARKER" ]; then
  LAST_ENV_SIG=$(cat "$ENV_MARKER")
  if [ "$CURRENT_ENV_SIG" != "$LAST_ENV_SIG" ]; then
    echo "Environment changed: was [$LAST_ENV_SIG], now [$CURRENT_ENV_SIG]. Re-setup required."
    NEED_SETUP=1
  fi
else
  echo "No environment marker found, setup required."
  NEED_SETUP=1
fi
if [ "${FORCE_SETUP:-0}" = "1" ]; then
  echo "FORCE_SETUP=1, forcing re-setup."
  NEED_SETUP=1
fi

if [ "$NEED_SETUP" = "1" ]; then
  echo "Running chain-setup..."
  # Re-deploying L1 contracts requires clean op-geth data (genesis will change)
  export CLEAN_OP_GETH_DATADIR=1
  # Remove stale op-node safedb (incompatible with new chain)
  rm -rf "$BASE_PATH/data/op-node/safedb" 2>/dev/null || true
  # Stop old anvil in local mode (need a fresh L1 for re-deployment)
  if [ "$CHAIN_ENV" = "local" ]; then
    echo "Stopping old anvil..."
    if [ -f "$BASE_PATH/data/pids/anvil.pid" ]; then
      kill "$(cat "$BASE_PATH/data/pids/anvil.pid")" 2>/dev/null || true
      rm -f "$BASE_PATH/data/pids/anvil.pid"
    fi
    docker rm -f anvil-chain 2>/dev/null || true
    # Ensure port 8545 is free
    for pid in $(lsof -i :8545 -t 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  bash "$SCRIPT_DIR/chain-setup.sh" "$CHAIN_ENV"

  # Save environment marker so we can detect changes on next run
  mkdir -p "$BASE_PATH/data"
  echo "$CURRENT_ENV_SIG" > "$ENV_MARKER"
  echo "Saved environment marker: $CURRENT_ENV_SIG"
fi

echo ""
echo "Starting all services..."
bash "$SCRIPT_DIR/chain-start.sh" "$CHAIN_ENV"
