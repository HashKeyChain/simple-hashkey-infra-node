#!/bin/bash
set -e

# Usage:
#   bash scripts/upgrade-systemconfig.sh [mode] [contracts_ref]
#
# Arguments:
#   mode          - "simple" (default) or "reinit"
#   contracts_ref - Git ref for contracts (default: $OP_NODE_REF)
#
# Environment variables:
#   OPERATOR_FEE_SCALAR   - Operator fee scalar (default: 0)
#   OPERATOR_FEE_CONSTANT - Operator fee constant in wei (default: 0)
#
# Examples:
#   # Simple upgrade
#   bash scripts/upgrade-systemconfig.sh simple
#
#   # Upgrade and set operator fee to 0.01 ether
#   OPERATOR_FEE_CONSTANT=10000000000000000 bash scripts/upgrade-systemconfig.sh simple

source .envrc

# Parse command line arguments
UPGRADE_MODE="${1:-simple}"  # "simple" or "reinit"
CONTRACTS_REF="${2:-$OP_NODE_REF}"  # Use OP_NODE_REF by default or specify custom ref

echo "============================================"
echo "  SystemConfig L1 Contract Upgrade Script"
echo "============================================"
echo "Upgrade mode: $UPGRADE_MODE"
echo "Contracts ref: $CONTRACTS_REF"

# Read addresses from artifact.json
ARTIFACT_FILE=$DEPLOYMENT_OUTFILE
if [ ! -f "$ARTIFACT_FILE" ]; then
  echo "Error: artifact.json not found at $ARTIFACT_FILE"
  exit 1
fi

SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' $ARTIFACT_FILE)
PROXY_ADMIN=$(jq -r '.ProxyAdmin' $ARTIFACT_FILE)
SYSTEM_OWNER_SAFE=$(jq -r '.SystemOwnerSafe' $ARTIFACT_FILE)
L1_CROSS_DOMAIN_MESSENGER_PROXY=$(jq -r '.L1CrossDomainMessengerProxy' $ARTIFACT_FILE)
L1_ERC721_BRIDGE_PROXY=$(jq -r '.L1ERC721BridgeProxy' $ARTIFACT_FILE)
L1_STANDARD_BRIDGE_PROXY=$(jq -r '.L1StandardBridgeProxy' $ARTIFACT_FILE)
OPTIMISM_PORTAL_PROXY=$(jq -r '.OptimismPortalProxy' $ARTIFACT_FILE)
OPTIMISM_MINTABLE_ERC20_FACTORY_PROXY=$(jq -r '.OptimismMintableERC20FactoryProxy' $ARTIFACT_FILE)
DELAYED_WETH_PROXY=$(jq -r '.DelayedWETHProxy' $ARTIFACT_FILE)
SUPERCHAIN_CONFIG_PROXY=$(jq -r '.SuperchainConfigProxy' $ARTIFACT_FILE)

echo ""
echo "Contract addresses:"
echo "  SystemConfigProxy: $SYSTEM_CONFIG_PROXY"
echo "  ProxyAdmin: $PROXY_ADMIN"
echo "  SystemOwnerSafe: $SYSTEM_OWNER_SAFE"

# Check current SystemConfig version
echo ""
echo "Checking current SystemConfig version..."
CURRENT_VERSION=$(cast call $SYSTEM_CONFIG_PROXY "version()" --rpc-url $L1_RPC_URL | cast --to-ascii)
echo "  Current version: $CURRENT_VERSION"

# Switch to the upgrade branch/ref
echo ""
echo "Switching to contracts ref: $CONTRACTS_REF"
cd $CONTRACTS_BEDROCK_PATH
git fetch origin $CONTRACTS_REF --depth 1 || git fetch origin tag $CONTRACTS_REF --depth 1 || true
git checkout FETCH_HEAD

# Update submodules (fix missing safe-contracts etc)
echo ""
echo "Updating submodules..."
git submodule update --init --recursive lib/safe-contracts lib/lib-keccak lib/forge-std 2>/dev/null || true

# Install dependencies
forge install --no-commit 2>/dev/null || true

# Deploy new SystemConfig implementation
echo ""
echo "Deploying new SystemConfig implementation..."

