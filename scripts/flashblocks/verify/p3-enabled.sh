#!/bin/bash
#
# P3 verification in enabled mode: builder blocks reach the canonical chain, with
# graceful fallback on builder failure.
#
# Corresponds to the P3 gate in doc/flashblocks_local_impl.md section 7:
#   "builder blocks are used for the canonical chain; Flashblocks are produced
#   continuously; failures in op-rbuilder fall back to op-geth."
#
# Evidence:
#   rollup-boost logs the following for every getPayload:
#     returning block hash=… number=… context=<l2|builder> payload_id=0x…
#   context identifies the payload source ultimately put on-chain (upstream integration
#   tests use the same line). In enabled mode, the vast majority should be builder; on
#   fallback, it automatically returns to l2 without interrupting block production.
#
# Usage: bash scripts/flashblocks/verify/p3-enabled.sh [--switch] [--watch=SEC] [--fallback-drill]
#   --switch          Switch live from dry_run to enabled. Remain enabled on success;
#                     restore the original mode on failure or interruption.
#   --watch=SEC       Observation duration in seconds; default 30.
#   --fallback-drill  Destructive and disabled by default. Deliberately switch
#                     rollup-boost to disabled to induce a failure.
#
# Default, non-destructive fallback verification:
#   Occasional builder payload failures are normal ("error getting payload from builder"
#   in the logs). rollup-boost automatically uses an l2 payload instead. Existing logs
#   can therefore prove the fallback path by confirming that every builder failure
#   corresponds to a returning block with context=l2, without inducing a failure.
#
# Why --fallback-drill is destructive (confirmed empirically; use with care):
#   In disabled mode, rollup-boost stops sending all requests to the builder, including
#   FCU and newPayload, so op-rbuilder disconnects completely from the chain. This
#   topology provides no P2P backfill. After restoring enabled, op-rbuilder cannot obtain
#   the missing blocks and its head remains permanently stuck at the drill's starting
#   height. rollup-boost then repeatedly reports "Unknown payload," and builder blocks
#   can no longer reach the chain. A 12-second disabled drill has been observed to leave
#   op-rbuilder 30+ blocks behind without recovery. The only remedy is the complete
#   off -> switch-to-flashblocks-dryrun.sh flow, using the temporary builder op-node to
#   fill the gap through CL P2P.

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DO_SWITCH=0; WATCH=30; DRILL=0
for arg in "$@"; do
  case "$arg" in
    --switch)         DO_SWITCH=1 ;;
    --watch=*)        WATCH="${arg#*=}" ;;
    --fallback-drill) DRILL=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p3-enabled.sh [--switch] [--watch=SEC] [--fallback-drill]" >&2
       exit 1 ;;
  esac
done

banner "P3 · enabled mode and fallback capability"

# After a successful --switch, persist enabled as the initial mode in .envrc. Restore the
# original runtime mode on failure or interruption.
ORIG_MODE=""; RESTORE=0

on_exit() {
  local rc=$?
  [ "$RESTORE" = "1" ] || return "$rc"
  [ -n "$ORIG_MODE" ] || return "$rc"
  local now; now=$(boost_mode)
  if [ "$now" != "$ORIG_MODE" ]; then
    echo ""
    echo "  ${C_YEL}Verification incomplete; restoring the original execution mode: ${now} → ${ORIG_MODE}${C_OFF}"
    set_boost_mode "$ORIG_MODE" >/dev/null
    echo "  Current mode: $(boost_mode)"
  fi
  return "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- Mode preparation ----------
section "Execution mode"
mode=$(boost_mode)
if [ "$mode" = "none" ]; then
  fail "rollup-boost debug endpoint (${RB_DEBUG}) is unresponsive; rollup-boost is not running"
  summary; exit 1
fi
info "Current mode = ${mode}"
ORIG_MODE="$mode"

if [ "$mode" = "enabled" ]; then
  pass "already in enabled mode"
elif [ "$DO_SWITCH" = "1" ]; then
  info "Switching live to enabled via --switch (remain enabled on success; restore ${ORIG_MODE} on failure)"
  RESTORE=1
  mode=$(set_boost_mode enabled)
  assert_eq "enabled" "$mode" "switched live to enabled"
  [ "$mode" != "enabled" ] && { summary; exit 1; }
  sleep 5   # Give op-node several blocks to complete an FCU → getPayload cycle.
else
  fail "current mode is ${mode}, not enabled; add --switch to change modes, remaining enabled on success and restoring on failure"
  summary; exit 1
fi

# ---------- Observation ----------
# Block production and payload source must be measured within this window. Logs cover the
# entire chain and still contain many context=l2 entries from dry_run before the switch
# to enabled. Measure these three counts before and after the window and subtract them;
# full-log counts remain appropriate for all other checks.
section "Observe for ${WATCH}s"
before_builder=$(log_count rollup-boost 'returning block.*context=builder')
before_l2=$(     log_count rollup-boost 'returning block.*context=l2')
before_fb=$(     log_count op-rbuilder  'Flashblock built')
g0=$(rpc_bn "$L2_RPC")

sleep "$WATCH"

builder=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))
l2=$((      $(log_count rollup-boost 'returning block.*context=l2')      - before_l2 ))
fb=$((      $(log_count op-rbuilder  'Flashblock built')                 - before_fb ))
g1=$(rpc_bn "$L2_RPC")
blocks=$((g1 - g0))

