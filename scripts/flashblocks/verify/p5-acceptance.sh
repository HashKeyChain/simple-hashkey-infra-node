#!/bin/bash
#
# P5 verification: local acceptance.
#
# Corresponds to P5 in doc/flashblocks_local_impl.md section 7:
#   "run one complete scenario (functionality, fault-proof non-regression, fallback),
#   record it, and form the local acceptance conclusion."
#
# Four parts:
#   1. Run the earlier gates P0 / P1 / P3 / P4 and collect their verdicts.
#   2. End-to-end functional scenarios sent through the user-facing RPC (op-reth :8745):
#      a plain transfer, a contract deployment plus call, and a reverting transaction.
#      Every one of them is cross-checked so op-reth and op-geth agree on the block it
#      landed in, which is what ties the flashblocks preview back to the canonical chain.
#   3. Fault-proof non-regression: the safe head advances, the proposer keeps submitting,
#      and batcher / challenger report nothing unusual.
#   4. Write everything to a Markdown report so the acceptance run leaves a record.
#
# Explicitly out of scope. A PASS here must not be read as covering these:
#   - deposits and withdrawals: they need L1 bridge interaction and are unrelated to
#     Flashblocks; verify them with the chain's own bridge tests
#   - CGT gas accounting: see scripts/jovian/verify-jovian-fees.sh
#   - L1 origin rotation: guaranteed by op-node derivation, covered indirectly by the
#     continuous block production checked in p1 and p3
#
# Usage: bash scripts/flashblocks/verify/p5-acceptance.sh [options]
#   --watch=SEC          observation window handed to gates that support it, default 60
#   --samples=N          preconfirmation samples for P4, default 3
#   --report=PATH        report path, default data/verify-reports/p5-<timestamp>.md
#   --skip-gates         skip P0/P1/P3/P4 and run only the scenarios in this script
#   --fallback-drill     [destructive] also run the p3 fallback drill
#   --restart-off-drill  [destructive] rehearse the hard rollback: stop the chain, restart
#                        it in off mode, verify, then switch back to enabled
#   --yes                do not ask for confirmation before a destructive drill
#
# Why both drills are off by default:
#   --fallback-drill switches rollup-boost to disabled, which pushes op-rbuilder off the
#     chain permanently because nothing backfills the gap (see the header of p3-enabled.sh).
#     Running it during acceptance means committing to rebuilding builder sync afterwards.
#   --restart-off-drill really stops the chain and starts it twice. It takes at least ten
#     minutes, and op-node restarts are constrained by the channel_timeout safety window
#     described as [9] in doc/flashblocks_local_impl.md section 7: restarting before that
#     window opens makes op-node exit with a crit error.
#   Without them this script only reads; it starts and stops nothing.

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WATCH=60; SAMPLES=3; SKIP_GATES=0; FB_DRILL=0; OFF_DRILL=0; ASSUME_YES=0
REPORT=""
for arg in "$@"; do
  case "$arg" in
    --watch=*)           WATCH="${arg#*=}" ;;
    --samples=*)         SAMPLES="${arg#*=}" ;;
    --report=*)          REPORT="${arg#*=}" ;;
    --skip-gates)        SKIP_GATES=1 ;;
    --fallback-drill)    FB_DRILL=1 ;;
    --restart-off-drill) OFF_DRILL=1 ;;
    --yes)               ASSUME_YES=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p5-acceptance.sh [--watch=SEC] [--samples=N] [--report=PATH] [--skip-gates] [--fallback-drill] [--restart-off-drill] [--yes]" >&2
       exit 1 ;;
  esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
[ -n "$REPORT" ] || REPORT="$DATA_DIR/verify-reports/p5-${STAMP}.md"

