#!/bin/bash
set -e

# Usage:
#   bash scripts/upgrade-systemconfig-custom.sh <system_config_proxy> [new_impl]
#
# Arguments:
#   system_config_proxy - SystemConfigProxy contract address (required)
#   new_impl            - New SystemConfig implementation address (optional, will deploy if not provided)
#
# Environment variables:
#   L1_RPC_URL          - L1 RPC URL (required)
#   GS_ADMIN_PRIVATE_KEY - Private key of Safe owner (required)
#   OPERATOR_FEE_SCALAR   - Operator fee scalar (default: 0)
#   OPERATOR_FEE_CONSTANT - Operator fee constant in wei (default: 0)
#
# The script will automatically query:
#   - ProxyAdmin from SystemConfigProxy's ERC1967 admin slot
#   - SystemOwnerSafe from ProxyAdmin's owner
#   - Safe owner from SystemOwnerSafe's getOwners()
#
# Examples:
#   # Use existing implementation
#   bash scripts/upgrade-systemconfig-custom.sh 0xSystemConfig... 0xImpl...
#
#   # Deploy new implementation
#   bash scripts/upgrade-systemconfig-custom.sh 0xSystemConfig...

source .envrc

# Parse command line arguments
SYSTEM_CONFIG_PROXY="${1}"
NEW_SYSTEM_CONFIG="${2}"

if [ -z "$SYSTEM_CONFIG_PROXY" ]; then
  echo "Usage: bash scripts/upgrade-systemconfig-custom.sh <system_config_proxy> [new_impl]"
  echo ""
  echo "Arguments:"
  echo "  system_config_proxy - SystemConfigProxy contract address (required)"
  echo "  new_impl            - New SystemConfig implementation address (optional)"
  echo ""
  echo "The script will automatically query ProxyAdmin and SystemOwnerSafe from the chain."
  exit 1
fi

echo "============================================"
echo "  SystemConfig L1 Contract Upgrade Script"
echo "  (Auto-discovery mode)"
echo "============================================"
echo "SystemConfigProxy: $SYSTEM_CONFIG_PROXY"
echo "L1 RPC: $L1_RPC_URL"
echo ""

# Query ProxyAdmin from ERC1967 admin slot
# Admin slot: 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103
echo "Querying ProxyAdmin from ERC1967 admin slot..."
ADMIN_SLOT=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getStorageAt\",\"params\":[\"$SYSTEM_CONFIG_PROXY\",\"0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103\",\"latest\"],\"id\":1}" \
  | jq -r '.result')
PROXY_ADMIN="0x${ADMIN_SLOT: -40}"
echo "  ProxyAdmin: $PROXY_ADMIN"

# Query SystemOwnerSafe from ProxyAdmin's owner
echo "Querying SystemOwnerSafe from ProxyAdmin..."
OWNER_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$PROXY_ADMIN\",\"data\":\"0x8da5cb5b\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
SYSTEM_OWNER_SAFE="0x${OWNER_RAW: -40}"
echo "  SystemOwnerSafe: $SYSTEM_OWNER_SAFE"

# Query Safe owner from SystemOwnerSafe's getOwners()
echo "Querying Safe owner..."
OWNERS_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_OWNER_SAFE\",\"data\":\"0xa0e67e2b\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
SAFE_OWNER="0x${OWNERS_RAW: -40}"
echo "  Safe owner (EOA): $SAFE_OWNER"

echo ""
echo "Discovered addresses:"
echo "  ProxyAdmin: $PROXY_ADMIN"
echo "  SystemOwnerSafe: $SYSTEM_OWNER_SAFE"
echo "  Safe owner: $SAFE_OWNER"

if [ -n "$NEW_SYSTEM_CONFIG" ]; then
  echo "  New implementation: $NEW_SYSTEM_CONFIG (provided)"
else
  echo "  New implementation: (will deploy)"
fi

# Check current SystemConfig version
echo ""
echo "Checking current SystemConfig version..."
CURRENT_VERSION_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x54fd4d50\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
# Decode version string (skip offset and length, take the actual string)
CURRENT_VERSION=$(echo "$CURRENT_VERSION_RAW" | cut -c131-146 | xxd -r -p 2>/dev/null || echo "unknown")
echo "  Current version: $CURRENT_VERSION"

# If new implementation not provided, deploy it
if [ -z "$NEW_SYSTEM_CONFIG" ]; then
  # Switch to the upgrade branch/ref
  CONTRACTS_REF="${OP_NODE_REF}"
  echo ""
  echo "Switching to contracts ref: $CONTRACTS_REF"
  cd $CONTRACTS_BEDROCK_PATH
  git fetch origin $CONTRACTS_REF --depth 1 || git fetch origin tag $CONTRACTS_REF --depth 1 || true
  git checkout FETCH_HEAD

  # Update submodules
  echo ""
  echo "Updating submodules..."
  git submodule update --init --recursive lib/safe-contracts lib/lib-keccak lib/forge-std 2>/dev/null || true

  # Install dependencies
  forge install --no-commit 2>/dev/null || true

  # Deploy new SystemConfig implementation
  echo ""
  echo "Deploying new SystemConfig implementation..."

  set +e
  DEPLOY_RESULT=$(forge create \
    --broadcast \
    --json \
    --rpc-url $L1_RPC_URL \
    --private-key $GS_ADMIN_PRIVATE_KEY \
    src/L1/SystemConfig.sol:SystemConfig 2>&1)
  DEPLOY_EXIT_CODE=$?
  set -e

  DEPLOY_JSON=$(echo "$DEPLOY_RESULT" | awk '/^{/,/^}/')
  NEW_SYSTEM_CONFIG=$(echo "$DEPLOY_JSON" | jq -r '.deployedTo' 2>/dev/null)

  if [ "$NEW_SYSTEM_CONFIG" == "null" ] || [ -z "$NEW_SYSTEM_CONFIG" ]; then
    echo "Error deploying SystemConfig (exit code: $DEPLOY_EXIT_CODE):"
    echo "$DEPLOY_RESULT"
    exit 1
  fi
  echo "  New SystemConfig implementation: $NEW_SYSTEM_CONFIG"
