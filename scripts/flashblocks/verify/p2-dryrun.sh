#!/bin/bash
#
# P2 verification: builder-block validity in dry_run mode.
#
# Corresponds to the P2 gate in doc/flashblocks_local_impl.md section 7. It checks only
# six items, each of which independently detects a real problem:
#
#   1. rollup-boost is in dry_run mode.           Prerequisite; all later checks are
#                                                   meaningless otherwise.
#   2. op-node's Engine points to rollup-boost.   Otherwise the builder does not
#                                                   participate and item 5's zero is false.
#   3. The builder op-node is stopped.            It competes with rollup-boost for
#                                                   op-rbuilder's auth RPC.
#   4. Block production speed is unaffected.      Required by the original P2 gate.
#   5. No builder block is marked INVALID.        Hard gate and the core P2 claim.
#   6. The builder delivers candidate blocks.     Prevents item 5's zero from being
#                                                   "zero samples" rather than "zero defects."
#
# Item 5 verification: after receiving a candidate block, op-geth independently replays
#   all transactions and recomputes stateRoot/receiptsRoot/gasUsed. It returns INVALID
#   if those values differ from the header. client/rpc.rs in rollup-boost converts
#   INVALID to an error, which reaches server.rs and logs:
#     error getting payload from builder error=InvalidPayload(...)
#   Therefore, counting InvalidPayload in the logs is sufficient: no entries means every
#   builder-produced block was valid. This is stronger than requiring builder and
#   op-geth blocks to be identical because op-geth recomputes independently without
#   requiring identical inputs.
#
# Deliberately omitted checks:
#   - Whether builder and op-geth blocks are identical. The builder has its own ordering
#     and slicing strategy and should produce different blocks in enabled mode. Inspect
#     rollup-boost Prometheus metrics for difference distributions
#     (block_building_gas_delta/block_building_tx_count_delta; see RB_METRICS_PORT).
#   - Slice configuration. This is a one-time static check in p0-genesis.sh.
#   - Flashblock slice count and preconfirmation-stream quality. The stream has no
#     consumers during dry_run; this is checked in p3-enabled.sh.
#   - safe head / batcher / proposer health. These concern base-chain health rather than
#     Flashblocks and belong in p1-shadow.sh and routine monitoring.
#
# Log counting: verification targets a newly started chain, so determine whether any
#   errors occurred from complete-log counts. There should be no InvalidPayload from
#   genesis through the present. Only delivery rate must be compared with blocks produced
#   inside the window, so those two counts use before/after deltas.
#
# Usage: bash scripts/flashblocks/verify/p2-dryrun.sh [--watch=SEC]
#   --watch=SEC  Observation window in seconds; default 30 (about 15 L2 blocks).

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WATCH=30
for arg in "$@"; do
  case "$arg" in
    --watch=*) WATCH="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p2-dryrun.sh [--watch=SEC]" >&2
       exit 1 ;;
  esac
done

banner "P2 · Builder-block validity in dry_run mode"

# ---------- [1] Prerequisite: execution mode ----------
section "[1] rollup-boost execution mode"
mode=$(boost_mode)
if [ "$mode" = "none" ]; then
  fail "rollup-boost debug endpoint (${RB_DEBUG}) is unresponsive; it is not running, so P2 cannot be evaluated"
  summary; exit 1
fi
assert_eq "dry_run" "$mode" "execution mode is dry_run"
[ "$mode" = "enabled" ] && detail "The current mode is enabled; run p3-enabled.sh instead."

# ---------- [2][3] Topology ----------
section "[2][3] Engine control ownership"
# Enumerate all op-node processes and classify them by their --l2 targets.
# Match exact process names with pgrep -x: `ps | rg op-node` would also match rg itself.
main_l2=""; builder_pids=""
for pid in $(pgrep -x op-node 2>/dev/null); do
  l2=$(ps -o args= -p "$pid" 2>/dev/null | rg -o '\-\-l2=([^ ]+)' -r '$1' | head -1)
  case "$l2" in
    *":${RBUILDER_AUTHRPC_PORT:-8661}"*) builder_pids="$builder_pids $pid" ;;
    *":${FB_RPC_AUTHRPC_PORT:-8751}"*)   ;;   # Verifier op-node; present only in enabled mode and irrelevant to P2.
    *) main_l2="$l2" ;;
  esac
done

if [ -z "$main_l2" ]; then
  fail "primary op-node (sequencer) process not found"
elif echo "$main_l2" | rg -q ":${RB_ENGINE_PORT:-8551}"; then
  pass "op-node is routed to rollup-boost (:${RB_ENGINE_PORT:-8551})"
else
  fail "op-node still connects directly to op-geth (${main_l2}); the switch did not take effect and the builder is not participating"
fi

# The builder op-node must be stopped because it competes with rollup-boost for the same
# op-rbuilder auth RPC. Content in data/logs/op-rbuilder-opnode.log does not prove that
# it is still running; those are historical logs from the temporary synchronization
# node used during switching. Check the process, not the log.
if [ -n "$builder_pids" ]; then
  fail "builder op-node is still running (PID${builder_pids}) and will compete with rollup-boost for Engine control"
else
  pass "builder op-node is stopped (rollup-boost exclusively controls the Engine)"
fi

