#!/bin/bash

source .envrc

echo "Starting op-batcher ..."
echo "op-batcher --l1-eth-rpc=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rpc.port=$OP_BATCHER_PORT --rollup-rpc=http://localhost:$OP_BATCHER_PORT --private-key=${GS_BATCHER_PRIVATE_KEY}"

op-batcher \
  --l1-eth-rpc=$L1_RPC_URL \
  --l2-eth-rpc=$L2_RPC_URL \
  --rollup-rpc=$OP_NODE_RPC_URL \
  --private-key=${GS_BATCHER_PRIVATE_KEY} \
  --rpc.port=$OP_BATCHER_PORT \
  --max-channel-duration=${BATCHER_MAX_CHANNEL_DURATION:-300} \
  --poll-interval=${BATCHER_POLL_INTERVAL:-6s} \
  --sub-safety-margin=${BATCHER_SUB_SAFETY_MARGIN:-10} \
  --num-confirmations=${BATCHER_NUM_CONFIRMATIONS:-10} \
  --safe-abort-nonce-too-low-count=${BATCHER_SAFE_ABORT_NONCE_TOO_LOW_COUNT:-3} \
  --resubmission-timeout=${BATCHER_RESUBMISSION_TIMEOUT:-48s} \
  --rpc.enable-admin