# The report is assembled in memory and written once at the end, so an interrupted run
# never leaves a half-written file that looks like a real acceptance record.
REPORT_BODY=""
note() { REPORT_BODY="${REPORT_BODY}$1
"; }

banner "P5 · local acceptance"

# ---------- Environment snapshot ----------
section "Environment"
mode=$(boost_mode)
geth_bn=$(rpc_bn "$L2_RPC")
rb_bn=$(rpc_bn "$RB_RPC")
reth_bn=$(rpc_bn "$FB_RPC")
info "rollup-boost execution mode = ${mode}"
info ".envrc FLASHBLOCKS_MODE      = ${FLASHBLOCKS_MODE:-off}"
info "heads: op-geth=${geth_bn}  op-rbuilder=${rb_bn}  op-reth=${reth_bn}"

note "# Flashblocks P5 local acceptance"
note ""
note "- Time: $(date '+%Y-%m-%d %H:%M:%S %z')"
note "- Deployment context: ${DEPLOYMENT_CONTEXT:-local-mainnet}"
note "- rollup-boost execution mode: \`${mode}\`"
note "- .envrc FLASHBLOCKS_MODE: \`${FLASHBLOCKS_MODE:-off}\`"
note "- Heads at start: op-geth \`${geth_bn}\`, op-rbuilder \`${rb_bn}\`, op-reth \`${reth_bn}\`"
note ""

if [ "$mode" != "enabled" ]; then
  fail "execution mode is ${mode}, not enabled; P5 accepts the full enabled deployment"
  note "**Aborted**: execution mode was \`${mode}\` rather than \`enabled\`."
  mkdir -p "$(dirname "$REPORT")" && printf '%s' "$REPORT_BODY" > "$REPORT"
  summary; exit 1
fi

# ---------- Earlier gates ----------
note "## Gates"
note ""
if [ "$SKIP_GATES" = "1" ]; then
  section "Gates P0 / P1 / P3 / P4"
  skip "--skip-gates, the earlier gates were not run in this acceptance"
  note "Skipped via \`--skip-gates\`; this acceptance rests on an earlier run of those gates."
else
  for gate in p0-genesis p1-shadow p3-enabled p4-user-facing; do
    case "$gate" in
      p0-genesis)     args="" ;;
      p3-enabled)     args="--watch=${WATCH}"; [ "$FB_DRILL" = "1" ] && args="${args} --fallback-drill" ;;
      p4-user-facing) args="--samples=${SAMPLES}" ;;
      *)              args="--watch=${WATCH}" ;;
    esac
    # shellcheck disable=SC2086
    if bash "$VERIFY_DIR/${gate}.sh" $args; then
      pass "gate ${gate}"
      note "- PASS \`${gate}.sh ${args}\`"
    else
      fail "gate ${gate}"
      note "- FAIL \`${gate}.sh ${args}\`"
    fi
  done
fi
note ""

# ---------- Functional scenarios ----------
section "End-to-end scenarios through the user-facing RPC"
note "## End-to-end scenarios"
note ""

# cast only accepts a key through --private-key, so it is visible in `ps` while a
# transaction is built. Use a disposable local test key; never print the value itself.
KEY="${L2_VERIFY_PRIVATE_KEY:-${DEPLOY_PRIVATE_KEY:-}}"
USER_RPC="$FB_RPC"

# Poll for a receipt field instead of letting cast block: `cast receipt` without --async
# waits forever when a transaction never lands, and macOS has no timeout(1) to bound it.
receipt_field() {   # <rpc> <txhash> <field>
  cast receipt "$2" "$3" --rpc-url "$1" --async 2>/dev/null | rg -o '^[0-9a-zA-Zx]+' | head -1
}
wait_receipt_field() {   # <rpc> <txhash> <field> <max-seconds>
  local i=0 value
  while [ "$i" -lt "$4" ]; do
    value=$(receipt_field "$1" "$2" "$3")
    [ -n "$value" ] && { echo "$value"; return 0; }
    sleep 1; i=$((i + 1))
  done
  echo ""
  return 1
}

# Runtime returns the constant 42; the init code copies those 10 bytes out.
#   init:    600a 600c 6000 39 600a 6000 f3   (PUSH len, PUSH offset, PUSH dest, CODECOPY, RETURN)
#   runtime: 602a 6000 52 6020 6000 f3        (MSTORE 42, RETURN 32 bytes)
# A hand-written contract keeps this script free of a Foundry project and a build step.
RETURN42_INITCODE="0x600a600c600039600a6000f3602a60005260206000f3"

