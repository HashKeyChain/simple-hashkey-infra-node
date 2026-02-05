#!/bin/bash

source .envrc

# Default values
AMOUNT=${1:-1ether}
RECIPIENT=${2:-$DEPLOY_ADDRESS}
PRIVATE_KEY=${3:-$DEPLOY_PRIVATE_KEY}

# Get contract addresses from artifact
OPTIMISM_PORTAL=$(jq -r '.OptimismPortalProxy // .OptimismPortal2Proxy' $DEPLOYMENT_CONFIG_PATH/artifact.json)
L1_STANDARD_BRIDGE=$(jq -r '.L1StandardBridgeProxy' $DEPLOYMENT_CONFIG_PATH/artifact.json)

if [ -z "$OPTIMISM_PORTAL" ] || [ "$OPTIMISM_PORTAL" = "null" ]; then
  echo "Error: OptimismPortal address not found in artifact.json"
  exit 1
fi

echo "=== Bridge to L2 ==="
echo "Use Custom Gas Token: $USE_CUSTOM_GAS_TOKEN"
echo "OptimismPortal: $OPTIMISM_PORTAL"
echo "L1StandardBridge: $L1_STANDARD_BRIDGE"
echo "Amount: $AMOUNT"
echo "Recipient: $RECIPIENT"
echo "L1 RPC: $L1_RPC_URL"
echo "L2 RPC: $L2_RPC_URL"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  echo "Custom Gas Token: $CUSTOM_GAS_TOKEN_ADDRESS"
fi
echo ""

# Check L1 balance before
echo "Checking balances..."
L1_ETH_BEFORE=$(cast balance $RECIPIENT --rpc-url $L1_RPC_URL)
echo "L1 ETH Balance: $L1_ETH_BEFORE"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  L1_TOKEN_BEFORE=$(cast call $CUSTOM_GAS_TOKEN_ADDRESS "balanceOf(address)(uint256)" $RECIPIENT --rpc-url $L1_RPC_URL 2>/dev/null || echo "0")
  echo "L1 Gas Token Balance: $L1_TOKEN_BEFORE"
fi

L2_BALANCE_BEFORE=$(cast balance $RECIPIENT --rpc-url $L2_RPC_URL 2>/dev/null || echo "0")
echo "L2 Native Balance: $L2_BALANCE_BEFORE"
echo ""

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  #############################################
  # Custom Gas Token Bridge
  #############################################
  echo "=== Bridging Custom Gas Token ==="
  
  # Convert amount to wei
  AMOUNT_WEI=$(cast to-wei $(echo $AMOUNT | sed 's/ether//'))
  
  # Step 1: Approve the OptimismPortal to spend tokens
  echo "Step 1: Approving OptimismPortal to spend tokens..."
  cast send $CUSTOM_GAS_TOKEN_ADDRESS \
    "approve(address,uint256)" \
    $OPTIMISM_PORTAL \
    $AMOUNT_WEI \
    --private-key $PRIVATE_KEY \
    --rpc-url $L1_RPC_URL \
    --json > /dev/null
  echo "Approved!"
  
  # Step 2: Call depositERC20Transaction on OptimismPortal
  # depositERC20Transaction(address _to, uint256 _mint, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes _data)
  echo "Step 2: Depositing tokens via OptimismPortal..."
  TX_HASH=$(cast send $OPTIMISM_PORTAL \
    "depositERC20Transaction(address,uint256,uint256,uint64,bool,bytes)" \
    $RECIPIENT \
    $AMOUNT_WEI \
    $AMOUNT_WEI \
    100000 \
    false \
    "0x" \
    --private-key $PRIVATE_KEY \
    --rpc-url $L1_RPC_URL \
    --json | jq -r '.transactionHash')
  
  echo "L1 Transaction: $TX_HASH"

else
  #############################################
  # Standard ETH Bridge
  #############################################
  echo "=== Bridging ETH ==="
  
  # depositTransaction(address _to, uint256 _value, uint64 _gasLimit, bool _isCreation, bytes _data)
  echo "Sending deposit transaction..."
  TX_HASH=$(cast send $OPTIMISM_PORTAL \
    "depositTransaction(address,uint256,uint64,bool,bytes)" \
    $RECIPIENT \
    $AMOUNT \
    100000 \
    false \
    "0x" \
    --value $AMOUNT \
    --private-key $PRIVATE_KEY \
    --rpc-url $L1_RPC_URL \
    --json | jq -r '.transactionHash')
  
  echo "L1 Transaction: $TX_HASH"
fi

echo ""

# Wait for L1 confirmation
echo "Waiting for L1 confirmation..."
cast receipt $TX_HASH --rpc-url $L1_RPC_URL > /dev/null 2>&1
echo "L1 transaction confirmed!"

# Check L1 balance after
echo ""
echo "L1 balances after:"
L1_ETH_AFTER=$(cast balance $RECIPIENT --rpc-url $L1_RPC_URL)
echo "  ETH: $L1_ETH_AFTER"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  L1_TOKEN_AFTER=$(cast call $CUSTOM_GAS_TOKEN_ADDRESS "balanceOf(address)(uint256)" $RECIPIENT --rpc-url $L1_RPC_URL 2>/dev/null || echo "0")
  echo "  Gas Token: $L1_TOKEN_AFTER"
fi

# Wait for L2 to process the deposit
echo ""
echo "Waiting for L2 to process deposit (this may take a few blocks)..."
for i in {1..10}; do
  sleep 3
  L2_BALANCE_AFTER=$(cast balance $RECIPIENT --rpc-url $L2_RPC_URL 2>/dev/null || echo "0")
  if [ "$L2_BALANCE_AFTER" != "$L2_BALANCE_BEFORE" ]; then
    echo "Deposit detected on L2!"
    break
  fi
  echo "  Waiting... ($i/10)"
done

# Final L2 balance
L2_BALANCE_AFTER=$(cast balance $RECIPIENT --rpc-url $L2_RPC_URL 2>/dev/null || echo "0")
echo ""
echo "L2 Native Balance after: $L2_BALANCE_AFTER"

echo ""
echo "=== Done ==="
echo ""
echo "To check L2 balance manually:"
echo "  cast balance $RECIPIENT --rpc-url $L2_RPC_URL"
