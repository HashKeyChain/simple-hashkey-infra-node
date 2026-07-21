#!/usr/bin/env bash
set -euo pipefail

# Deploy a standalone L1 SystemConfig implementation from the Jovian contracts branch.
# This script does not upgrade any proxy and does not modify artifact files.
#
# Usage:
#   bash scripts/jovian/deploy-systemconfig.sh [contracts_ref]
#
# Environment variables:
#   SYSTEM_CONFIG_DEPLOY_PRIVATE_KEY defaults to $GS_ADMIN_PRIVATE_KEY
#   CONTRACTS_UPGRADE_REF            defaults to cgt-jovian/contracts-v2.0.0-beta.3

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

CONTRACTS_REF="${1:-${CONTRACTS_UPGRADE_REF:-cgt-jovian/contracts-v2.0.0-beta.3}}"
SYSTEM_CONFIG_DEPLOY_PRIVATE_KEY="${SYSTEM_CONFIG_DEPLOY_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
DEPLOY_SIGNER=$(cast wallet address --private-key "$SYSTEM_CONFIG_DEPLOY_PRIVATE_KEY")

echo "============================================"
echo "  Deploy Jovian SystemConfig Implementation"
echo "============================================"
echo "contracts ref: $CONTRACTS_REF"
echo "contracts dir: $CONTRACTS_BEDROCK_PATH"
echo "L1 RPC:        $L1_RPC_URL"
echo "deploy signer: $DEPLOY_SIGNER"
echo ""

echo "== checking out contracts ref =="
cd "$CONTRACTS_BEDROCK_PATH"
if git rev-parse --verify --quiet "$CONTRACTS_REF" >/dev/null; then
  git checkout "$CONTRACTS_REF"
else
  git fetch origin "$CONTRACTS_REF" --depth 1
  git checkout FETCH_HEAD
fi

echo "== installing/building contracts =="
forge install --no-commit >/dev/null 2>&1 || true
forge build --silent

echo "== deploying SystemConfig implementation =="
if ! DEPLOY_RESULT=$(forge create \
  --json \
  --rpc-url "$L1_RPC_URL" \
  --private-key "$SYSTEM_CONFIG_DEPLOY_PRIVATE_KEY" \
  src/L1/SystemConfig.sol:SystemConfig 2>&1); then
  echo "ERROR: forge create failed"
  echo "$DEPLOY_RESULT"
  exit 1
fi

DEPLOY_JSON=$(echo "$DEPLOY_RESULT" | awk '/^{/,/^}/')
NEW_SYSTEM_CONFIG=$(echo "$DEPLOY_JSON" | jq -r '.deployedTo // empty')
if [ -z "$NEW_SYSTEM_CONFIG" ]; then
  echo "ERROR: failed to parse new SystemConfig implementation address"
  echo "$DEPLOY_RESULT"
  exit 1
fi

NEW_IMPL_VERSION=$(cast call "$NEW_SYSTEM_CONFIG" "version()(string)" --rpc-url "$L1_RPC_URL")

cd "$BASE_PATH"

echo ""
echo "============================================"
echo "  Deployed"
echo "============================================"
echo "SystemConfig implementation: $NEW_SYSTEM_CONFIG"
echo "Implementation version:      $NEW_IMPL_VERSION"
echo ""
echo "To upgrade the proxy to this implementation:"
echo "  bash scripts/jovian/upgrade-systemconfig.sh $NEW_SYSTEM_CONFIG"
