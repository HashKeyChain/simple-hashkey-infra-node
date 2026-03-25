#!/bin/bash

# 若由 upgrade-to-fault-proofs 等脚本调用且已设置，不要被 .envrc 覆盖
_CALLER_DEPLOYMENT_OUTFILE="${DEPLOYMENT_OUTFILE:-}"
_CALLER_DEPLOY_CONFIG_PATH="${DEPLOY_CONFIG_PATH:-}"
source .envrc
[ -n "$_CALLER_DEPLOYMENT_OUTFILE" ] && export DEPLOYMENT_OUTFILE="$_CALLER_DEPLOYMENT_OUTFILE"
[ -n "$_CALLER_DEPLOY_CONFIG_PATH" ] && export DEPLOY_CONFIG_PATH="$_CALLER_DEPLOY_CONFIG_PATH"

echo "Checking AnchorStateRegistry initialization..."
echo "  DEPLOYMENT_OUTFILE=$DEPLOYMENT_OUTFILE"
echo "  DEPLOY_CONFIG_PATH=$DEPLOY_CONFIG_PATH"

# Check if already initialized.
ANCHOR_PROXY=$(jq -r .AnchorStateRegistryProxy "$DEPLOYMENT_OUTFILE")
superchainConfig=$(cast call --rpc-url "$L1_RPC_URL" "$ANCHOR_PROXY" "superchainConfig()(address)" 2>/dev/null || echo "0x0000000000000000000000000000000000000000")
if [ "$superchainConfig" != "0x0000000000000000000000000000000000000000" ]; then
  echo "AnchorStateRegistry already initialized, skipping."
  exit 0
fi

# Get L2 output root from op-node.
blockNumber=$(jq -r '.faultGameGenesisBlock // 0' "$DEPLOY_CONFIG_PATH")
faultGameGenesisBlock=$(printf '0x%x' "$blockNumber")
echo "Fetching output root at L2 block $blockNumber from op-node ($OP_NODE_RPC_URL)..."
result=$(curl -sf "$OP_NODE_RPC_URL" -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_outputAtBlock\",\"params\":[\"${faultGameGenesisBlock}\"],\"id\":67}")
FAULT_GAME_GENESIS_OUTPUT_ROOT=$(echo "$result" | jq -r '.result.outputRoot // empty')

if [ -z "$FAULT_GAME_GENESIS_OUTPUT_ROOT" ]; then
  echo "Error: failed to get output root from op-node."
  echo "  Response: $result"
  exit 1
fi
echo "faultGameGenesisOutputRoot: $FAULT_GAME_GENESIS_OUTPUT_ROOT"

# Update deploy config with the output root (instead of calling config.sh which
# would overwrite our custom fields and use unsupported 'finalized' tag on Anvil).
jq --arg root "$FAULT_GAME_GENESIS_OUTPUT_ROOT" \
  '.faultGameGenesisOutputRoot = $root' \
  "$DEPLOY_CONFIG_PATH" > "$DEPLOY_CONFIG_PATH.tmp" \
  && mv "$DEPLOY_CONFIG_PATH.tmp" "$DEPLOY_CONFIG_PATH"
echo "Updated faultGameGenesisOutputRoot in deploy config."

cd "$CONTRACTS_BEDROCK_PATH"

export CONTRACT_ADDRESSES_PATH="$DEPLOYMENT_OUTFILE"
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "initializeAnchorStateRegistry()" \
  --skip-simulation

cp "$DEPLOY_CONFIG_PATH" "$DEPLOYMENT_CONFIG_PATH" 2>/dev/null || true

cd "$BASE_PATH"