if [ -z "$KEY" ]; then
  skip "no test private key, all functional scenarios skipped"
  detail "export L2_VERIFY_PRIVATE_KEY=0x… (a disposable test key funded on L2) and run again."
  note "Skipped: no test private key was provided."
elif ! require_cmd cast; then
  skip "cast is missing, all functional scenarios skipped"
  note "Skipped: cast is not installed."
else
  FROM=$(cast wallet address --private-key "$KEY" 2>/dev/null)
  info "Test account ${FROM}"
  note "Sent through the user-facing RPC \`${USER_RPC}\` from \`${FROM}\`."
  note ""

  # send_tx <description> <cast send args...>; sets TX to the hash or an empty string.
  TX=""
  send_tx() {
    local desc="$1"; shift
    local out
    out=$(cast send "$@" --private-key "$KEY" --rpc-url "$USER_RPC" --async 2>&1 | tail -1)
    case "$out" in
      0x*) TX="$out"; return 0 ;;
      *)   TX=""; warn "${desc}: submission failed: ${out}"; return 1 ;;
    esac
  }

  # check_landed <description> <txhash> <expected-status>; also cross-checks that op-reth
  # and op-geth place the transaction in the same block, which is the whole point of
  # running these through the user-facing path rather than straight at the sequencer.
  check_landed() {
    local desc="$1" tx="$2" want="$3" got blk_geth blk_reth
    got=$(wait_receipt_field "$L2_RPC" "$tx" status 30)
    if [ -z "$got" ]; then
      fail "${desc}: no receipt within 30s (tx=${tx})"
      note "- FAIL ${desc}: no receipt within 30s (\`${tx}\`)"
      return 1
    fi
    blk_geth=$(receipt_field "$L2_RPC" "$tx" blockNumber)
    blk_reth=$(wait_receipt_field "$FB_RPC" "$tx" blockNumber 15)
    if [ "$got" = "$want" ]; then
      pass "${desc}: receipt.status=${got}, block ${blk_geth}"
    else
      fail "${desc}: receipt.status=${got}, expected ${want}"
    fi
    if [ -z "$blk_reth" ]; then
      fail "${desc}: op-reth never produced a receipt, the user-facing view lost the transaction"
      note "- FAIL ${desc}: op-geth block \`${blk_geth}\`, op-reth had no receipt"
    elif [ "$blk_geth" = "$blk_reth" ]; then
      pass "${desc}: op-reth and op-geth agree on block ${blk_geth}"
      note "- PASS ${desc}: status \`${got}\`, block \`${blk_geth}\`, both clients agree"
    else
      fail "${desc}: op-reth says block ${blk_reth} but op-geth says ${blk_geth}"
      note "- FAIL ${desc}: block mismatch, op-geth \`${blk_geth}\` vs op-reth \`${blk_reth}\`"
    fi
    [ "$got" = "$want" ]
  }

  # Scenario 1: plain transfer.
  if send_tx "transfer" "$FROM" --value 1; then
    check_landed "transfer" "$TX" 1
  else
    note "- FAIL transfer: submission failed"
  fi

  # Scenario 2: contract deployment, then a state-changing call and a static read.
  CONTRACT=""
  if send_tx "contract deployment" --create "$RETURN42_INITCODE"; then
    if check_landed "contract deployment" "$TX" 1; then
      CONTRACT=$(receipt_field "$L2_RPC" "$TX" contractAddress)
    fi
  else
    note "- FAIL contract deployment: submission failed"
  fi

  if [ -z "$CONTRACT" ]; then
    skip "no contract address, skipping the contract call scenarios"
  else
    info "Deployed at ${CONTRACT}"
    if send_tx "contract call" "$CONTRACT"; then
      check_landed "contract call" "$TX" 1
    else
      note "- FAIL contract call: submission failed"
    fi

    # Read it back from the user-facing RPC: this proves op-reth applied the deployment to
    # its own state, not merely that it saw the transaction go by.
    ret=$(cast call "$CONTRACT" --rpc-url "$FB_RPC" 2>/dev/null)
    ret_dec=$(cast to-dec "$ret" 2>/dev/null || echo -1)
    assert_eq 42 "$ret_dec" "op-reth returns the contract's constant"
    note "- Static read from op-reth returned \`${ret_dec}\` (expected 42)"
  fi

  # Scenario 3: a reverting transaction must land with status 0 and disturb nothing.
  # The target is the GasPriceOracle predeploy called with a selector it does not have;
  # a Solidity dispatcher with no fallback reverts. --gas-limit is required because
  # estimation would fail on a call that always reverts.
  before_bn=$(rpc_bn "$L2_RPC")
  if send_tx "reverting transaction" 0x420000000000000000000000000000000000000F 0xdeadbeef --gas-limit 100000; then
    check_landed "reverting transaction" "$TX" 0
    sleep 4
    after_bn=$(rpc_bn "$L2_RPC")
    assert_num_ge "$((after_bn - before_bn))" 1 "the chain keeps producing blocks after a reverting transaction"
  else
    detail "Some cast versions estimate gas even with --gas-limit; then this scenario cannot be exercised here."
    note "- WARN reverting transaction: could not be submitted, scenario not exercised"
  fi
