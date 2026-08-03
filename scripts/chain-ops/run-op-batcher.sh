#!/bin/bash
#
# Component-only launcher: starts op-batcher with the correct flags (the single source of truth for this component's flags).
# Orchestrated by chain-start.sh; it can also be run independently for debugging or restarts.
#
# Prerequisites for standalone use: op-node is serving the rollup RPC at $OP_NODE_RPC_URL and L2 is producing blocks.
#

source .envrc

# Allow the chain-start orchestration layer to override values via _CALLER_*; fall back to .envrc when run independently.
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"

echo "Starting op-batcher ..."

base_flags="--log.level=debug --l1-eth-rpc=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rpc.port=$OP_BATCHER_PORT --rollup-rpc=$OP_NODE_RPC_URL --private-key=${GS_BATCHER_PRIVATE_KEY}"

batcher_flags="--max-channel-duration=${MAX_CHANNEL_DURATION:-300} --poll-interval=${POLL_INTERVAL:-6s} --sub-safety-margin=${SUB_SAFETY_MARGIN:-10} --resubmission-timeout=${RESUBMISSION_TIMEOUT:-48s} --max-l1-tx-size-bytes=${MAX_L1_TX_SIZE_BYTES:-1000} --data-availability-type=${OP_BATCHER_DATA_AVAILABILITY_TYPE:-calldata}"

txmgr_flags="--txmgr.max-retries=${OP_PROPOSER_TXMGR_MAX_RETRIES:-2}"

misc_flags="--rpc.enable-admin --network-timeout=600s --num-confirmations=1 --safe-abort-nonce-too-low-count=${SAFE_ABORT_NONCE_TOO_LOW_COUNT:-3}"

flags="$base_flags $batcher_flags $txmgr_flags $misc_flags"

echo "op-batcher ${flags}"

exec op-batcher $flags
