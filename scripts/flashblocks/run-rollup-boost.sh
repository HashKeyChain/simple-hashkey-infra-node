#!/bin/bash
#
# Component-only launcher for rollup-boost: the Engine API proxy between op-node and
# (op-geth fallback + op-rbuilder builder), which also broadcasts Flashblocks externally.
# Includes the debug server for live execution-mode switching.
# Orchestrated by chain-start.sh; it can also run independently for debugging.
#
# FLASHBLOCKS_MODE only sets the initial mode: dry_run -> dry-run (validate builder
# payloads without using them), enabled -> enabled (use builder payloads). This component
# is not started in off mode (see chain-start.sh).
# Switch modes at runtime through the debug server's JSON-RPC API (v0.7.11 has no
# `debug set-execution-mode` subcommand):
#   curl -X POST -H 'Content-Type: application/json' \
#     --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
#     http://localhost:$RB_DEBUG_PORT
# Use debug_getExecutionMode to query the current mode. Live switching does not require
# restarting op-node.
#
# Flags have been verified against `bin/rollup-boost --help` (v0.7.11):
#   - The inbound Engine server uses --rpc-host/--rpc-port (there is no separate
#     --jwt-path; it shares jwt.txt with l2/builder).
#   - Upstreams use --l2-url/--builder-url and require a scheme (http://host:port).
#     v0.7.11 parses them as url::Url at runtime and crashes with
#     `Invalid URL: relative URL without a base` if the scheme is absent, even though
#     --help shows a host:port default.
#   - The broadcast endpoint uses --flashblocks-host/--flashblocks-port; the builder
#     input uses --flashblocks-builder-url (ws://).
#   - Execution modes are enabled / dry-run / disabled (default: enabled).
#   - --metrics enables Prometheus (disabled by default), exposing
#     block_building_gas_delta / block_building_tx_count_delta (distributions of
#     builder deltas relative to op-geth),
#     rpc_blocks_created{source=l2|builder}, and rollup_boost_execution_mode.
#     Note that it does not compare block hashes or count invalid blocks; both must be
#     derived from logs (see scripts/flashblocks/verify/p2-dryrun.sh).
#
source .envrc

OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

EXEC_MODE_FLAG=""
[ "$FLASHBLOCKS_MODE" = "dry_run" ] && EXEC_MODE_FLAG="--execution-mode=dry-run"
[ "$FLASHBLOCKS_MODE" = "enabled" ] && EXEC_MODE_FLAG="--execution-mode=enabled"

exec rollup-boost \
  --rpc-host 0.0.0.0 --rpc-port "$RB_ENGINE_PORT" \
  --l2-url  http://127.0.0.1:"${OP_GETH_AUTHRPC_PORT:-8651}" \
  --l2-jwt-path "$JWT_FILE" \
  --builder-url http://127.0.0.1:"$RBUILDER_AUTHRPC_PORT" \
  --builder-jwt-path "$JWT_FILE" \
  --flashblocks --flashblocks-builder-url ws://127.0.0.1:"$RBUILDER_FB_WS_PORT" \
  --flashblocks-host 0.0.0.0 --flashblocks-port "$RB_FLASHBLOCKS_WS_PORT" \
  --debug-server-port "$RB_DEBUG_PORT" \
  --metrics --metrics-host 127.0.0.1 --metrics-port "${RB_METRICS_PORT:-9090}" \
  $EXEC_MODE_FLAG