fi
note ""

# ---------- Fault-proof non-regression ----------
section "Fault-proof non-regression (${WATCH}s)"
note "## Fault-proof non-regression"
note ""
safe0=$(sync_head "$OPNODE_RPC" safe_l2)
unsafe0=$(sync_head "$OPNODE_RPC" unsafe_l2)
prop0=$(log_count op-proposer 'Proposer tx successfully published')
sleep "$WATCH"
safe1=$(sync_head "$OPNODE_RPC" safe_l2)
unsafe1=$(sync_head "$OPNODE_RPC" unsafe_l2)
prop1=$(log_count op-proposer 'Proposer tx successfully published')

info "safe_l2   ${safe0} -> ${safe1}"
info "unsafe_l2 ${unsafe0} -> ${unsafe1}"
if [ "$safe0" -lt 0 ] || [ "$safe1" -lt 0 ]; then
  fail "cannot read optimism_syncStatus from op-node (${OPNODE_RPC})"
elif [ "$safe1" -gt "$safe0" ]; then
  pass "safe head advanced by $((safe1 - safe0)) blocks"
elif [ "$safe1" -lt "$safe0" ]; then
  fail "safe head went backwards: ${safe0} -> ${safe1}"
else
  warn "safe head did not move in ${WATCH}s (still ${safe1})"
  detail "batcher backlog is $((unsafe1 - safe1)) blocks; a large backlog makes the safe head crawl."
fi
note "- safe_l2 \`${safe0}\` to \`${safe1}\`, unsafe_l2 \`${unsafe0}\` to \`${unsafe1}\`, backlog \`$((unsafe1 - safe1))\` blocks"

if [ "$prop1" -gt "$prop0" ]; then
  pass "proposer published $((prop1 - prop0)) outputs during the window"
else
  warn "proposer published nothing during the window (${prop1} total)"
  detail "The proposal interval can be longer than ${WATCH}s; only worry if this stays at zero over several runs."
fi
note "- proposer submissions during the window: \`$((prop1 - prop0))\` (\`${prop1}\` total)"

check_component_errors() {   # <log-name> <regex> <label>
  local n; n=$(log_count "$1" "$2")
  if [ "$n" -eq 0 ]; then
    pass "$3 has no errors"
  else
    warn "$3 has ${n} error entries; see data/logs/${1}.log"
  fi
  note "- $3 error entries: \`${n}\`"
}
check_component_errors op-batcher    '\bERROR\b|lvl=eror|lvl=crit' "batcher"
check_component_errors op-proposer   '\bERROR\b|lvl=eror|lvl=crit' "proposer"
check_component_errors op-challenger '\bERROR\b|lvl=eror|lvl=crit' "challenger"
note ""

