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
# When the test account is empty, the script bridges itself some funds from L1 first.
#
# Usage:
#   bash scripts/flashblocks/verify/p4-user-facing.sh [--samples=N]
#
# --samples defaults to 3. Set it to 0 for an RPC-only check without sending transactions
# and without bridging.

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

# Enough for a few 1-wei transfers plus gas; the exact figure does not matter.
FUND_AMOUNT=1ether

# Bridge FUND_AMOUNT from L1 to <address> and wait for the deposit to land on L2.
fund_from_l1() {
  local to="$1" artifact portal log deadline balance
  artifact="$BASE_PATH/config/${DEPLOYMENT_CONTEXT:-}/artifact.json"
  portal=$(jq -r '.OptimismPortalProxy // empty' "$artifact" 2>/dev/null)
  if [ -z "$portal" ]; then
    fail "cannot read OptimismPortalProxy from ${artifact}"
    return 1
  fi

  log=$(mktemp)
  bash "$BASE_PATH/scripts/bridge-to-l2-custom.sh" "$portal" "$FUND_AMOUNT" "$to" >"$log" 2>&1

  # The bridge script gives up waiting after 30s, which a slow L1 easily exceeds, and it
  # reports no error when it does. The deposit is committed on L1 by then, so treat the
  # balance itself as the verdict and keep waiting for op-node to derive it.
  deadline=$(( $(date +%s) + 180 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    balance=$(cast balance "$to" --rpc-url "$FB_RPC" 2>/dev/null || echo 0)
    if [ "$balance" != "0" ]; then
      info "Bridged ${FUND_AMOUNT}; balance is now ${balance}"
      rm -f "$log"
      return 0
    fi
    sleep 2
  done

  fail "the deposit did not reach L2 within 180s (bridge output: ${log})"
  return 1
}

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

# A custom-gas-token chain allocates no balance at genesis, so every account on a freshly
# deployed chain is empty and an L1 deposit is the only way in. Bridge once instead of
# failing and leaving the operator a manual step. Use --samples=0 to send nothing at all.
BALANCE=$(cast balance "$FROM" --rpc-url "$FB_RPC" 2>/dev/null || echo 0)
if [ "$BALANCE" = "0" ]; then
  info "Test account ${FROM} is empty; bridging ${FUND_AMOUNT} from L1"
  if ! fund_from_l1 "$FROM"; then
    summary
    exit 1
  fi
fi
info "Test account: ${FROM}"

# Count nonces here rather than letting cast derive one per transaction. cast reads the
# confirmed nonce, not the pool, so a transaction that is accepted but never mined leaves
# every later one signed with the nonce it still holds. Those then collide with it and are
# refused as underpriced replacements, turning one stuck transaction into a dozen failures
# that all blame fees and hide the real cause.
NONCE=$(cast nonce "$FROM" --rpc-url "$FB_RPC" --block pending 2>/dev/null)
case "$NONCE" in
  ''|*[!0-9]*) fail "could not read the nonce of ${FROM}"; summary; exit 1 ;;
esac

i=1
while [ "$i" -le "$SAMPLES" ]; do
  raw=$(cast mktx --private-key "$KEY" --rpc-url "$FB_RPC" --nonce "$NONCE" --value 1 "$FROM" 2>&1 | tail -1)
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
    break
  elif [ "$final_ms" -lt 0 ]; then
    # The nonce is spoken for but the transaction is not mined, so anything signed after it
    # would queue behind the gap and spend the whole timeout proving it. Report the one real
    # failure and stop.
    fail "transaction ${i} was not sealed within 30 seconds, stopping here (${txhash})"
    break
  elif [ "$tx_status" != "1" ]; then
    fail "transaction ${i} failed in block ${tx_block} (status=${tx_status})"
  elif [ "$pre_ms" -lt 0 ]; then
    fail "transaction ${i} never appeared in pending"
  elif [ "$pre_ms" -ge "$final_ms" ]; then
    fail "transaction ${i} appeared in pending after sealing (${pre_ms}ms >= ${final_ms}ms)"
  elif [ "$pre_ms" -ge 1000 ]; then
    fail "transaction ${i} preconfirmation was too slow (${pre_ms}ms)"
  else
    # txprobe also reports receipt_ms, the point at which op-reth could serve a receipt.
    # It is not shown because the same flashblock arrival drives both it and the pending
    # listing, so in practice it tracks pre_ms to within a poll interval and adds nothing.
    # Run txprobe directly when that assumption needs checking.
    pass "transaction ${i}: pending=${pre_ms}ms, sealed=${final_ms}ms, block=${tx_block}"
  fi

  NONCE=$((NONCE + 1))
  i=$((i + 1))
done

summary
