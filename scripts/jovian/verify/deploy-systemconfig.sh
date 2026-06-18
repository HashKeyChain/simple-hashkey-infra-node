#!/usr/bin/env bash
set -euo pipefail

# Deploy a standalone L1 SystemConfig implementation for external/remote networks.
# Fill scripts/jovian/verify/verify.env before running.
# This script does not upgrade any proxy.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../../.." && pwd)
cd "$BASE_PATH"

if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L1_RPC="${L1_RPC:?missing L1_RPC in verify.env}"
SYSTEM_CONFIG_PRIVATE_KEY="${SYSTEM_CONFIG_PRIVATE_KEY:?missing SYSTEM_CONFIG_PRIVATE_KEY in verify.env}"
SYSTEM_CONFIG_CONTRACTS_REPO="${SYSTEM_CONFIG_CONTRACTS_REPO:?missing SYSTEM_CONFIG_CONTRACTS_REPO in verify.env}"
SYSTEM_CONFIG_CONTRACTS_REF="${SYSTEM_CONFIG_CONTRACTS_REF:-cgt-jovian/contracts-v2.0.0-beta.2}"
SYSTEM_CONFIG_VERIFIER="${SYSTEM_CONFIG_VERIFIER:-blockscout}"
SYSTEM_CONFIG_VERIFIER_URL="${SYSTEM_CONFIG_VERIFIER_URL:-}"
SYSTEM_CONFIG_ETHERSCAN_API_KEY="${SYSTEM_CONFIG_ETHERSCAN_API_KEY:-}"
SYSTEM_CONFIG_CHAIN_ID="${SYSTEM_CONFIG_CHAIN_ID:-}"

if [ ! -d "$SYSTEM_CONFIG_CONTRACTS_REPO/.git" ]; then
  echo "ERROR: contracts repo not found: $SYSTEM_CONFIG_CONTRACTS_REPO"
  exit 1
fi

echo "== checking out contracts ref =="
cd "$SYSTEM_CONFIG_CONTRACTS_REPO"
git checkout "$SYSTEM_CONFIG_CONTRACTS_REF"

if [ -d "$SYSTEM_CONFIG_CONTRACTS_REPO/packages/contracts-bedrock" ]; then
  SYSTEM_CONFIG_CONTRACTS_PATH="$SYSTEM_CONFIG_CONTRACTS_REPO/packages/contracts-bedrock"
elif [ -d "$SYSTEM_CONFIG_CONTRACTS_REPO/optimism/packages/contracts-bedrock" ]; then
  SYSTEM_CONFIG_CONTRACTS_PATH="$SYSTEM_CONFIG_CONTRACTS_REPO/optimism/packages/contracts-bedrock"
else
  echo "ERROR: contracts-bedrock path not found under: $SYSTEM_CONFIG_CONTRACTS_REPO"
  echo "Checked:"
  echo "  $SYSTEM_CONFIG_CONTRACTS_REPO/packages/contracts-bedrock"
  echo "  $SYSTEM_CONFIG_CONTRACTS_REPO/optimism/packages/contracts-bedrock"
  exit 1
fi

DEPLOY_SIGNER=$(cast wallet address --private-key "$SYSTEM_CONFIG_PRIVATE_KEY")

echo "============================================"
echo "  Deploy SystemConfig Implementation"
echo "============================================"
echo "contracts ref: $SYSTEM_CONFIG_CONTRACTS_REF"
echo "contracts dir: $SYSTEM_CONFIG_CONTRACTS_PATH"
echo "L1 RPC:        $L1_RPC"
echo "deploy signer: $DEPLOY_SIGNER"
echo ""

cd "$SYSTEM_CONFIG_CONTRACTS_PATH"

echo "== installing/building contracts =="
forge install --no-commit >/dev/null 2>&1 || true
forge build --silent

echo "== deploying SystemConfig implementation =="
DEPLOY_RESULT=$(forge create \
  --broadcast \
  --json \
  --rpc-url "$L1_RPC" \
  --private-key "$SYSTEM_CONFIG_PRIVATE_KEY" \
  src/L1/SystemConfig.sol:SystemConfig 2>&1)

DEPLOY_JSON=$(echo "$DEPLOY_RESULT" | awk '/^{/,/^}/')
NEW_SYSTEM_CONFIG=$(echo "$DEPLOY_JSON" | jq -r '.deployedTo // empty')
if [ -z "$NEW_SYSTEM_CONFIG" ]; then
  echo "ERROR: failed to parse new SystemConfig implementation address"
  echo "$DEPLOY_RESULT"
  exit 1
fi
echo "deployed implementation: $NEW_SYSTEM_CONFIG"

echo "== verifying source on explorer =="

if [ -z "$SYSTEM_CONFIG_CHAIN_ID" ]; then
  SYSTEM_CONFIG_CHAIN_ID=$(cast chain-id --rpc-url "$L1_RPC")
fi

VERIFY_ARGS=(
  verify-contract
  "$NEW_SYSTEM_CONFIG"
  "src/L1/SystemConfig.sol:SystemConfig"
  --chain-id "$SYSTEM_CONFIG_CHAIN_ID"
  --verifier "$SYSTEM_CONFIG_VERIFIER"
  --watch
)

if [ -n "$SYSTEM_CONFIG_VERIFIER_URL" ]; then
  VERIFY_ARGS+=(--verifier-url "$SYSTEM_CONFIG_VERIFIER_URL")
elif [ "$SYSTEM_CONFIG_VERIFIER" != "etherscan" ]; then
  echo "ERROR: missing SYSTEM_CONFIG_VERIFIER_URL in verify.env"
  echo "Set it to the explorer API URL, for example: https://explorer.example.com/api/"
  exit 1
fi

if [ -n "$SYSTEM_CONFIG_ETHERSCAN_API_KEY" ]; then
  VERIFY_ARGS+=(--etherscan-api-key "$SYSTEM_CONFIG_ETHERSCAN_API_KEY")
fi

if ! forge "${VERIFY_ARGS[@]}"; then
  echo "ERROR: explorer source verification failed for: $NEW_SYSTEM_CONFIG"
  exit 1
fi

cd "$BASE_PATH"

echo ""
echo "============================================"
echo "  Deployed"
echo "============================================"
echo "SystemConfig implementation: $NEW_SYSTEM_CONFIG"
echo "Explorer source verification: verified"