# ---------- Builder blocks on the canonical chain ----------
section "Builder blocks used by the canonical chain"
total=$((builder + l2))
info "returning blocks in window: context=builder ${builder}, context=l2 ${l2}"
info "op-geth ${g0} → ${g1} (${blocks} blocks / ${WATCH}s)"
if [ "$total" -le 0 ]; then
  fail "no payloads were produced in the window"
else
  ratio=$((builder * 100 / total))
  if [ "$ratio" -ge 90 ]; then
    pass "builder blocks account for ${ratio}% (${builder}/${total}); Flashblocks are active"
  elif [ "$ratio" -gt 0 ]; then
    warn "builder blocks account for only ${ratio}% (${builder}/${total}); a substantial share fell back to op-geth"
    detail "Fallback usually results from builder timeouts or getPayload failures; inspect op-rbuilder load and logs."
  else
    fail "no builder blocks reached the chain; enabled mode is not actually effective"
  fi
fi
assert_num_ge "$blocks" 1 "the chain continues producing blocks"

# ---------- flashblocks ----------
section "Flashblock production"
per=$(( ${L2_BLOCK_TIME:-2} * 1000 / ${FB_INTERVAL_MS:-250} ))
if [ "$blocks" -gt 0 ]; then
  avg=$((fb / blocks))
  info "built ${fb} Flashblocks / ${blocks} blocks, averaging ${avg} per block (expected ${per})"
  assert_num_ge "$avg" $((per - per / 4)) "Flashblocks are produced continuously at an acceptable slice count"
else
  skip "no blocks were produced in the window; cannot evaluate Flashblocks"
fi

# ---------- External Flashblocks broadcast ----------
section "External Flashblocks broadcast (:${RB_FLASHBLOCKS_WS_PORT:-1112})"
# In enabled mode, this stream supplies user-facing preconfirmations: rollup-boost
# forwards builder slices here, and flashblocks-websocket-proxy distributes them to
# op-reth. Verify not only that the port is open, but that the handshake upgrades to
# WebSocket and data actually flows. This is the only check a shell cannot perform, so
# wscheck handles it (verify/wscheck/main.go).
if [ ! -x "$WSCHECK" ]; then
  skip "wscheck is not built (Go toolchain required); skipping the broadcast-stream check"
else
  ok=0; status=0; bytes=0; slices=0; covered_blocks=0; error=""
  eval "$("$WSCHECK" --port="${RB_FLASHBLOCKS_WS_PORT:-1112}" --timeout=6 --verbose)"
  if [ "$ok" != "1" ]; then
    fail "Flashblocks broadcast port is unavailable (${error:-handshake failed}, HTTP status ${status})"
  elif [ "$bytes" -gt 0 ]; then
    pass "WebSocket handshake succeeded; received ${slices} slices / ${bytes} bytes covering ${covered_blocks} blocks"
  else
    fail "WebSocket handshake succeeded but no data arrived within 6s; the builder is not producing slices"
  fi
fi

# ---------- Errors ----------
# Use full-log counts because verification targets a newly started chain; every error of
# these types deserves investigation.
section "Errors (full-chain totals)"
check_errors() {
  local n; n=$(log_count "$1" "$2")
  if [ "$n" -eq 0 ]; then pass "$3: 0"; else warn "$3: ${n}; inspect data/logs/${1}.log"; fi
}
check_errors rollup-boost 'error getting payload from builder' "rollup-boost builder-payload retrieval failures"
check_errors rollup-boost 'Invalid index for flashblock'       "Invalid index for flashblock"
check_errors rollup-boost 'Payload ID mismatch'                "Payload ID mismatch"
check_errors op-geth      'Invalid block|bad block|Failed to insert' "op-geth invalid / bad block"
check_errors op-node      '\bERROR\b|lvl=eror|lvl=crit'        "op-node ERROR"

