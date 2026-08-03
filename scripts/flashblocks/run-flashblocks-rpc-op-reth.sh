#!/bin/bash
#
# Component-only launcher for op-reth (a Flashblocks-aware RPC). It subscribes to
# Flashblocks from ws-proxy and exposes pending/preconfirmation data. The verifier
# op-node from run-flashblocks-rpc-op-node.sh drives canonical-chain synchronization
# through the Engine API. It uses the same genesis as op-geth. Orchestrated by
# chain-start.sh; it can also run independently for debugging.
#
# Note: this runs the op-reth binary (reth v1.9.3, with built-in Flashblocks RPC), not
# the standalone `flashblocks-rpc` binary of the same name in rollup-boost.
#
# Local connections use ws:// throughout (not wss://; no TLS).
# Confirm flag names against `bin/op-reth node --help` (reth v1.9.3) before deployment,
# especially --flashblocks-url.
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# Share genesis.json with op-geth (forks are embedded by activate-fork.sh at activation).
CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GENESIS_FILE="${_CALLER_OP_GETH_GENESIS_FILE:-$CFG/genesis.json}"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

# Match mainnet P2P behavior: enable discovery and persist peers (do not add
# --disable-discovery or --no-persist-peers). All three ports are customized only to
# avoid local conflicts with op-geth/op-rbuilder; P2P semantics are unchanged.
# --port controls only RLPx TCP. The two discovery protocols have separate UDP ports
# (defaults: discv4 30303, discv5 9200). If they are not moved together, op-reth exits
# with AddrInUse after op-rbuilder starts first.
#
# Transaction forwarding target = rollup-boost (not op-geth). rollup-boost's ProxyLayer
# fans eth_sendRawTransaction out to both op-geth (canonical) and op-rbuilder (builder),
# keeping the builder and canonical transaction pools synchronized so Flashblocks are
# non-empty (see FORWARD_REQUESTS in rollup-boost proxy.rs). Pointing this at op-geth
# instead still works as an RPC, but the builder never sees the transaction directly and
# preconfirmations for it are no longer timely. The inbound --rpc-port has no JWT, so
# plain HTTP forwarding is sufficient.
#
# --color never: as in run-op-rbuilder.sh, reth-based components otherwise write ANSI
# escape sequences into log files by default.
RB_RPC_URL="${RB_RPC_URL:-http://localhost:${RB_ENGINE_PORT:-8551}}"
exec op-reth node \
  --chain "$GENESIS_FILE" --datadir "$DATADIR" \
  --color never \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" --http.api eth,web3,net,debug \
  --port "${FB_RPC_P2P_PORT:-30323}" \
  --discovery.port "${FB_RPC_DISC_PORT:-30324}" \
  --discovery.v5.port "${FB_RPC_DISC_V5_PORT:-9201}" \
  --rollup.sequencer-http "$RB_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
