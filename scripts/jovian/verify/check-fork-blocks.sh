#!/usr/bin/env bash
set -uo pipefail

# Locate each fork's activation block (the first block whose timestamp is at
# least the fork time) and check every transaction receipt in the surrounding blocks.
#
# Usage: bash scripts/jovian/verify/check-fork-blocks.sh [window_blocks]
#   window_blocks: number of blocks to check before and after activation (default: 3)

RPC="${L2_RPC:-https://mainnet.hsk.xyz}"
WINDOW="${1:-3}"

declare -a FORKS=(
  "holocene:1785306600"
  "isthmus:1785306900"
  "prague:1785306900"
  "jovian:1785307200"
)

bn_ts() { cast block "$1" -f timestamp --rpc-url "$RPC" 2>/dev/null; }

# Binary-search for the first block whose timestamp is >= $1
find_activation_block() {
  local target="$1" lo=1 hi mid ts
  hi=$(cast bn --rpc-url "$RPC")
  while [ "$lo" -lt "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    ts=$(bn_ts "$mid")
    if [ -z "$ts" ]; then echo ""; return 1; fi
    if [ "$ts" -lt "$target" ]; then lo=$(( mid + 1 )); else hi="$mid"; fi
  done
  echo "$lo"
}

# Check the receipt status of every transaction in one block
check_block_receipts() {
  local n="$1" label="$2"
  local blk txs count ok=0 fail=0 hash ts
  blk=$(cast block "$n" --rpc-url "$RPC" --json)
  ts=$(echo "$blk" | jq -r '.timestamp' | xargs -I{} cast to-dec {})
  hash=$(echo "$blk" | jq -r '.hash')
  txs=$(echo "$blk" | jq -r '.transactions[]?')
  count=$(echo "$blk" | jq -r '.transactions | length')

  printf '  block %-10s ts=%s txs=%-3s %s\n' "$n" "$ts" "$count" "$label"
  [ "$count" = "0" ] && return 0

  for tx in $txs; do
    local rcpt status ttype
    rcpt=$(cast receipt "$tx" --rpc-url "$RPC" --json 2>/dev/null)
    status=$(echo "$rcpt" | jq -r '.status')
    ttype=$(echo "$rcpt" | jq -r '.type')
    if [ "$status" = "0x1" ]; then
      ok=$(( ok + 1 ))
    else
      fail=$(( fail + 1 ))
      echo "      FAILED tx=$tx type=$ttype status=$status"
    fi
  done
  printf '      receipts: success=%s failed=%s\n' "$ok" "$fail"
  [ "$fail" -gt 0 ] && return 1
  return 0
}

echo "RPC: $RPC   head=$(cast bn --rpc-url "$RPC")   now=$(date -u +%s)"
echo ""

TOTAL_FAIL=0
for entry in "${FORKS[@]}"; do
  name="${entry%%:*}"; t="${entry##*:}"
  echo "=== $name (forkTime=$t) ==="
  act=$(find_activation_block "$t")
  if [ -z "$act" ]; then echo "  Unable to locate activation block"; continue; fi
  prev_ts=$(bn_ts $(( act - 1 )))
  echo "  Activation block = $act   (previous block #$(( act - 1 )) ts=$prev_ts < $t <= activation block ts)"
  for (( i = act - WINDOW; i <= act + WINDOW; i++ )); do
    lbl=""
    [ "$i" = "$act" ] && lbl="<<< ACTIVATION"
    check_block_receipts "$i" "$lbl" || TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
  done
  echo ""
done

echo "============================"
if [ "$TOTAL_FAIL" = "0" ]; then
  echo "Result: all transaction receipts in the checked blocks have successful status (0x1)"
else
  echo "Result: $TOTAL_FAIL blocks contain failed transactions; see the FAILED lines above"
fi