# Temporarily disable set -e for forge create
set +e
DEPLOY_RESULT=$(forge create \
  --broadcast \
  --json \
  --rpc-url $L1_RPC_URL \
  --private-key $GS_ADMIN_PRIVATE_KEY \
  src/L1/SystemConfig.sol:SystemConfig 2>&1)
DEPLOY_EXIT_CODE=$?
set -e

# Extract JSON block and parse deployedTo
# The output may have warning lines before JSON, so we extract lines from { to }
DEPLOY_JSON=$(echo "$DEPLOY_RESULT" | awk '/^{/,/^}/')
NEW_SYSTEM_CONFIG=$(echo "$DEPLOY_JSON" | jq -r '.deployedTo' 2>/dev/null)

if [ "$NEW_SYSTEM_CONFIG" == "null" ] || [ -z "$NEW_SYSTEM_CONFIG" ]; then
  echo "Error deploying SystemConfig (exit code: $DEPLOY_EXIT_CODE):"
  echo "$DEPLOY_RESULT"
  exit 1
fi
echo "  New SystemConfig implementation: $NEW_SYSTEM_CONFIG"

# Check new version
NEW_VERSION=$(cast call $NEW_SYSTEM_CONFIG "version()" --rpc-url $L1_RPC_URL | cast --to-ascii)
echo "  New implementation version: $NEW_VERSION"

# Get current config values from proxy
echo ""
echo "Reading current SystemConfig values..."
CURRENT_OWNER=$(cast call $SYSTEM_CONFIG_PROXY "owner()" --rpc-url $L1_RPC_URL)
CURRENT_BASEFEE_SCALAR=$(cast call $SYSTEM_CONFIG_PROXY "basefeeScalar()" --rpc-url $L1_RPC_URL)
CURRENT_BLOBBASEFEE_SCALAR=$(cast call $SYSTEM_CONFIG_PROXY "blobbasefeeScalar()" --rpc-url $L1_RPC_URL)
CURRENT_BATCHER_HASH=$(cast call $SYSTEM_CONFIG_PROXY "batcherHash()" --rpc-url $L1_RPC_URL)
CURRENT_GAS_LIMIT=$(cast call $SYSTEM_CONFIG_PROXY "gasLimit()" --rpc-url $L1_RPC_URL)
CURRENT_UNSAFE_BLOCK_SIGNER=$(cast call $SYSTEM_CONFIG_PROXY "unsafeBlockSigner()" --rpc-url $L1_RPC_URL)
CURRENT_BATCH_INBOX=$(cast call $SYSTEM_CONFIG_PROXY "batchInbox()" --rpc-url $L1_RPC_URL)

echo "  Owner: $CURRENT_OWNER"
echo "  BasefeeScalar: $CURRENT_BASEFEE_SCALAR"
echo "  BlobbasefeeScalar: $CURRENT_BLOBBASEFEE_SCALAR"
echo "  BatcherHash: $CURRENT_BATCHER_HASH"
echo "  GasLimit: $CURRENT_GAS_LIMIT"

# Get Safe owner (for execTransaction)
# getOwners() returns address[], we extract the first owner
OWNERS_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_OWNER_SAFE\",\"data\":\"0xa0e67e2b\"},\"latest\"],\"id\":1}" \
  | jq -r '.result')
# For 1-owner Safe, format is: offset(32) + length(32) + owner(32)
# Extract last 40 chars of the 3rd 32-byte word
SAFE_OWNER="0x${OWNERS_RAW: -40}"
echo ""
echo "Safe owner: $SAFE_OWNER"
echo "Using GS_ADMIN_PRIVATE_KEY to sign transactions"

if [ "$UPGRADE_MODE" == "reinit" ]; then
  echo ""
  echo "Executing upgradeAndCall with reinitialize..."
  
  # Encode the initialize call data
  # New SystemConfig.initialize signature:
  # initialize(address,uint32,uint32,bytes32,uint64,address,ResourceConfig,address,Addresses,uint256,ISuperchainConfig)
  
  # For now, use the Forge script approach for complex encoding
  # Or we can use cast to encode the call
  
  # Build Addresses struct (new format):
  # struct Addresses { l1CrossDomainMessenger, l1ERC721Bridge, l1StandardBridge, optimismPortal, optimismMintableERC20Factory, delayedWETH, opcm }
  
  # Get ResourceConfig
  RESOURCE_CONFIG=$(cast call $SYSTEM_CONFIG_PROXY "resourceConfig()" --rpc-url $L1_RPC_URL)
  
  # This is complex - use forge script instead
  echo "Running upgrade via Forge script..."
  
  cd $CONTRACTS_BEDROCK_PATH
  
  # Create a temporary upgrade script
  cat > scripts/temp/UpgradeSystemConfigTemp.s.sol << 'SCRIPT_EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console2 as console } from "forge-std/console2.sol";
