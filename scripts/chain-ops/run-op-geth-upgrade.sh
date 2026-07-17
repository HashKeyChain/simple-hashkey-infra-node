#!/bin/bash

# This script starts op-geth with Granite, Isthmus, and Jovian hardfork overrides
# Use this after upgrading rollup.json with run-op-node-upgrade.sh

source .envrc

echo "============================================"
echo "  op-geth Upgrade to Jovian"
echo "============================================"

# Read hardfork times from rollup.json
ROLLUP_JSON=$OP_NODE_ROLLUP_FILE
if [ ! -f "$ROLLUP_JSON" ]; then
  echo "Error: rollup.json not found at $ROLLUP_JSON"
  exit 1
fi

GRANITE_TIME=$(jq -r '.granite_time // empty' $ROLLUP_JSON)
HOLOCENE_TIME=$(jq -r '.holocene_time // empty' $ROLLUP_JSON)
ISTHMUS_TIME=$(jq -r '.isthmus_time // empty' $ROLLUP_JSON)
JOVIAN_TIME=$(jq -r '.jovian_time // empty' $ROLLUP_JSON)

echo "Reading hardfork times from rollup.json:"
echo "  granite_time: $GRANITE_TIME"
echo "  holocene_time: $HOLOCENE_TIME"
echo "  isthmus_time: $ISTHMUS_TIME"
echo "  jovian_time: $JOVIAN_TIME"

# Build override flags
OVERRIDE_FLAGS=""
if [ -n "$GRANITE_TIME" ]; then
  OVERRIDE_FLAGS="$OVERRIDE_FLAGS --override.granite=$GRANITE_TIME"
fi
if [ -n "$HOLOCENE_TIME" ]; then
  OVERRIDE_FLAGS="$OVERRIDE_FLAGS --override.holocene=$HOLOCENE_TIME"
fi
if [ -n "$ISTHMUS_TIME" ]; then
  OVERRIDE_FLAGS="$OVERRIDE_FLAGS --override.isthmus=$ISTHMUS_TIME"
fi
if [ -n "$JOVIAN_TIME" ]; then
  OVERRIDE_FLAGS="$OVERRIDE_FLAGS --override.jovian=$JOVIAN_TIME"
fi

echo ""
echo "Override flags: $OVERRIDE_FLAGS"

export OP_GETH_DATA_PATH=$BASE_PATH/data/op-geth

# Check if data directory exists (don't reinit if it does)
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo ""
  echo "Initializing op-geth datadir..."
  init_flags="--state.scheme=hash --datadir=${OP_GETH_DATA_PATH} $OP_GETH_GENESIS_FILE"
  echo "op-geth init $init_flags"
  op-geth init $init_flags
else
  echo ""
  echo "op-geth datadir already exists, skipping init"
fi

# Start op-geth with hardfork overrides
echo ""
echo "============================================"
echo "  Starting op-geth with Jovian enabled"
echo "============================================"

base_flags="--verbosity=3 --datadir=${OP_GETH_DATA_PATH} --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner"
geth_flags="--syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=${OP_GETH_DATA_PATH}/jwt.txt --state.scheme=hash"
flags="$base_flags $geth_flags $OVERRIDE_FLAGS"

echo "op-geth $flags"
op-geth $flags
