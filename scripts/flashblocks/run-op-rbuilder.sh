#!/bin/bash
#
# Component-only launcher for op-rbuilder (a reth-based Flashblocks builder).
# This file is the single source of truth for this component's flags.
# It uses the same genesis as op-geth and requires no separate builder op-node:
# rollup-boost forwards Engine calls from the primary op-node to drive block production.
# Orchestrated by chain-start.sh; it can also run independently for debugging.
#
# Confirm flag names against `bin/op-rbuilder node --help` (v0.2.13) before deployment.
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# Share genesis.json with op-geth (forks are embedded by activate-fork.sh at activation).
CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GENESIS_FILE="${_CALLER_OP_GETH_GENESIS_FILE:-$CFG/genesis.json}"
DATADIR="$BASE_PATH/data/op-rbuilder"
mkdir -p "$DATADIR"

# Flashblock slices per block = chain-block-time / flashblocks.block-time
# (see flashblocks_per_block in
# op-rbuilder/crates/op-rbuilder/src/builders/flashblocks/config.rs).
# --rollup.chain-block-time defaults to only 1000 ms. If omitted, slicing covers one
# second: with L2_BLOCK_TIME=2, this yields only four slices, each with a gas budget of
# block_gas_limit / slice_count. That allocates the entire block's gas during the first
# second, so transactions arriving in the latter half cannot enter any Flashblock.
# Therefore, it must match L2_BLOCK_TIME.
FB_INTERVAL_MS="${FB_INTERVAL_MS:-250}"
CHAIN_BLOCK_TIME_MS=$(( ${L2_BLOCK_TIME:-2} * 1000 ))
if [ $(( CHAIN_BLOCK_TIME_MS % FB_INTERVAL_MS )) -ne 0 ]; then
  echo "WARN: L2_BLOCK_TIME (${CHAIN_BLOCK_TIME_MS}ms) is not an exact multiple of the Flashblock interval (${FB_INTERVAL_MS}ms);" \
       "$(( CHAIN_BLOCK_TIME_MS / FB_INTERVAL_MS )) slices per block after integer division will not cover the full block window." >&2
fi

# Match mainnet P2P behavior: enable discovery and persist peers (do not add
# --disable-discovery or --no-persist-peers). --port is customized only to avoid a
# local conflict with op-geth's default port 30303; it does not change P2P semantics.
#
# --color never: reth-based components default to always and do not detect TTYs, so they
# write ANSI escapes even when stdout is redirected. Logs then contain ESC[ sequences,
# render poorly in editors, and require stripping colors before rg can match. This flag
# affects only color, not log content. rollup-boost and websocket-proxy already use
# with_ansi(false) internally and do not need it.
exec op-rbuilder node \
  --chain "$GENESIS_FILE" \
  --datadir "$DATADIR" \
  --color never \
  --authrpc.addr 0.0.0.0 --authrpc.port "$RBUILDER_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$RBUILDER_HTTP_PORT" --http.api eth,web3,net,debug,txpool \
  --ws --ws.addr 0.0.0.0 --ws.port "$RBUILDER_WS_PORT" \
  --port "${RBUILDER_P2P_PORT:-30313}" \
  --rollup.chain-block-time "$CHAIN_BLOCK_TIME_MS" \
  --flashblocks.enabled --flashblocks.addr 0.0.0.0 --flashblocks.port "$RBUILDER_FB_WS_PORT" \
  --flashblocks.block-time "$FB_INTERVAL_MS"