import { ProxyAdmin } from "src/universal/ProxyAdmin.sol";
import { SystemConfig } from "src/L1/SystemConfig.sol";
import { IResourceMetering } from "interfaces/L1/IResourceMetering.sol";
import { ISuperchainConfig } from "interfaces/L1/ISuperchainConfig.sol";

contract UpgradeSystemConfigTemp is Script {
    function run(
        address systemConfigProxy,
        address proxyAdmin,
        address newSystemConfig,
        address superchainConfigProxy,
        uint256 l2ChainId
    ) public {
        SystemConfig currentConfig = SystemConfig(systemConfigProxy);
        
        // Read current values
        address owner = currentConfig.owner();
        uint32 basefeeScalar = currentConfig.basefeeScalar();
        uint32 blobbasefeeScalar = currentConfig.blobbasefeeScalar();
        bytes32 batcherHash = currentConfig.batcherHash();
        uint64 gasLimit = currentConfig.gasLimit();
        address unsafeBlockSigner = currentConfig.unsafeBlockSigner();
        address batchInbox = currentConfig.batchInbox();
        IResourceMetering.ResourceConfig memory resourceConfig = currentConfig.resourceConfig();
        
        // Build new Addresses struct
        SystemConfig.Addresses memory addresses = SystemConfig.Addresses({
            l1CrossDomainMessenger: currentConfig.l1CrossDomainMessenger(),
            l1ERC721Bridge: currentConfig.l1ERC721Bridge(),
            l1StandardBridge: currentConfig.l1StandardBridge(),
            optimismPortal: currentConfig.optimismPortal(),
            optimismMintableERC20Factory: currentConfig.optimismMintableERC20Factory(),
            delayedWETH: address(0), // Will be set if exists
            opcm: address(0) // Not used
        });
        
        // Try to get delayedWETH if it exists
        try this.getDelayedWETH(systemConfigProxy) returns (address delayedWETH) {
            addresses.delayedWETH = delayedWETH;
        } catch {}
        
        bytes memory initData = abi.encodeCall(
            SystemConfig.initialize,
            (
                owner,
                basefeeScalar,
                blobbasefeeScalar,
                batcherHash,
                gasLimit,
                unsafeBlockSigner,
                resourceConfig,
                batchInbox,
                addresses,
                l2ChainId,
                ISuperchainConfig(superchainConfigProxy)
            )
        );
        
        vm.broadcast();
        ProxyAdmin(proxyAdmin).upgradeAndCall(payable(systemConfigProxy), newSystemConfig, initData);
        
        console.log("Upgrade complete. New version:", SystemConfig(systemConfigProxy).version());
    }
    
    function getDelayedWETH(address systemConfigProxy) external view returns (address) {
        // Try to call delayedWETH() - will revert if not available
        (bool success, bytes memory data) = systemConfigProxy.staticcall(abi.encodeWithSignature("delayedWETH()"));
        require(success, "delayedWETH not available");
        return abi.decode(data, (address));
    }
}
SCRIPT_EOF

  mkdir -p scripts/temp
  
  forge script scripts/temp/UpgradeSystemConfigTemp.s.sol:UpgradeSystemConfigTemp \
    --sig "run(address,address,address,address,uint256)" \
    $SYSTEM_CONFIG_PROXY \
    $PROXY_ADMIN \
    $NEW_SYSTEM_CONFIG \
    $SUPERCHAIN_CONFIG_PROXY \
    $L2_CHAIN_ID \
    --broadcast \
    --unlocked \
    --sender $SYSTEM_OWNER_SAFE \
    --rpc-url $L1_RPC_URL
  
  # Clean up temp script
  rm -f scripts/temp/UpgradeSystemConfigTemp.s.sol
  
