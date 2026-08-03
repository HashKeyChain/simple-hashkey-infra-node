#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# Helper function to fetch and checkout a ref (works with shallow clones)
fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin $ref 2>/dev/null || git fetch --depth 1 origin tag $ref 2>/dev/null || true
  git checkout $ref
}

# build op-geth
cd $BASE_PATH/op-geth
fetch_and_checkout $OP_GETH_REF
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $BASE_PATH/optimism
fetch_and_checkout $OP_NODE_REF
make op-node
cp $BASE_PATH/optimism/op-node/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/optimism
fetch_and_checkout $OP_PROPOSER_REF
make op-proposer
cp $BASE_PATH/optimism/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/optimism
fetch_and_checkout $OP_BATCHER_REF
make op-batcher
cp $BASE_PATH/optimism/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/optimism
fetch_and_checkout $OP_CHALLENGER_REF
make op-challenger
cp $BASE_PATH/optimism/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

# # build op-deployer
# cd $BASE_PATH/optimism
# fetch_and_checkout $OP_DEPLOYER_REF
# just op-deployer
# cp $BASE_PATH/optimism/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer

# ---------- Fault-proof components (built only when USE_FAULT_PROOFS=true) ----------
# Running cannon through op-challenger requires the cannon binary, op-program (host oracle server), and absolute prestate.
# Build the prestate reproducibly with Docker to ensure its .pre value can be reproduced. It must equal
# faultGameAbsolutePrestate in deploy-config for the challenger to participate in deployed dispute games.
# CANNON_REF/OP_PROGRAM_REF use the same source commit as OP_CONTRACTS_REF (see .envrc).
if [ "${USE_FAULT_PROOFS:-false}" = "true" ]; then
  # Build cannon (--cannon-bin).
  cd $BASE_PATH/optimism
  fetch_and_checkout $CANNON_REF
  make cannon
  cp $BASE_PATH/optimism/cannon/bin/cannon $BASE_PATH/bin/cannon

  # Build a reproducible prestate with Docker. Outputs are written to optimism/op-program/bin/:
  #   op-program (host), op-program-client.elf, prestate.json, and prestate-proof.json
  cd $BASE_PATH/optimism
  fetch_and_checkout $OP_PROGRAM_REF
  make -C op-program reproducible-prestate
  cp $BASE_PATH/optimism/op-program/bin/op-program $BASE_PATH/bin/op-program
  cp $BASE_PATH/optimism/op-program/bin/prestate.json $BASE_PATH/bin/prestate.json
  cp $BASE_PATH/optimism/op-program/bin/prestate-proof.json $BASE_PATH/bin/prestate-proof.json

  echo "Fault-proof binaries built."
  echo "  Absolute prestate (.pre): $(jq -r .pre $BASE_PATH/bin/prestate-proof.json)"
  echo "  This must equal faultGameAbsolutePrestate in deploy-config, or the challenger cannot participate in deployed games."
fi

# macOS: force a fresh ad hoc signature on newly created binaries.
# The Go linker gives outputs an ad hoc (linker-signed) signature, but on some macOS/Apple Silicon systems,
# the first exec can hang during kernel page verification (process STAT=UNE, even --version never returns,
# and SIGQUIT produces no stack). Re-signing with codesign resolves the issue and is an idempotent, harmless
# operation for binaries that already run. Skip this on Linux, where codesign is unavailable.
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  for b in op-geth op-node op-proposer op-batcher op-challenger cannon op-program; do
    [ -f "$BASE_PATH/bin/$b" ] && codesign -f -s - "$BASE_PATH/bin/$b" >/dev/null 2>&1 || true
  done
  echo "Re-signed binaries (adhoc) for macOS."
fi

# ---------- Flashblocks Rust components (only when FLASHBLOCKS_MODE != off) ----------
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  bash "$BASE_PATH/scripts/flashblocks/build-flashblocks.sh"
fi

# return base path
cd $BASE_PATH
