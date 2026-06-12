#!/usr/bin/env bash
set -euo pipefail

# Run the EIP-7702 verification using scripts/jovian/verify/verify.env.
#
# Usage:
#   bash scripts/jovian/verify/verify-7702.sh [delegate_address]
#
# Defaults:
#   L2 RPC            = $L2_RPC from verify.env
#   payer private key = $L2_VERIFY_PRIVATE_KEY from verify.env
#   delegate_address  = empty, which deploys EIP7702Delegate.sol first

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../../.." && pwd)
EIP7702_DIR="$SCRIPT_DIR/../7702"
cd "$BASE_PATH"

if [ ! -f "$SCRIPT_DIR/verify.env" ]; then
  echo "ERROR: missing $SCRIPT_DIR/verify.env. Copy verify.env.example to verify.env and fill it first."
  exit 1
fi
source "$SCRIPT_DIR/verify.env"

L2_RPC="${L2_RPC:?missing L2_RPC in verify.env}"
L2_VERIFY_PRIVATE_KEY="${L2_VERIFY_PRIVATE_KEY:?missing L2_VERIFY_PRIVATE_KEY in verify.env}"
DELEGATE_ADDRESS="${1:-}"

if [ "$L2_RPC" = "https://REPLACE_ME_L2_RPC" ] || [ "$L2_VERIFY_PRIVATE_KEY" = "0xREPLACE_ME" ]; then
  echo "ERROR: set L2_RPC and L2_VERIFY_PRIVATE_KEY before running."
  exit 1
fi

if [ ! -d "$EIP7702_DIR" ]; then
  echo "ERROR: EIP-7702 verifier directory not found: $EIP7702_DIR"
  exit 1
fi

ARGS=(
  "--rpc" "$L2_RPC"
  "--payer-private-key" "$L2_VERIFY_PRIVATE_KEY"
  "--require-isthmus=false"
  "--require-jovian=false"
)

if [ -n "$DELEGATE_ADDRESS" ]; then
  ARGS+=("--delegate-address" "$DELEGATE_ADDRESS")
else
  if ! command -v forge >/dev/null 2>&1; then
    echo "ERROR: forge is required to compile EIP7702Delegate.sol"
    exit 1
  fi

  DELEGATE_BYTECODE=$(cd "$EIP7702_DIR" && forge inspect EIP7702Delegate bytecode)
  if [ -z "$DELEGATE_BYTECODE" ] || [ "$DELEGATE_BYTECODE" = "0x" ]; then
    echo "ERROR: failed to compile EIP7702Delegate.sol"
    exit 1
  fi
  ARGS+=("--delegate-bytecode" "$DELEGATE_BYTECODE")
fi

echo "============================================"
echo "  EIP-7702 Verification"
echo "============================================"
echo "L2 RPC: $L2_RPC"
echo ""

(
  cd "$EIP7702_DIR"
  go run . "${ARGS[@]}"
)