# ---------- Hard-rollback drill ----------
if [ "$OFF_DRILL" = "1" ]; then
  section "Hard-rollback drill: restart the chain in off mode"
  warn "This stops the whole chain and restarts it twice; it takes at least ten minutes"
  detail "op-node restarts are bounded by the channel_timeout safety window ([9] in doc section 7)."
  detail "If that window has not opened, op-node exits with 'unknown batch validity type' and the chain stays down."
  if [ "$ASSUME_YES" != "1" ]; then
    if [ -t 0 ]; then
      printf "  Type 'yes' to run the drill: "
      read -r reply
      [ "$reply" = "yes" ] || { skip "drill declined"; OFF_DRILL=0; }
    else
      skip "--restart-off-drill needs --yes when stdin is not a terminal"
      OFF_DRILL=0
    fi
  fi
fi

if [ "$OFF_DRILL" = "1" ]; then
  note "## Hard-rollback drill"
  note ""
  # No attempt to auto-heal from a trap: a chain caught halfway through a restart needs a
  # human decision, and a trap that starts components behind the operator's back is worse
  # than a clear message about where things stopped.
  drill_state() {
    echo ""
    echo "  ${C_YEL}Drill state: .envrc FLASHBLOCKS_MODE is now $(rg -o '^export FLASHBLOCKS_MODE=(.*)$' -r '$1' .envrc | head -1)${C_OFF}"
    echo "  ${C_YEL}Recover by hand: set the mode you want in .envrc, then chain-stop.sh && chain-start.sh local${C_OFF}"
  }
  trap 'drill_state' EXIT

  head0=$(rpc_bn "$L2_RPC")
  info "Head before the drill: ${head0}"

  bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh" >/dev/null 2>&1
  set_envrc_mode off
  info "Switched .envrc to off, starting the chain again"
  bash "$BASE_PATH/scripts/chain-ops/chain-start.sh" local >/dev/null 2>&1
  sleep 20

  off_head0=$(rpc_bn "$L2_RPC")
  sleep 10
  off_head1=$(rpc_bn "$L2_RPC")
  info "In off mode: ${off_head0} -> ${off_head1}"
  assert_num_ge "$((off_head1 - off_head0))" 1 "the chain produces blocks in off mode"
  assert_num_ge "$off_head0" "$head0" "no blocks were lost across the restart"
  assert_eq "none" "$(boost_mode)" "rollup-boost is not running in off mode"
  if pgrep -x op-node >/dev/null 2>&1; then
    pass "op-node is running and driving op-geth directly"
  else
    fail "op-node is not running; the off-mode chain did not come up"
  fi
  note "- off mode: head \`${off_head0}\` to \`${off_head1}\`, rollup-boost stopped"

  info "Restoring enabled mode"
  bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh" >/dev/null 2>&1
  set_envrc_mode enabled
  bash "$BASE_PATH/scripts/chain-ops/chain-start.sh" local >/dev/null 2>&1
  sleep 30

  back_mode=$(boost_mode)
  assert_eq "enabled" "$back_mode" "rollup-boost is back in enabled mode"
  b0=$(rpc_bn "$L2_RPC"); sleep 10; b1=$(rpc_bn "$L2_RPC")
  info "After restoring: ${b0} -> ${b1}"
  assert_num_ge "$((b1 - b0))" 1 "the chain produces blocks again after restoring enabled"
  note "- restored: mode \`${back_mode}\`, head \`${b0}\` to \`${b1}\`"
  note ""
  detail "op-rbuilder resumed from its warm datadir. Rerun p3-enabled.sh to confirm builder blocks are landing again."

  trap - EXIT
fi

# ---------- Report ----------
note "## Result"
note ""
note "- PASS \`${PASS_N}\`, FAIL \`${FAIL_N}\`, WARN \`${WARN_N}\`, SKIP \`${SKIP_N}\`"
if [ "$FAIL_N" -gt 0 ]; then
  note "- Verdict: **not accepted**"
  note "$FAILED_ITEMS"
else
  note "- Verdict: **accepted**"
fi
note ""
note "Out of scope in this run: deposits and withdrawals, CGT gas accounting"
note "(scripts/jovian/verify-jovian-fees.sh), and L1 origin rotation."

mkdir -p "$(dirname "$REPORT")"
printf '%s' "$REPORT_BODY" > "$REPORT"
section "Report"
info "Written to ${REPORT}"

summary
