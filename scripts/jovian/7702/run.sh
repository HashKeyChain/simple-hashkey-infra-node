#!/usr/bin/env bash
set -euo pipefail

# Run the EIP-7702 verification against the configured L2.
#
# Usage:
#   bash scripts/jovian/7702/run.sh [payer_private_key] [delegate_address]
#
# Defaults:
#   payer_private_key = $DEPLOY_PRIVATE_KEY
#   delegate_address  = empty, which deploys EIP7702Delegate.sol first

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../../.." && pwd)
cd "$BASE_PATH"

source .envrc
[ -f scripts/jovian/upgrade.env ] && source scripts/jovian/upgrade.env

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
PAYER_PRIVATE_KEY="${1:-$DEPLOY_PRIVATE_KEY}"
DELEGATE_ADDRESS="${2:-}"
OP_GETH_PATH="$BASE_PATH/op-geth"

if [ ! -d "$OP_GETH_PATH" ]; then
  echo "ERROR: op-geth path not found: $OP_GETH_PATH"
  exit 1
fi

ARGS=(
  "--rpc" "$L2_RPC"
  "--payer-private-key" "$PAYER_PRIVATE_KEY"
)

if [ -n "$DELEGATE_ADDRESS" ]; then
  ARGS+=("--delegate-address" "$DELEGATE_ADDRESS")
else
  if ! command -v forge >/dev/null 2>&1; then
    echo "ERROR: forge is required to compile EIP7702Delegate.sol"
    exit 1
  fi

  DELEGATE_BYTECODE=$(cd "$SCRIPT_DIR" && forge inspect EIP7702Delegate bytecode)
  if [ -z "$DELEGATE_BYTECODE" ] || [ "$DELEGATE_BYTECODE" = "0x" ]; then
    echo "ERROR: failed to compile EIP7702Delegate.sol"
    exit 1
  fi
  ARGS+=("--delegate-bytecode" "$DELEGATE_BYTECODE")
fi

echo "============================================"
echo "  EIP-7702 Verification"
echo "============================================"
echo "L2 RPC:       $L2_RPC"
echo "op-geth path: $OP_GETH_PATH"
echo ""

(
  cd "$SCRIPT_DIR"
  go run . "${ARGS[@]}"
)
