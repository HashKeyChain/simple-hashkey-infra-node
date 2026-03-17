#!/bin/bash

# Usage:
#   bash scripts/bridge-to-l2-custom.sh <optimism_portal> <amount> [recipient] [private_key]
#
# Arguments:
#   optimism_portal - OptimismPortal contract address (required)
#   amount          - Amount to bridge, e.g. "1ether" or "0.1ether" (required)
#   recipient       - Recipient address on L2 (optional, defaults to sender)
#   private_key     - Private key for signing (optional, defaults to $DEPLOY_PRIVATE_KEY)
#
# Environment variables:
#   L1_RPC_URL              - L1 RPC URL (required)
#   L2_RPC_URL              - L2 RPC URL (required)
#   USE_CUSTOM_GAS_TOKEN    - "true" to bridge custom gas token (optional)
#   CUSTOM_GAS_TOKEN_ADDRESS - Custom gas token address on L1 (required if USE_CUSTOM_GAS_TOKEN=true)
#
# Examples:
#   # Bridge 1 ether
#   bash scripts/bridge-to-l2-custom.sh 0xPortal... 1ether
#
#   # Bridge 0.1 ether to specific address
#   bash scripts/bridge-to-l2-custom.sh 0xPortal... 0.1ether 0xRecipient...
#
#   # Bridge custom gas token
#   USE_CUSTOM_GAS_TOKEN=true CUSTOM_GAS_TOKEN_ADDRESS=0xToken... \
#     bash scripts/bridge-to-l2-custom.sh 0xPortal... 1ether

source .envrc

# Parse arguments
OPTIMISM_PORTAL="${1}"
AMOUNT="${2}"
RECIPIENT="${3}"
PRIVATE_KEY="${4:-$DEPLOY_PRIVATE_KEY}"

if [ -z "$OPTIMISM_PORTAL" ] || [ -z "$AMOUNT" ]; then
  echo "Usage: bash scripts/bridge-to-l2-custom.sh <optimism_portal> <amount> [recipient] [private_key]"
  echo ""
  echo "Arguments:"
  echo "  optimism_portal - OptimismPortal contract address (required)"
  echo "  amount          - Amount to bridge, e.g. '1ether' (required)"
  echo "  recipient       - Recipient address on L2 (optional)"
  echo "  private_key     - Private key for signing (optional)"
  exit 1
fi

# Get sender address from private key
SENDER=$(cast wallet address --private-key $PRIVATE_KEY 2>/dev/null)
if [ -z "$SENDER" ]; then
  echo "Error: Invalid private key"
  exit 1
fi

# Default recipient to sender
RECIPIENT=${RECIPIENT:-$SENDER}

echo "=== Bridge to L2 (Custom) ==="
echo "OptimismPortal: $OPTIMISM_PORTAL"
echo "Amount: $AMOUNT"
echo "Sender: $SENDER"
echo "Recipient: $RECIPIENT"
echo "L1 RPC: $L1_RPC_URL"
echo "L2 RPC: $L2_RPC_URL"
echo "Use Custom Gas Token: ${USE_CUSTOM_GAS_TOKEN:-false}"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  if [ -z "$CUSTOM_GAS_TOKEN_ADDRESS" ]; then
    echo "Error: CUSTOM_GAS_TOKEN_ADDRESS is required when USE_CUSTOM_GAS_TOKEN=true"
    exit 1
  fi
  echo "Custom Gas Token: $CUSTOM_GAS_TOKEN_ADDRESS"
fi
echo ""

# Check L1 balance before
echo "Checking balances..."
L1_ETH_BEFORE=$(cast balance $SENDER --rpc-url $L1_RPC_URL)
echo "L1 ETH Balance (sender): $L1_ETH_BEFORE"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  L1_TOKEN_BEFORE=$(cast call $CUSTOM_GAS_TOKEN_ADDRESS "balanceOf(address)(uint256)" $SENDER --rpc-url $L1_RPC_URL 2>/dev/null || echo "0")
  echo "L1 Gas Token Balance (sender): $L1_TOKEN_BEFORE"
fi

L2_BALANCE_BEFORE=$(cast balance $RECIPIENT --rpc-url $L2_RPC_URL 2>/dev/null || echo "0")
echo "L2 Native Balance (recipient): $L2_BALANCE_BEFORE"
echo ""

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  #############################################
  # Custom Gas Token Bridge
  #############################################
  echo "=== Bridging Custom Gas Token ==="
  
  # Convert amount to wei
  AMOUNT_WEI=$(cast to-wei $(echo $AMOUNT | sed 's/ether//'))
  echo "Amount in wei: $AMOUNT_WEI"
  
  # Step 1: Approve the OptimismPortal to spend tokens
  echo ""
  echo "Step 1: Approving OptimismPortal to spend tokens..."
  echo "  Token: $CUSTOM_GAS_TOKEN_ADDRESS"
  echo "  Spender: $OPTIMISM_PORTAL"
  echo "  Amount: $AMOUNT_WEI"
  
  APPROVE_TX=$(cast send $CUSTOM_GAS_TOKEN_ADDRESS \
    "approve(address,uint256)" \
    $OPTIMISM_PORTAL \
    $AMOUNT_WEI \
    --private-key $PRIVATE_KEY \
    --rpc-url $L1_RPC_URL \
    --json | jq -r '.transactionHash')
  echo "  Approve TX: $APPROVE_TX"
  
  # Wait for approve to be confirmed
  echo "  Waiting for confirmation..."
  cast receipt $APPROVE_TX --rpc-url $L1_RPC_URL > /dev/null 2>&1
  
  # Verify allowance
  ALLOWANCE=$(cast call $CUSTOM_GAS_TOKEN_ADDRESS \
    "allowance(address,address)(uint256)" \
    $SENDER \
    $OPTIMISM_PORTAL \
    --rpc-url $L1_RPC_URL 2>/dev/null || echo "0")
  echo "  Allowance after approve: $ALLOWANCE"
  
  if [ "$ALLOWANCE" = "0" ]; then
    echo "Error: Allowance is still 0 after approve!"
    exit 1
  fi
  echo "Approved!"
  
  # Step 2: Call depositERC20Transaction on OptimismPortal
  echo ""
  echo "Step 2: Depositing tokens via OptimismPortal..."
  TX_HASH=$(cast send $OPTIMISM_PORTAL \
    "depositERC20Transaction(address,uint256,uint256,uint64,bool,bytes)" \
    $RECIPIENT \
    $AMOUNT_WEI \
    $AMOUNT_WEI \
    300000 \
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
L1_ETH_AFTER=$(cast balance $SENDER --rpc-url $L1_RPC_URL)
echo "  ETH: $L1_ETH_AFTER"

if [ "$USE_CUSTOM_GAS_TOKEN" = "true" ]; then
  L1_TOKEN_AFTER=$(cast call $CUSTOM_GAS_TOKEN_ADDRESS "balanceOf(address)(uint256)" $SENDER --rpc-url $L1_RPC_URL 2>/dev/null || echo "0")
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
