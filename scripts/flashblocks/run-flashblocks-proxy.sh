#!/bin/bash
#
# 纯组件启动器：flashblocks-websocket-proxy —— 订阅 rollup-boost 的 flashblocks 广播，
# 对用户侧扇出（生产同构，本地不省略）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试。
#
# flag 名以 `bin/flashblocks-websocket-proxy --help`（rollup-boost v0.7.11 同 submodule）为准，落地时先校准。
#
source .envrc

exec flashblocks-websocket-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
