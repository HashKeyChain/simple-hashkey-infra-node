#!/bin/bash

source .envrc

rm -rf $BASE_PATH/data
mkdir -p $BASE_PATH/data/verse-challenger

# Deploy Optimism genesis contracts.
sh scripts/deploy-contracts.sh

# Init l2geth datadir.
export VERSE_GETH_PATH=$BASE_PATH/data/verse-geth
init_flags="--state.scheme=hash --datadir=${VERSE_GETH_PATH} $OP_GETH_GENESIS_FILE"
echo "op-geth init $init_flags"
op-geth init $init_flags

# Init the anchor state before starting challenger.
if [ "$USE_FAULT_PROOFS" = "true" ]; then
  sh scripts/set-anchorState.sh
fi