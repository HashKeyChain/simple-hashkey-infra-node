#!/bin/bash
#
# Component-only launcher: starts op-geth with the correct flags (the single source of truth for this component's flags).
# Orchestrated by chain-start.sh; it can also be run independently for debugging or restarts.
#
# Prerequisites for standalone use: chain-setup has generated the configuration, the datadir has been initialized
# with op-geth init, and the JWT has been generated.
# Note: chain-start.sh initializes the datadir idempotently; this script no longer runs op-geth init.
#

source .envrc

# Allow the chain-start orchestration layer to override values via _CALLER_*; fall back to .envrc/defaults when run independently.
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

# Hardfork times are baked into genesis.json by activate-fork.sh from .envrc FORK_*_TIME values.
# Geth reads forks from genesis instead of using --override.*; reth has no overrides, so both remain consistent
# by sharing the same genesis.
flags="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=${OP_GETH_HTTP_PORT:-8645} --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=${OP_GETH_WS_PORT:-8646} --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=${OP_GETH_AUTHRPC_PORT:-8651} --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash"

echo "Starting op-geth ..."
echo "op-geth $flags"

exec op-geth $flags