else
  echo ""
  echo "Using provided implementation: $NEW_SYSTEM_CONFIG"
fi

# Check new version
echo "Checking new implementation version..."
NEW_VERSION_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$NEW_SYSTEM_CONFIG\",\"data\":\"0x54fd4d50\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
NEW_VERSION=$(echo "$NEW_VERSION_RAW" | cut -c131-146 | xxd -r -p 2>/dev/null || echo "unknown")
echo "  New implementation version: $NEW_VERSION"

# Get current config values from proxy
echo ""
echo "Reading current SystemConfig values..."
CURRENT_OWNER_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x8da5cb5b\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
CURRENT_OWNER="0x${CURRENT_OWNER_RAW: -40}"
echo "  Owner: $CURRENT_OWNER"

echo ""
echo "Using GS_ADMIN_PRIVATE_KEY to sign transactions"

# Simple upgrade via Safe.execTransaction
echo ""
echo "Executing simple upgrade via Safe.execTransaction..."

# Encode ProxyAdmin.upgrade(proxy, impl) calldata
UPGRADE_DATA=$(cast calldata "upgrade(address,address)" $SYSTEM_CONFIG_PROXY $NEW_SYSTEM_CONFIG)
echo "  Upgrade calldata: $UPGRADE_DATA"

# For 1-of-1 Safe with v=1 mode (approved hash), when msg.sender == owner:
# Format: r (32 bytes = owner padded) + s (32 bytes = 0) + v (1 byte = 01)
OWNER_NO_PREFIX=$(echo $SAFE_OWNER | sed 's/0x//')
SIGNATURE="0x000000000000000000000000${OWNER_NO_PREFIX}000000000000000000000000000000000000000000000000000000000000000001"

# Call Safe.execTransaction
cast send $SYSTEM_OWNER_SAFE \
  "execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)" \
  $PROXY_ADMIN \
  0 \
  $UPGRADE_DATA \
  0 \
  0 \
  0 \
  0 \
  "0x0000000000000000000000000000000000000000" \
  "0x0000000000000000000000000000000000000000" \
  $SIGNATURE \
  --private-key $GS_ADMIN_PRIVATE_KEY \
  --rpc-url $L1_RPC_URL

# Verify upgrade
echo ""
echo "Verifying upgrade..."
UPGRADED_VERSION_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x54fd4d50\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
UPGRADED_VERSION=$(echo "$UPGRADED_VERSION_RAW" | cut -c131-146 | xxd -r -p 2>/dev/null || echo "unknown")
echo "  Proxy version after upgrade: $UPGRADED_VERSION"

# Set operator fee (optional)
OPERATOR_FEE_SCALAR="${OPERATOR_FEE_SCALAR:-0}"
OPERATOR_FEE_CONSTANT="${OPERATOR_FEE_CONSTANT:-0}"

if [ "$OPERATOR_FEE_CONSTANT" != "0" ] || [ "$OPERATOR_FEE_SCALAR" != "0" ]; then
  echo ""
  echo "Setting operator fee parameters..."
  echo "  operatorFeeScalar: $OPERATOR_FEE_SCALAR"
  echo "  operatorFeeConstant: $OPERATOR_FEE_CONSTANT wei"
  
  # Send setOperatorFeeScalars using private key
  cast send $SYSTEM_CONFIG_PROXY \
    "setOperatorFeeScalars(uint32,uint64)" \
    $OPERATOR_FEE_SCALAR \
    $OPERATOR_FEE_CONSTANT \
    --private-key $GS_ADMIN_PRIVATE_KEY \
    --rpc-url $L1_RPC_URL
  
  # Verify the setting
  echo "  Verifying operator fee settings..."
  NEW_OPERATOR_FEE_SCALAR_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x68cf83f8\"},\"latest\"],\"id\":1}" \
    | jq -r '.result')
  NEW_OPERATOR_FEE_CONSTANT_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x6cdeeb7d\"},\"latest\"],\"id\":1}" \
    | jq -r '.result')
  echo "  Verified operatorFeeScalar: $NEW_OPERATOR_FEE_SCALAR_RAW"
  echo "  Verified operatorFeeConstant: $NEW_OPERATOR_FEE_CONSTANT_RAW"
fi

echo ""
echo "============================================"
echo "  Upgrade complete!"
echo "  Old version: $CURRENT_VERSION"
echo "  New version: $UPGRADED_VERSION"
echo "  New implementation: $NEW_SYSTEM_CONFIG"
echo "============================================"

cd $BASE_PATH
