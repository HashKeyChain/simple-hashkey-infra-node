#!/bin/bash
#
# Component-only launcher: starts op-proposer with the correct flags (the single source of truth for this component's flags).
# Orchestrated by chain-start.sh; it can also be run independently for debugging or restarts.
#
# Prerequisites for standalone use: op-node is serving the rollup RPC and contracts are deployed (artifact.json is ready).
# Note: deployment seeds AnchorStateRegistry with a nonzero faultGameGenesisOutputRoot (0xdead...),
#       so the proposer can create its first game without separate anchor initialization.
#

source .envrc

# Allow the chain-start orchestration layer to override values via _CALLER_*; fall back to .envrc when run independently.
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
# Always read artifact.json from config/<context>/ (the canonical, Git-tracked configuration patched by the runbook),
# rather than the raw build output under optimism/.../deployments/ referenced by .envrc by default.
DEPLOYMENT_OUTFILE="${_CALLER_DEPLOYMENT_OUTFILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/artifact.json}"

base_flags="--log.level=debug --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL"

proposer_flags=""
if [ "$USE_FAULT_PROOFS" = "true" ]; then
  # GAME_TYPE defaults to 1 (PERMISSIONED_CANNON), starting in permissioned mode to match respectedGameType at deployment.
  proposer_flags="--game-factory-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .DisputeGameFactoryProxy) --proposal-interval=${PROPOSAL_INTERVAL:-30s} --game-type=${GAME_TYPE:-1}"
else
  proposer_flags="--l2oo-address=$(cat $DEPLOYMENT_OUTFILE | jq -r .L2OutputOracleProxy)"
fi

misc_flags="--poll-interval=30s --network-timeout=600s --num-confirmations=1 --wait-node-sync=${WAIT_NODE_SYNC:-true}"
flags="$base_flags $proposer_flags $misc_flags"

echo "Starting op-proposer ..."
echo "op-proposer $flags"

exec op-proposer $flags
