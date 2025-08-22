#!/bin/bash

source .envrc

echo "Starting op-batcher ..."

base_flags="--log.level=debug --l1-eth-rpc=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rpc.port=$OP_BATCHER_PORT --rollup-rpc=$OP_NODE_RPC_URL --private-key=${GS_BATCHER_PRIVATE_KEY}"

misc_flags="--rpc.enable-admin --network-timeout=600s --num-confirmations=1 --safe-abort-nonce-too-low-count=${SAFE_ABORT_NONCE_TOO_LOW_COUNT:-3}"

proposer_flags="--max-channel-duration=${MAX_CHANNEL_DURATION:-300} --poll-interval=${POLL_INTERVAL:-6s} --sub-safety-margin=${SUB_SAFETY_MARGIN:-10} --resubmission-timeout=${RESUBMISSION_TIMEOUT:-48s} --max-l1-tx-size-bytes=${MAX_L1_TX_SIZE_BYTES:-1000}"

txmgr_flags="--txmgr.max-retries=${OP_PROPOSER_TXMGR_MAX_RETRIES:-2}"

flags="$base_flags $proposer_flags $txmgr_flags $misc_flags"

echo "op-batcher  ${flags}"

op-batcher $flags
