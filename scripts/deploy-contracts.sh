#!/bin/bash
set -e

# Preserve caller's env vars before .envrc overwrites them (e.g. local uses localhost L1)
_CALLER_L1_RPC="${L1_RPC_URL:-}"
_CALLER_DEPLOYMENT_CONTEXT="${DEPLOYMENT_CONTEXT:-}"
_CALLER_CHAIN_ENV="${CHAIN_ENV:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"
if [ -n "$_CALLER_DEPLOYMENT_CONTEXT" ]; then
  export DEPLOYMENT_CONTEXT="$_CALLER_DEPLOYMENT_CONTEXT"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
  export DEPLOY_CONFIG_PATH="$CONTRACTS_BEDROCK_PATH/deploy-config/$DEPLOYMENT_CONTEXT.json"
fi
CHAIN_ENV="${_CALLER_CHAIN_ENV:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
fi

mkdir -p $DEPLOYMENT_CONFIG_PATH

_rpc_call() {
  curl -sf -X POST -H "Content-Type: application/json" \
    --connect-timeout 3 --max-time 10 \
    --data "$1" "$L1_RPC_URL"
}

# Build and deploy contracts.
cd $CONTRACTS_BEDROCK_PATH

if [ "${SKIP_GIT_CHECKOUT:-0}" != "1" ]; then
  # Remove lib dirs that often cause "unable to rmdir ... Directory not empty" on checkout;
  # forge install below will reinstall the correct versions for this ref.
  rm -rf lib/openzeppelin-contracts-v5 lib/solady-v0.0.245 lib/superchain-registry 2>/dev/null || true
  git checkout $OP_CONTRACTS_REF
else
  echo "SKIP_GIT_CHECKOUT=1, keeping current contract source (including local modifications)."
fi

# Check deployer account balances
ADMIN_ACTUAL=$(cast wallet address --private-key "$GS_ADMIN_PRIVATE_KEY" 2>/dev/null || true)
DEPLOY_ACTUAL=$(cast wallet address --private-key "$DEPLOY_PRIVATE_KEY" 2>/dev/null || true)

