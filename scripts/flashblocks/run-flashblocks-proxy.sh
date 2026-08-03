#!/bin/bash
#
# Component-only launcher for flashblocks-websocket-proxy. It subscribes to the
# rollup-boost Flashblocks broadcast and fans it out to user-facing consumers
# (matching production topology; not omitted locally).
# Orchestrated by chain-start.sh; it can also run independently for debugging.
#
# Confirm flag names against `bin/flashblocks-websocket-proxy --help`
# (the same rollup-boost v0.7.11 submodule) before deployment.
#
source .envrc

exec flashblocks-websocket-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
