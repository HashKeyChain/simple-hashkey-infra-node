#!/bin/bash
#
# Run the verification gates appropriate for the chain's current state, then summarize.
#
# Select automatically according to the rollup-boost execution mode:
#   not running / off -> P0 only (build artifacts and configuration alignment;
#                        Flashblocks need not be running)
#   dry_run          -> P0 + P1 + P2 (topology, block production, payload validity,
#                        and delivery rate)
#   enabled          -> P0 + P1 + P3 + P4 (P2's dry_run assertions are intentionally false
#                        in enabled mode; P4 covers the user-facing path)
#
# P5 is not part of this rotation: p5-acceptance.sh is the top-level acceptance entry and
# runs these gates itself.
#
# Usage: bash scripts/flashblocks/verify/run-all.sh [--watch=SEC] [--quick]
#   --watch=SEC  Observation window passed to stages that support it; default 30.
#   --quick      Equivalent to --watch=10, and P4 sends no transactions.

set -uo pipefail
VERIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$VERIFY_DIR/lib.sh"

WATCH=30; QUICK=0
for arg in "$@"; do
  case "$arg" in
    --watch=*)  WATCH="${arg#*=}" ;;
    --quick)    WATCH=10; QUICK=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/run-all.sh [--watch=SEC] [--quick]" >&2
       exit 1 ;;
  esac
done

banner "Flashblocks verification overview"
mode=$(boost_mode)
info "rollup-boost execution mode = ${mode}"
info ".envrc FLASHBLOCKS_MODE = ${FLASHBLOCKS_MODE:-off}"

STAGES=""
case "$mode" in
  dry_run) STAGES="p0-genesis p1-shadow p2-dryrun"
           ;;
  enabled) STAGES="p0-genesis p1-shadow p3-enabled p4-user-facing" ;;
  *)       STAGES="p0-genesis"
           info "Flashblocks is not running, so only P0 can be verified. Rerun after startup to cover P1/P2/P3/P4." ;;
esac
info "Stages to run: ${STAGES}"

RESULTS=""; FAILED=0
for s in $STAGES; do
  case "$s" in
    p0-genesis)     args="" ;;
    # P4 is the only stage that sends transactions, so --quick turns them off.
    p4-user-facing) args=""; [ "$QUICK" = "1" ] && args="--samples=0" ;;
    *)              args="--watch=${WATCH}" ;;
  esac
  # shellcheck disable=SC2086
  if bash "$VERIFY_DIR/${s}.sh" $args; then
    RESULTS="${RESULTS}  ${C_GRN}PASS${C_OFF}  ${s}
"
  else
    RESULTS="${RESULTS}  ${C_RED}FAIL${C_OFF}  ${s}
"
    FAILED=$((FAILED + 1))
  fi
done

banner "Overview"
printf '%s' "$RESULTS"
if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "  ${C_RED}${FAILED} stage(s) failed${C_OFF}; review the corresponding FAIL details above."
  exit 1
fi
echo ""
echo "  ${C_GRN}All stages passed${C_OFF}"
