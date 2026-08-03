#!/bin/bash
#
# P1 verification: op-rbuilder shadow synchronization consistency.
#
# Corresponds to the P1 gate in doc/flashblocks_local_impl.md section 7:
#   "op-rbuilder catches up to the chain head; blockHash/stateRoot of key blocks match
#   op-geth; no invalid blocks."
#
# Checks:
#   1. Both op-geth and op-rbuilder are reachable.
#   2. Their chain-head height difference is <= --lag.
#   3. Sampled block hashes match exactly (genesis, evenly distributed samples, and
#      blocks near the head; the hash already covers stateRoot).
#   4. op-rbuilder logs contain no invalid block / bad block.
#   5. Both sides advance during the observation window and remain synchronized.
#
# Usage: bash scripts/flashblocks/verify/p1-shadow.sh [--lag=N] [--samples=N] [--watch=SEC]
#   --lag=N      Allowed chain-head height difference; default 2. Samples are taken
#                sequentially during block production, so exact equality is not required.
#   --samples=N  Number of evenly distributed blocks to sample; default 6. Genesis and
#                four blocks near the head are always added.
#   --watch=SEC  Seconds to observe synchronization progress; default 8. Set to 0 to skip.

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LAG=2; SAMPLES=6; WATCH=8
for arg in "$@"; do
  case "$arg" in
    --lag=*)     LAG="${arg#*=}" ;;
    --samples=*) SAMPLES="${arg#*=}" ;;
    --watch=*)   WATCH="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p1-shadow.sh [--lag=N] [--samples=N] [--watch=SEC]" >&2
       exit 1 ;;
  esac
done

banner "P1 · op-rbuilder shadow synchronization consistency"
info "op-geth     = ${L2_RPC}"
info "op-rbuilder = ${RB_RPC}"
info "Parameters: lag<=${LAG}  samples=${SAMPLES}  observation=${WATCH}s"

# ---------- Reachability ----------
section "Node reachability"
gbn=$(rpc_bn "$L2_RPC"); rbn=$(rpc_bn "$RB_RPC")
if [ "$gbn" -lt 0 ]; then
  fail "op-geth is unreachable (${L2_RPC})"
  summary; exit 1
fi
pass "op-geth is reachable, head=${gbn}"
if [ "$rbn" -lt 0 ]; then
  fail "op-rbuilder is unreachable (${RB_RPC}); P1 cannot be verified"
  summary; exit 1
fi
pass "op-rbuilder is reachable, head=${rbn}"

# ---------- Catch-up ----------
section "Chain-head catch-up"
diff=$((gbn - rbn)); [ "$diff" -lt 0 ] && diff=$((-diff))
info "op-geth head=${gbn}   op-rbuilder head=${rbn}   |Δ|=${diff}"
assert_num_le "$diff" "$LAG" "chain-head height difference is within tolerance"

# An op-rbuilder stall is a typical failure in this topology: rollup-boost feeds only the
# current head and does not backfill history, while op-rbuilder usually has no P2P peer.
# A gap caused by downtime therefore leaves it permanently stalled.
if [ "$diff" -gt "$LAG" ]; then
  detail "If the difference does not converge, op-rbuilder was probably restarted alone and its gap was never backfilled."
  detail "See the common-failures table in doc/chain-lifecycle.md; run the off -> switch flow so the builder op-node can backfill it."
fi

# ---------- Block fingerprint comparison ----------
section "Block hash comparison"
top=$rbn; [ "$gbn" -lt "$top" ] && top=$gbn   # Compare only heights available on both sides.

nums="0"
if [ "$SAMPLES" -gt 0 ] && [ "$top" -gt 1 ]; then
  step=$((top / (SAMPLES + 1)))
  [ "$step" -lt 1 ] && step=1
  i=1
  while [ "$i" -le "$SAMPLES" ]; do
    n=$((step * i))
    [ "$n" -ge 1 ] && [ "$n" -lt "$top" ] && nums="$nums $n"
    i=$((i + 1))
  done
fi
for off in 10 3 1 0; do
  n=$((top - off))
  [ "$n" -ge 1 ] && nums="$nums $n"
done
nums=$(echo "$nums" | tr ' ' '\n' | sort -n -u | tr '\n' ' ')

# Compare only blockHash: it hashes the entire block header, including stateRoot.
# Query stateRoot only on a mismatch to distinguish different execution results from
# other header differences.
mismatch=0; checked=0
for n in $nums; do
  a=$(block_hash "$L2_RPC" "$n")
  b=$(block_hash "$RB_RPC" "$n")
  checked=$((checked + 1))
  if [ -z "$a" ] || [ -z "$b" ]; then
    warn "could not obtain blockHash for block ${n}: geth=[${a}] rbuilder=[${b}]"
  elif [ "$a" = "$b" ]; then
    detail "block ${n}  ✓  ${a}"
  else
    mismatch=$((mismatch + 1))
    fail "block ${n} blockHash mismatch"
    detail "geth     hash=${a}  stateRoot=$(block_state_root "$L2_RPC" "$n")"
    detail "rbuilder hash=${b}  stateRoot=$(block_state_root "$RB_RPC" "$n")"
  fi
done
info "compared ${checked} blocks (including genesis); ${mismatch} mismatches"
assert_eq 0 "$mismatch" "all sampled block hashes match"

# ---------- Invalid blocks ----------
section "op-rbuilder invalid blocks"
inv=$(log_count op-rbuilder 'invalid block|bad block|INVALID|failed to insert')
assert_eq 0 "$inv" "op-rbuilder logs contain no invalid / bad block"

# ---------- Synchronization progress ----------
if [ "$WATCH" -gt 0 ]; then
  section "Synchronization progress observation (${WATCH}s)"
  g0=$(rpc_bn "$L2_RPC"); r0=$(rpc_bn "$RB_RPC")
  sleep "$WATCH"
  g1=$(rpc_bn "$L2_RPC"); r1=$(rpc_bn "$RB_RPC")
  info "op-geth     ${g0} → ${g1}  (+$((g1 - g0)))"
  info "op-rbuilder ${r0} → ${r1}  (+$((r1 - r0)))"
  if [ "$g1" -gt "$g0" ]; then pass "op-geth continues producing blocks"; else fail "op-geth produced no blocks in ${WATCH}s"; fi
  if [ "$r1" -gt "$r0" ]; then
    pass "op-rbuilder advances with op-geth"
  else
    fail "op-rbuilder height did not change in ${WATCH}s; it may be stalled by an unfilled gap"
  fi
  d1=$((g1 - r1)); [ "$d1" -lt 0 ] && d1=$((-d1))
  assert_num_le "$d1" "$LAG" "nodes remain synchronized at the end of observation"
fi

summary
