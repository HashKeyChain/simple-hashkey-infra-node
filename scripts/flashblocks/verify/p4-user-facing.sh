#!/bin/bash
#
# P4 verifies the user-facing Flashblocks RPC:
#   1. op-reth and the canonical RPC are reachable.
#   2. A submitted transaction appears in pending before it is sealed.
#   3. The pending observation happens in less than one second.
#
# P3 already verifies rollup-boost, op-rbuilder and the WebSocket stream. P4 intentionally
# does not repeat those checks.
#
# Usage:
#   bash scripts/flashblocks/verify/p4-user-facing.sh [--samples=N]
#
# --samples defaults to 3. Set it to 0 for an RPC-only check without sending transactions.

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SAMPLES=3
for arg in "$@"; do
  case "$arg" in
    --samples=*) SAMPLES="${arg#*=}" ;;
    *) echo "Usage: bash scripts/flashblocks/verify/p4-user-facing.sh [--samples=N]" >&2
       exit 1 ;;
  esac
done

case "$SAMPLES" in
  ''|*[!0-9]*) echo "--samples must be a non-negative integer" >&2; exit 1 ;;
esac

banner "P4 · user-facing Flashblocks RPC"

section "[1] RPC"
if ! rpc_alive "$FB_RPC"; then
  fail "op-reth RPC is unreachable (${FB_RPC})"
  summary
  exit 1
fi
pass "op-reth RPC is reachable (${FB_RPC})"
if ! rpc_alive "$L2_RPC"; then
  fail "canonical RPC is unreachable (${L2_RPC})"
  summary
  exit 1
fi
pass "canonical RPC is reachable (${L2_RPC})"

section "[2] Sub-second preconfirmation"
if [ "$SAMPLES" -eq 0 ]; then
  skip "--samples=0, no transaction was sent"
  summary
  exit $?
fi

KEY="${DEPLOY_PRIVATE_KEY:-}"
if [ -z "$KEY" ]; then
  fail "missing DEPLOY_PRIVATE_KEY"
  summary
  exit 1
fi
if ! require_cmd cast; then
  fail "cast is required"
  summary
  exit 1
fi
if [ ! -x "$TXPROBE" ]; then
  fail "txprobe is unavailable"
  summary
  exit 1
fi

# Use a disposable funded test key. cast receives the key through its command line.
FROM=$(cast wallet address --private-key "$KEY" 2>/dev/null)
BALANCE=$(cast balance "$FROM" --rpc-url "$FB_RPC" 2>/dev/null || echo 0)
if [ "$BALANCE" = "0" ]; then
  fail "test account ${FROM} has no balance"
  summary
  exit 1
fi
info "Test account: ${FROM}"

i=1
while [ "$i" -le "$SAMPLES" ]; do
  raw=$(cast mktx --private-key "$KEY" --rpc-url "$FB_RPC" --value 1 "$FROM" 2>&1 | tail -1)
  if [[ "$raw" != 0x* ]]; then
    fail "transaction ${i} could not be signed: ${raw}"
    break
  fi

  ok=0; txhash=""; pre_ms=-1; final_ms=-1; tx_status=-1; tx_block=-1; error=""
  eval "$("$TXPROBE" \
    --send-url="$FB_RPC" \
    --pending-url="$FB_RPC" \
    --canonical-url="$L2_RPC" \
    --raw="$raw" \
    --timeout=30)"

  if [ "$ok" != "1" ]; then
    fail "transaction ${i} was rejected: ${error}"
  elif [ "$final_ms" -lt 0 ]; then
    fail "transaction ${i} was not sealed within 30 seconds (${txhash})"
  elif [ "$tx_status" != "1" ]; then
    fail "transaction ${i} failed in block ${tx_block} (status=${tx_status})"
  elif [ "$pre_ms" -lt 0 ]; then
    fail "transaction ${i} never appeared in pending"
  elif [ "$pre_ms" -ge "$final_ms" ]; then
    fail "transaction ${i} appeared in pending after sealing (${pre_ms}ms >= ${final_ms}ms)"
  elif [ "$pre_ms" -ge 1000 ]; then
    fail "transaction ${i} preconfirmation was too slow (${pre_ms}ms)"
  else
    pass "transaction ${i}: pending=${pre_ms}ms, sealed=${final_ms}ms, block=${tx_block}"
  fi

  i=$((i + 1))
done

summary