# ---------- Fallback capability (default: inspect existing logs, non-destructive) ----------
section "Fallback capability: automatic op-geth fallback on builder failure"
# Failure and block-return lines share a payload_id; intersecting them identifies which
# source ultimately supplied the block. The payload_id on a failure line is in the
# prefix span (get_payload_v4{… payload_id=0x…}: … error …), not after the keyword, so
# first filter by keyword and then extract the ID from the complete line.
RB_LOG="$LOG_DIR/rollup-boost.log"
if [ ! -f "$RB_LOG" ]; then
  skip "rollup-boost log is unavailable; cannot verify fallback history"
else
  failed_ids=$(strip_ansi "$RB_LOG" | rg 'error getting payload from builder' \
    | rg -o 'payload_id=(0x[0-9a-f]+)' -r '$1' | sort -u)
  nf=$(echo "$failed_ids" | rg -c '.' || echo 0)
  info "${nf} builder payload retrieval failures (deduplicated by payload_id)"
  if [ "$nf" -eq 0 ]; then
    skip "no builder failure has occurred; no historical data is available to verify the fallback path"
    detail "Use --fallback-drill for an active drill (destructive; see the script header)."
  else
    fell_back=$(comm -12 <(echo "$failed_ids") \
      <(strip_ansi "$RB_LOG" | rg -o 'context=l2 payload_id=(0x[0-9a-f]+)'      -r '$1' | sort -u) | rg -c '.' || echo 0)
    still_builder=$(comm -12 <(echo "$failed_ids") \
      <(strip_ansi "$RB_LOG" | rg -o 'context=builder payload_id=(0x[0-9a-f]+)' -r '$1' | sort -u) | rg -c '.' || echo 0)
    detail "${fell_back} fell back to op-geth; ${still_builder} still used the builder"
    assert_eq 0 "$still_builder" "no builder failure was incorrectly treated as success"
    assert_num_ge "$fell_back" 1 "builder failures automatically fall back to op-geth without interrupting the chain"
  fi
fi

# ---------- Active fallback drill (destructive; must be explicitly enabled) ----------
if [ "$DRILL" = "1" ]; then
  section "Active fallback drill (destructive)"
  warn "disabled disconnects op-rbuilder completely and it cannot recover automatically; rebuild builder synchronization after the drill"
  detail "Recovery: run bash scripts/flashblocks/stop-flashblocks.sh, then rerun"
  detail "          bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh"
  RESTORE=1

  d0=$(rpc_bn "$L2_RPC")
  before_l2=$(     log_count rollup-boost 'returning block.*context=l2')
  before_builder=$(log_count rollup-boost 'returning block.*context=builder')
  m=$(set_boost_mode disabled)
  assert_eq "disabled" "$m" "switched to disabled (simulating builder unavailability)"
  sleep 12
  d1=$(rpc_bn "$L2_RPC")
  drill_l2=$((      $(log_count rollup-boost 'returning block.*context=l2')      - before_l2 ))
  drill_builder=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))

  info "blocks during fallback ${d0} → ${d1} (+$((d1 - d0)))"
  assert_num_ge "$((d1 - d0))" 1 "the chain continues producing blocks while the builder is unavailable (fell back to op-geth)"
  info "during fallback: context=l2 ${drill_l2}, context=builder ${drill_builder}"
  assert_eq 0 "$drill_builder" "builder blocks are not adopted during fallback"

  m=$(set_boost_mode enabled)
  assert_eq "enabled" "$m" "restored enabled mode"
  sleep 8
  before_builder=$(log_count rollup-boost 'returning block.*context=builder')
  sleep 10
  back=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))

  gnow=$(rpc_bn "$L2_RPC"); rnow=$(rpc_bn "$RB_RPC")
  info "after recovery, context=builder appeared ${back} times in the window; op-geth=${gnow}  op-rbuilder=${rnow}"
  if [ "$back" -ge 1 ]; then
    pass "builder blocks reached the chain again; this drill caused no lag"
  else
    fail "builder block production did not recover; op-rbuilder is $((gnow - rnow)) blocks behind and cannot recover automatically"
    detail "This is the expected cost of a disabled drill: op-rbuilder receives no FCU/newPayload during the drill,"
    detail "and no source can backfill the missing blocks. Rebuild builder synchronization:"
    detail "  bash scripts/flashblocks/stop-flashblocks.sh"
    detail "  bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh"
  fi
fi

if summary; then
  if [ "$RESTORE" = "1" ]; then
    if set_envrc_mode enabled; then
      RESTORE=0
      info "Verification passed: remaining enabled and updated .envrc"
    else
      echo "  ${C_RED}FAIL${C_OFF}  failed to update .envrc; restoring ${ORIG_MODE}" >&2
      exit 1
    fi
  fi
else
  exit 1
fi
