#!/bin/bash
#
# 用 beta.3 合约代码升级已部署链上的 OptimismPortal2 与 AnchorStateRegistry 实现：
#   1. 在 beta.3 目录编译并部署新的 OptimismPortal2 impl（含 reinitialize）
#   2. 在 beta.3 目录编译并部署新的 AnchorStateRegistry impl（含 reinitialize）
#   3. 通过 SystemOwnerSafe -> ProxyAdmin.upgradeAndCall，让 OptimismPortalProxy /
#      AnchorStateRegistryProxy 指向新 impl，并执行 reinitialize(2)
#
# 用法:
#   bash scripts/upgrade-portal-asr-beta3.sh [local|server]
#
# 前置条件:
#   - L1 (anvil 或真实 L1) 与 op-node 已运行
#   - 已完成首次 beta.2 部署，config/<ctx>/artifact.json 存在
#   - SystemOwnerSafe threshold=1 且 GS_ADMIN 是唯一 owner
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

# Allow upgrading a deployment context that differs from .envrc without editing .envrc.
if [ -n "${UPGRADE_DEPLOYMENT_CONTEXT:-}" ]; then
  DEPLOYMENT_CONTEXT="$UPGRADE_DEPLOYMENT_CONTEXT"
  DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
fi

CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
fi

if [ "$CHAIN_ENV" = "local" ]; then
  L1_RPC_URL="http://localhost:8545"
  DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/local"
else
  DEPLOYMENT_CONFIG_PATH="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
fi

OP_NODE_RPC_URL="${OP_NODE_RPC_URL:-http://localhost:${OP_ROLLUP_PORT:-9545}}"
ARTIFACT="$DEPLOYMENT_CONFIG_PATH/artifact.json"
BETA3_DIR="$BASE_PATH/optimism-v2.0.0-beta.3/packages/contracts-bedrock"

echo "=== Upgrade OptimismPortal2 + AnchorStateRegistry to beta.3 ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "OP_NODE_RPC_URL=$OP_NODE_RPC_URL"
echo "ARTIFACT=$ARTIFACT"
echo "BETA3_DIR=$BETA3_DIR"
echo ""

# ---- 基础检查 ----
[ -f "$ARTIFACT" ] || { echo "Error: artifact not found at $ARTIFACT"; exit 1; }
[ -d "$BETA3_DIR" ] || { echo "Error: beta.3 contracts dir not found at $BETA3_DIR"; exit 1; }

curl -sf --connect-timeout 3 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L1_RPC_URL" >/dev/null \
  || { echo "Error: L1 RPC not reachable at $L1_RPC_URL"; exit 1; }

# ---- 从 artifact 读地址 ----
export OPTIMISM_PORTAL_PROXY=$(jq -r '.OptimismPortalProxy' "$ARTIFACT")
export ASR_PROXY=$(jq -r '.AnchorStateRegistryProxy' "$ARTIFACT")
export DGF_PROXY=$(jq -r '.DisputeGameFactoryProxy' "$ARTIFACT")
export SYSTEM_CONFIG_PROXY=$(jq -r '.SystemConfigProxy' "$ARTIFACT")
export SUPERCHAIN_CONFIG_PROXY=$(jq -r '.SuperchainConfigProxy' "$ARTIFACT")
export PROXY_ADMIN=$(jq -r '.ProxyAdmin' "$ARTIFACT")
export SYSTEM_OWNER_SAFE=$(jq -r '.SystemOwnerSafe' "$ARTIFACT")

# ---- 升级参数（本地快测：12s/12s；可用环境变量覆盖）----
export PROOF_MATURITY_DELAY_SECONDS="${PROOF_MATURITY_DELAY_SECONDS:-12}"
export DISPUTE_GAME_FINALITY_DELAY_SECONDS="${DISPUTE_GAME_FINALITY_DELAY_SECONDS:-12}"
export RESPECTED_GAME_TYPE="${RESPECTED_GAME_TYPE:-1}"   # 1 = PERMISSIONED_CANNON

# ---- 取 genesis output root（block 0）作为 anchor ----
export FAULT_GAME_GENESIS_BLOCK="${FAULT_GAME_GENESIS_BLOCK:-0}"
if [ -n "${FAULT_GAME_GENESIS_OUTPUT_ROOT:-}" ]; then
  echo "Using provided output root for L2 block $FAULT_GAME_GENESIS_BLOCK."
else
  GENESIS_HEX=$(printf '0x%x' "$FAULT_GAME_GENESIS_BLOCK")
  echo "Fetching output root at L2 block $FAULT_GAME_GENESIS_BLOCK from op-node..."
  OUT=$(curl -sf "$OP_NODE_RPC_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"optimism_outputAtBlock\",\"params\":[\"${GENESIS_HEX}\"],\"id\":1}")
  export FAULT_GAME_GENESIS_OUTPUT_ROOT=$(echo "$OUT" | jq -r '.result.outputRoot // empty')
  [ -n "$FAULT_GAME_GENESIS_OUTPUT_ROOT" ] || { echo "Error: failed to get output root. Resp: $OUT"; exit 1; }
fi
echo "  anchor outputRoot: $FAULT_GAME_GENESIS_OUTPUT_ROOT"

# ---- 签名 key（必须是 Safe 唯一 owner）----
export DEPLOY_OR_ADMIN_KEY="${GS_ADMIN_PRIVATE_KEY}"

echo ""
echo "Addresses:"
echo "  OptimismPortalProxy=$OPTIMISM_PORTAL_PROXY"
echo "  ASRProxy=$ASR_PROXY"
echo "  DGFProxy=$DGF_PROXY"
echo "  SystemConfigProxy=$SYSTEM_CONFIG_PROXY"
echo "  SuperchainConfigProxy=$SUPERCHAIN_CONFIG_PROXY"
echo "  ProxyAdmin=$PROXY_ADMIN"
echo "  SystemOwnerSafe=$SYSTEM_OWNER_SAFE"
echo "Params: proofMaturity=$PROOF_MATURITY_DELAY_SECONDS finality=$DISPUTE_GAME_FINALITY_DELAY_SECONDS respectedGameType=$RESPECTED_GAME_TYPE"
echo ""

# ---- 执行 forge 升级脚本 ----
cd "$BETA3_DIR"
forge script scripts/hsk-upgrade/UpgradePortalAndASR.s.sol:UpgradePortalAndASR \
  --rpc-url "$L1_RPC_URL" \
  --broadcast \
  --skip-simulation \
  -vvv

cd "$BASE_PATH"
echo ""
echo "=== Upgrade script finished. Verifying on-chain... ==="
PORTAL_VER=$(cast call --rpc-url "$L1_RPC_URL" "$OPTIMISM_PORTAL_PROXY" "version()(string)" 2>/dev/null || echo "n/a")
ASR_VER=$(cast call --rpc-url "$L1_RPC_URL" "$ASR_PROXY" "version()(string)" 2>/dev/null || echo "n/a")
echo "  OptimismPortalProxy version: $PORTAL_VER  (expect 3.11.0-beta.4)"
echo "  AnchorStateRegistryProxy version: $ASR_VER  (expect 2.0.1-beta.2)"
echo ""
echo "Done."
