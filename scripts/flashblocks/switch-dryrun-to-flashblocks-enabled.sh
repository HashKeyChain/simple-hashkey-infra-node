#!/bin/bash
#
# Switch a running Flashblocks stack from dry_run to enabled without restarting it.
# The dry_run topology already includes ws-proxy, op-reth, and verifier op-node.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"
source .envrc

RB_DEBUG="http://localhost:${RB_DEBUG_PORT:-5555}"

get_mode() {
  curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
    "$RB_DEBUG" | sed -n 's/.*"execution_mode":"\([a-z_]*\)".*/\1/p'
}

mode=$(get_mode)
if [ "$mode" = "enabled" ]; then
  echo "Flashblocks is already enabled."
  exit 0
fi
if [ "$mode" != "dry_run" ]; then
  echo "Error: expected dry_run mode, got ${mode:-unknown}." >&2
  exit 1
fi

curl -fsS --max-time 3 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
  "$RB_DEBUG" >/dev/null

mode=$(get_mode)
if [ "$mode" != "enabled" ]; then
  echo "Error: rollup-boost did not switch to enabled mode." >&2
  exit 1
fi

sed -i.bak \
  's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=enabled/' \
  .envrc
rm -f .envrc.bak

echo "Flashblocks switched live: dry_run → enabled"
echo "User RPC: http://localhost:${FB_RPC_HTTP_PORT:-8745}"