_check_balance() {
  local addr="$1" name="$2"
  [ -z "$addr" ] && return
  local bal=$(_rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" | jq -r '.result // "0x0"')
  local bal_dec=$(printf '%d' "$bal" 2>/dev/null || echo 0)
  local bal_eth=$(echo "scale=4; $bal_dec / 1000000000000000000" | bc 2>/dev/null || echo "?")
  if [ "$bal_dec" -lt 1000000000000000000 ] 2>/dev/null; then
    return 1
  fi
  echo "  $name ($addr): ${bal_eth} ETH"
  return 0
}

if [ "$CHAIN_ENV" = "local" ]; then
  # local: auto-fund via anvil_setBalance
  _fund_if_needed() {
    local addr="$1"
    [ -z "$addr" ] && return
    local bal=$(_rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$addr\",\"latest\"],\"id\":1}" | jq -r '.result // "0x0"')
    local bal_dec=$(printf '%d' "$bal" 2>/dev/null || echo 0)
    if [ "$bal_dec" -lt 1000000000000000000 ] 2>/dev/null; then
      echo "Funding $addr with 100 ETH (anvil)..."
      _rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setBalance\",\"params\":[\"$addr\",\"0x56BC75E2D63100000\"],\"id\":1}" > /dev/null
    fi
  }
  for addr in "$DEPLOY_ADDRESS" "$GS_ADMIN_ADDRESS" "$ADMIN_ACTUAL" "$DEPLOY_ACTUAL" \
              "$GS_BATCHER_ADDRESS" "$GS_PROPOSER_ADDRESS" "$GS_SEQUENCER_ADDRESS"; do
    _fund_if_needed "$addr"
  done
else
  # server: check balances, prompt user to fund if insufficient
  echo "Checking account balances on L1..."
  BALANCE_OK=true
  for pair in "Admin:$GS_ADMIN_ADDRESS" "Deploy:$DEPLOY_ADDRESS" "Batcher:$GS_BATCHER_ADDRESS" "Proposer:$GS_PROPOSER_ADDRESS" "Sequencer:$GS_SEQUENCER_ADDRESS"; do
    name="${pair%%:*}"
    addr="${pair#*:}"
    if ! _check_balance "$addr" "$name"; then
      echo "  WARNING: $name ($addr) has insufficient balance (< 1 ETH)"
      BALANCE_OK=false
    fi
  done
  if [ "$BALANCE_OK" = "false" ]; then
    echo ""
    echo "Some accounts have insufficient balance. Fund them on L1 ($L1_RPC_URL) before proceeding."
    echo "At minimum, Admin and Deploy accounts need ETH for contract deployment."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
fi

# If using a custom gas token and address is not set, deploy it first.
# Mint 10000 HSK (custom gas token) to deployer address.
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
if [ "${USE_CUSTOM_GAS_TOKEN}" = "true" ]; then
  NEED_DEPLOY_CGT=false
  if [ -z "$CUSTOM_GAS_TOKEN_ADDRESS" ] || [ "$CUSTOM_GAS_TOKEN_ADDRESS" = "$ZERO_ADDRESS" ]; then
    NEED_DEPLOY_CGT=true
  else
    # Verify contract code exists at existing address (may be gone after anvil restart)
    CGT_CODE=$(_rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$CUSTOM_GAS_TOKEN_ADDRESS\",\"latest\"],\"id\":1}" | jq -r '.result // "0x"')
    if [ "$CGT_CODE" = "0x" ] || [ -z "$CGT_CODE" ]; then
      echo "Custom gas token at $CUSTOM_GAS_TOKEN_ADDRESS has no code on L1, re-deploying..."
      NEED_DEPLOY_CGT=true
    fi
  fi
  if [ "$NEED_DEPLOY_CGT" = "true" ]; then
    echo "Deploying custom gas token..."
    deploy_result=$(forge create --broadcast --json --rpc-url $L1_RPC_URL --private-key $DEPLOY_PRIVATE_KEY lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol:ERC20Mock --constructor-args "hashkeyToken" "HSK" $DEPLOY_ADDRESS 10000000000000000000000)
    CUSTOM_GAS_TOKEN_ADDRESS=$(echo $deploy_result | jq -r .deployedTo)
    echo "Custom gas token deployed at: $CUSTOM_GAS_TOKEN_ADDRESS"
    sed -i.bak "s/^export CUSTOM_GAS_TOKEN_ADDRESS=.*/export CUSTOM_GAS_TOKEN_ADDRESS=${CUSTOM_GAS_TOKEN_ADDRESS}/" "$BASE_PATH/.envrc" && rm -f "$BASE_PATH/.envrc.bak"
  else
    echo "Using existing custom gas token at: $CUSTOM_GAS_TOKEN_ADDRESS"
  fi
fi

# Init deployment config.
L1_BLOCK_JSON=$(_rpc_call '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}')
L1_START_HASH=$(echo "$L1_BLOCK_JSON" | jq -r '.result.hash')
L1_START_TS_HEX=$(echo "$L1_BLOCK_JSON" | jq -r '.result.timestamp')
L1_START_TS=$(printf '%d' "$L1_START_TS_HEX" 2>/dev/null || echo 0)
if [ -z "$L1_START_HASH" ] || [ "$L1_START_HASH" = "null" ]; then
  echo "Error: cannot fetch latest L1 block from $L1_RPC_URL"
  exit 1
fi
echo "L1 latest block: hash=$L1_START_HASH timestamp=$L1_START_TS"
# Generate deploy config (equivalent to config.sh but using "latest" instead of "finalized")
cat > "$DEPLOY_CONFIG_PATH" <<EOCFG
{
  "l1StartingBlockTag": "$L1_START_HASH",
  "l1ChainID": $L1_CHAIN_ID,
  "l2ChainID": $L2_CHAIN_ID,
  "l2BlockTime": $L2_BLOCK_TIME,
  "l1BlockTime": $L1_BLOCK_TIME,
  "maxSequencerDrift": 600,
  "sequencerWindowSize": 3600,
  "channelTimeout": 300,
  "p2pSequencerAddress": "$GS_SEQUENCER_ADDRESS",
  "batchInboxAddress": "0xff00000000000000000000000000000000042069",
  "batchSenderAddress": "$GS_BATCHER_ADDRESS",
  "l2OutputOracleSubmissionInterval": 120,
  "l2OutputOracleStartingBlockNumber": 0,
  "l2OutputOracleStartingTimestamp": $L1_START_TS,
  "l2OutputOracleProposer": "$GS_PROPOSER_ADDRESS",
  "l2OutputOracleChallenger": "$GS_ADMIN_ADDRESS",
  "finalizationPeriodSeconds": 12,
  "proxyAdminOwner": "$GS_ADMIN_ADDRESS",
  "baseFeeVaultRecipient": "$GS_ADMIN_ADDRESS",
  "l1FeeVaultRecipient": "$GS_ADMIN_ADDRESS",
  "sequencerFeeVaultRecipient": "$GS_ADMIN_ADDRESS",
  "finalSystemOwner": "$GS_ADMIN_ADDRESS",
  "superchainConfigGuardian": "$GS_ADMIN_ADDRESS",
  "baseFeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
  "l1FeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
  "sequencerFeeVaultMinimumWithdrawalAmount": "0x8ac7230489e80000",
  "baseFeeVaultWithdrawalNetwork": 0,
  "l1FeeVaultWithdrawalNetwork": 0,
  "sequencerFeeVaultWithdrawalNetwork": 0,
  "gasPriceOracleOverhead": 0,
  "gasPriceOracleScalar": 1000000,
  "enableGovernance": true,
  "governanceTokenSymbol": "OP",
  "governanceTokenName": "Optimism",
  "governanceTokenOwner": "$GS_ADMIN_ADDRESS",
  "l2GenesisBlockGasLimit": "0x1c9c380",
  "l2GenesisBlockBaseFeePerGas": "0x3b9aca00",
  "l2GenesisRegolithTimeOffset": "0x0",
  "eip1559Denominator": 50,
  "eip1559DenominatorCanyon": 250,
  "eip1559Elasticity": 6,
  "l2GenesisEcotoneTimeOffset": "0x0",
  "l2GenesisDeltaTimeOffset": "0x0",
  "l2GenesisCanyonTimeOffset": "0x0",
  "systemConfigStartBlock": 0,
  "requiredProtocolVersion": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "recommendedProtocolVersion": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "faultGameAbsolutePrestate": "0x03c7ae758795765c6664a5d39bf63841c71ff191e9189522bad8ebff5d4eca98",
  "faultGameMaxDepth": 44,
  "faultGameClockExtension": 0,
  "faultGameMaxClockDuration": 600,
  "faultGameGenesisBlock": 0,
  "faultGameGenesisOutputRoot": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "faultGameSplitDepth": 14,
  "faultGameWithdrawalDelay": 604800,
  "preimageOracleMinProposalSize": 1800000,
  "preimageOracleChallengePeriod": 86400
}
EOCFG
echo "Generated deploy config at $DEPLOY_CONFIG_PATH (L1 block: $L1_START_HASH)"

# Add custom gas token and fault proofs config to deploy config
echo "Adding custom gas token and fault proofs config..."
jq --arg use_cgt "$USE_CUSTOM_GAS_TOKEN" \
   --arg cgt_addr "$CUSTOM_GAS_TOKEN_ADDRESS" \
   --arg use_fp "$USE_FAULT_PROOFS" \
   '. + {
     "useCustomGasToken": ($use_cgt == "true"),
     "customGasTokenAddress": $cgt_addr,
     "useFaultProofs": ($use_fp == "true")
   }' $DEPLOY_CONFIG_PATH > tmp.json && mv tmp.json $DEPLOY_CONFIG_PATH