else
  # Simple upgrade without reinitialize
  echo ""
  echo "Executing simple upgrade via Safe.execTransaction..."
  
  # Encode ProxyAdmin.upgrade(proxy, impl) calldata
  UPGRADE_DATA=$(cast calldata "upgrade(address,address)" $SYSTEM_CONFIG_PROXY $NEW_SYSTEM_CONFIG)
  echo "  Upgrade calldata: $UPGRADE_DATA"
  
  # For 1-of-1 Safe with v=1 mode (approved hash), when msg.sender == owner:
  # Format: r (32 bytes = owner padded) + s (32 bytes = 0) + v (1 byte = 01)
  OWNER_NO_PREFIX=$(echo $SAFE_OWNER | sed 's/0x//')
  # r = 24 zeros + 40 char address = 64 chars, s = 64 zeros, v = 01
  SIGNATURE="0x000000000000000000000000${OWNER_NO_PREFIX}000000000000000000000000000000000000000000000000000000000000000001"
  
  # Call Safe.execTransaction(to, value, data, operation, safeTxGas, baseGas, gasPrice, gasToken, refundReceiver, signatures)
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
fi

# Verify upgrade
echo ""
echo "Verifying upgrade..."
UPGRADED_VERSION=$(cast call $SYSTEM_CONFIG_PROXY "version()" --rpc-url $L1_RPC_URL | cast --to-ascii)
echo "  Proxy version after upgrade: $UPGRADED_VERSION"

# Set operator fee
# Default: 0.01 ether = 10000000000000000 wei
OPERATOR_FEE_SCALAR="${OPERATOR_FEE_SCALAR:-0}"
OPERATOR_FEE_CONSTANT="${OPERATOR_FEE_CONSTANT:-10000000000000000}"

if [ "$OPERATOR_FEE_CONSTANT" != "0" ] || [ "$OPERATOR_FEE_SCALAR" != "0" ]; then
  echo ""
  echo "Setting operator fee parameters..."
  echo "  operatorFeeScalar: $OPERATOR_FEE_SCALAR"
  echo "  operatorFeeConstant: $OPERATOR_FEE_CONSTANT wei"
  
  # Get the owner of SystemConfig (convert bytes32 to address)
  SYSTEM_CONFIG_OWNER_RAW=$(curl -s -X POST $L1_RPC_URL -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$SYSTEM_CONFIG_PROXY\",\"data\":\"0x8da5cb5b\"},\"latest\"],\"id\":1}" \
    | jq -r '.result')
  SYSTEM_CONFIG_OWNER="0x${SYSTEM_CONFIG_OWNER_RAW: -40}"
  echo "  SystemConfig owner: $SYSTEM_CONFIG_OWNER"
  
  # Send setOperatorFeeScalars using private key
  cast send $SYSTEM_CONFIG_PROXY \
    "setOperatorFeeScalars(uint32,uint64)" \
    $OPERATOR_FEE_SCALAR \
    $OPERATOR_FEE_CONSTANT \
    --private-key $GS_ADMIN_PRIVATE_KEY \
    --rpc-url $L1_RPC_URL
  
  # Verify the setting
  NEW_OPERATOR_FEE_SCALAR=$(cast call $SYSTEM_CONFIG_PROXY "operatorFeeScalar()" --rpc-url $L1_RPC_URL)
  NEW_OPERATOR_FEE_CONSTANT=$(cast call $SYSTEM_CONFIG_PROXY "operatorFeeConstant()" --rpc-url $L1_RPC_URL)
  echo "  Verified operatorFeeScalar: $NEW_OPERATOR_FEE_SCALAR"
  echo "  Verified operatorFeeConstant: $NEW_OPERATOR_FEE_CONSTANT"
fi

# Update artifact.json with new implementation address
echo ""
echo "Updating artifact.json..."
jq --arg new_impl "$NEW_SYSTEM_CONFIG" '.SystemConfig = $new_impl' $ARTIFACT_FILE > tmp.json && mv tmp.json $ARTIFACT_FILE
cp $ARTIFACT_FILE $DEPLOYMENT_CONFIG_PATH/

echo ""
echo "============================================"
echo "  Upgrade complete!"
echo "  Old version: $CURRENT_VERSION"
echo "  New version: $UPGRADED_VERSION"
echo "  New implementation: $NEW_SYSTEM_CONFIG"
echo "============================================"

cd $BASE_PATH