# ---------- Observation ----------
section "Observe for ${WATCH}s"
# log_count <log-name> <regex>, defined in lib.sh, is `rg -c` after stripping ANSI codes.
# Delivery counts are meaningful only relative to blocks produced in the window, so use
# before/after deltas for these two values.
before_delivered=$(log_count rollup-boost 'get_payload_v[0-9]\{.*:new_payload_v[0-9]\{.*target="l2"')
before_nodeliver=$(log_count rollup-boost 'error getting payload from builder')
g0=$(rpc_bn "$L2_RPC")
t0=$(date +%s)

sleep "$WATCH"

delivered=$(( $(log_count rollup-boost 'get_payload_v[0-9]\{.*:new_payload_v[0-9]\{.*target="l2"') - before_delivered ))
nodeliver=$(( $(log_count rollup-boost 'error getting payload from builder') - before_nodeliver ))
g1=$(rpc_bn "$L2_RPC"); r1=$(rpc_bn "$RB_RPC")
elapsed=$(( $(date +%s) - t0 ))
blocks=$((g1 - g0))

# These two values use full-chain totals: neither should ever occur in dry_run mode, so
# any historical occurrence is a problem rather than only occurrences in this window.
invalid=$(log_count rollup-boost 'InvalidPayload')
adopted=$(log_count rollup-boost 'returning block.*context=builder')

# ---------- [4] Block production ----------
section "[4] Block production speed is unaffected"
info "op-geth ${g0} → ${g1}   (${blocks} blocks / ${elapsed}s)"
expected=$(( elapsed / ${L2_BLOCK_TIME:-2} ))
assert_num_ge "$blocks" "$(( expected - expected / 4 - 1 ))" \
  "block count meets expectations (about ${expected} blocks, L2_BLOCK_TIME=${L2_BLOCK_TIME:-2}s)"

# dry_run safety semantics: builder payloads are compared but never put on-chain.
# rollup-boost logs "returning block ... context=<l2|builder>" for every getPayload;
# context identifies the payload source ultimately given to op-node. In dry_run mode,
# builder must never be selected.
assert_eq 0 "$adopted" "no builder payload was adopted on-chain (dry_run semantics)"
if [ "$adopted" -gt 0 ]; then
  detail "This is a full-chain count. If the chain previously used enabled mode, those historical entries are included."
  detail "They do not indicate a current dry_run problem; clear data/logs, restart the chain, and verify again."
fi

# ---------- [5] Validity: hard gate ----------
section "[5] Builder-block validity (hard gate)"
#
# Boundary (do not misread this zero): Engine API statuses are VALID, INVALID, SYNCING,
# and ACCEPTED. rollup-boost records an error only for INVALID (is_invalid() in
# client/rpc.rs, defined in alloy as matches!(self, Invalid{..})); SYNCING and ACCEPTED
# are treated as success. Therefore, a zero grep count means "none were classified as
# invalid," not "all were verified." op-geth may not have completed validation, returning
# SYNCING when a candidate block's parent is unknown. That almost always indicates that
# the builder is behind and is indirectly detected by item 6's delivery rate and height
# difference.
#
detail "op-geth independently replays builder blocks and recomputes state roots; INVALID leaves InvalidPayload in the logs."
assert_eq 0 "$invalid" "op-geth classified no builder block as INVALID"
if [ "$invalid" -gt 0 ]; then
  detail "Narrow down the cause in this order: blockHash → stateRoot/receiptsRoot/gasUsed → specific transaction."
  detail "See doc/flashblocks_local_impl.md section 8.4."
fi

# ---------- [6] Delivery rate: guard against zero samples ----------
section "[6] Builder delivery rate (guard against false PASS from zero samples)"
# INVALID=0 may simply mean that the builder delivered no blocks. Zero samples do not
# imply zero defects. Missing blocks are harmless in dry_run because op-geth blocks are
# used anyway. In enabled mode, each miss triggers fallback: the chain remains safe, but
# that block has no Flashblocks.
info "candidate blocks delivered ${delivered} times / ${blocks} blocks produced; ${nodeliver} delivery failures"
if [ "$blocks" -le 0 ]; then
  fail "no blocks were produced in the window; cannot evaluate"
elif [ "$delivered" -lt $((blocks / 2)) ]; then
  fail "delivery rate is only ${delivered}/${blocks}; INVALID=0 above reflects zero samples and proves nothing"
  # A builder falling behind is the most common cause and is invisible in rollup-boost
  # logs, so compare block heights.
  lag=$((g1 - r1)); [ "$lag" -lt 0 ] && lag=$((-lag))
  if [ "$lag" -gt 2 ]; then
    detail "Root cause: op-rbuilder is ${lag} blocks behind (op-geth ${g1} / op-rbuilder ${r1})."
    detail "op-rbuilder has no P2P and rollup-boost does not backfill history; perform a complete rebuild:"
    detail "chain-stop → FLASHBLOCKS_MODE=off → chain-start → switch-to-flashblocks-dryrun.sh"
  else
    detail "op-rbuilder height is normal (${lag} blocks behind); inspect errors in data/logs/op-rbuilder.log."
  fi
else
  rate=$((delivered * 100 / blocks))
  if [ "$rate" -ge 95 ]; then
    pass "delivery rate ${rate}% (${delivered}/${blocks}); item 5 is supported by enough samples"
  else
    warn "delivery rate ${rate}% (${delivered}/${blocks}); in enabled mode, these misses fall back to op-geth and produce blocks without Flashblocks"
  fi
fi

summary