echo "Deploy config updated:"
echo "  - Custom gas token: $USE_CUSTOM_GAS_TOKEN"
echo "  - Custom gas token address: $CUSTOM_GAS_TOKEN_ADDRESS"
echo "  - Fault proofs: $USE_FAULT_PROOFS"

# Build and deploy contracts.
# forge install uses git clone/submodule internally; may show little output for a while
echo "Installing Forge dependencies (may take 2-5 min, git may have little output)..."
forge install
echo "Dependencies OK. Building..."
forge build --silent
echo "Deploying contracts..."
forge script scripts/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --batch-size 10

# Create l2chain genesis state and load in file.
export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()'

# Init rollup config and genesis file.
# Re-fetch L1 block by hash to ensure op-node validation won't fail due to hash mismatch
L1_START_TAG=$(jq -r .l1StartingBlockTag "$DEPLOY_CONFIG_PATH")
L1_REFETCH=$(_rpc_call "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByHash\",\"params\":[\"$L1_START_TAG\",false],\"id\":1}")
L1_REFETCH_HASH=$(echo "$L1_REFETCH" | jq -r '.result.hash // empty')
if [ -n "$L1_REFETCH_HASH" ] && [ "$L1_REFETCH_HASH" != "$L1_START_TAG" ]; then
  jq --arg h "$L1_REFETCH_HASH" '.l1StartingBlockTag = $h' "$DEPLOY_CONFIG_PATH" > "$DEPLOY_CONFIG_PATH.tmp" && mv "$DEPLOY_CONFIG_PATH.tmp" "$DEPLOY_CONFIG_PATH"
  echo "Updated deploy config l1StartingBlockTag: $L1_REFETCH_HASH"
fi
# Use op-node from the same repo version as contracts to ensure compatibility
cd $BASE_PATH/optimism/op-node
go run ./cmd genesis l2 \
  --deploy-config $DEPLOY_CONFIG_PATH \
  --l1-deployments $DEPLOYMENT_OUTFILE \
  --l2-allocs $STATE_DUMP_PATH \
  --l1-rpc $L1_RPC_URL \
  --outfile.l2 $OP_GETH_GENESIS_FILE \
  --outfile.rollup $OP_NODE_ROLLUP_FILE

# Copy the generated configs to the result path.
cp $DEPLOYMENT_OUTFILE $DEPLOYMENT_CONFIG_PATH
cp $STATE_DUMP_PATH $DEPLOYMENT_CONFIG_PATH
cp $OP_GETH_GENESIS_FILE $DEPLOYMENT_CONFIG_PATH
cp $OP_NODE_ROLLUP_FILE $DEPLOYMENT_CONFIG_PATH

echo "Deployment complete!"

cd $BASE_PATH
