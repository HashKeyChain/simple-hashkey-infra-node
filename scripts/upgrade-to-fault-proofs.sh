#!/bin/bash
#
# 将已部署的 L2OutputOracle 链升级为 PermissionedDisputeGame（Fault Proofs）。
# 要求：L1 与 op-node 已运行，且已完成首次部署（L2OutputOracle）。
#
# 用法:
#   bash scripts/upgrade-to-fault-proofs.sh [local|server]
#
# 步骤:
#   1. 更新 deploy config：useFaultProofs=true, respectedGameType=1 (PERMISSIONED_CANNON)
#   2. 升级 OptimismPortal 代理为 OptimismPortal2
#   3. 初始化 AnchorStateRegistry（需 op-node 提供 genesis 输出根）
#   4. 在 DisputeGameFactory 中设置 PermissionedDisputeGame 实现
#   5. 更新 .envrc 中 USE_FAULT_PROOFS=true, GAME_TYPE=1
#
# 合约版本：使用 .envrc 中 OP_CONTRACTS_REF（建议 v2.0.0-beta.2 或 v2.0.0-beta.3）。
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi

if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/local"
  export DEPLOY_CONFIG_PATH="$CONTRACTS_BEDROCK_PATH/deploy-config/local.json"
else
  export DEPLOY_CONFIG_PATH="${DEPLOY_CONFIG_PATH:-$CONTRACTS_BEDROCK_PATH/deploy-config/$DEPLOYMENT_CONTEXT.json}"
fi

# forge 只能写 contracts-bedrock/deployments/，所以 artifact 统一放这里
FORGE_ARTIFACT="$CONTRACTS_BEDROCK_PATH/deployments/artifact.json"
USER_ARTIFACT="${DEPLOYMENT_CONFIG_PATH:-$CONTRACTS_BEDROCK_PATH/deployments}/artifact.json"

echo "=== Upgrade to PermissionedDisputeGame (Fault Proofs) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "DEPLOY_CONFIG_PATH=$DEPLOY_CONFIG_PATH"
echo "USER_ARTIFACT=$USER_ARTIFACT"
echo ""

# 检查 L1 和 op-node
if ! curl -sf --connect-timeout 2 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "$L1_RPC_URL" >/dev/null; then
  echo "Error: L1 RPC not reachable at $L1_RPC_URL. Start L1 first."
  exit 1
fi
if ! curl -sf --connect-timeout 2 -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "http://localhost:9545" >/dev/null; then
  echo "Error: op-node RPC not reachable. Start chain (op-node) first."
  exit 1
fi

if [ ! -f "$USER_ARTIFACT" ]; then
  echo "Error: artifact not found at $USER_ARTIFACT. Run chain-setup first."
  exit 1
fi

# 拷贝 artifact 到 forge 可写目录
cp "$USER_ARTIFACT" "$FORGE_ARTIFACT"
export DEPLOYMENT_OUTFILE="$FORGE_ARTIFACT"

# 更新 deploy config：useFaultProofs=true, respectedGameType=1 (PERMISSIONED_CANNON)
if [ ! -f "$DEPLOY_CONFIG_PATH" ]; then
  echo "Error: deploy config not found at $DEPLOY_CONFIG_PATH"
  exit 1
fi
echo "Updating deploy config (useFaultProofs=true, respectedGameType=1)..."
jq '. + {"useFaultProofs": true, "respectedGameType": 1}' "$DEPLOY_CONFIG_PATH" > "$DEPLOY_CONFIG_PATH.tmp" && mv "$DEPLOY_CONFIG_PATH.tmp" "$DEPLOY_CONFIG_PATH"

# 进入合约目录（不 checkout ref，保留本地对 OptimismPortal2/Deploy.s.sol 的修改）
cd "$CONTRACTS_BEDROCK_PATH"

export CONTRACT_ADDRESSES_PATH="$DEPLOYMENT_OUTFILE"

# ---------- Step 0a: 部署新的 OptimismPortal2 实现（包含 reinitialize 方法） ----------
PORTAL_PROXY=$(jq -r '.OptimismPortalProxy' "$DEPLOYMENT_OUTFILE")
PORTAL_VERSION=$(cast call --rpc-url "$L1_RPC_URL" "$PORTAL_PROXY" "version()(string)" 2>/dev/null || echo "unknown")
# cast 可能返回带引号的字符串，去掉引号再比较
PORTAL_VERSION=$(echo "$PORTAL_VERSION" | tr -d '"')
# 也检查 _initialized 存储值（slot 0 最低字节）
PORTAL_SLOT0=$(cast storage --rpc-url "$L1_RPC_URL" "$PORTAL_PROXY" 0 2>/dev/null || echo "0x01")
PORTAL_INIT_BYTE="${PORTAL_SLOT0: -2}"
echo ""
echo "Step 0a: deployOptimismPortal2()"
echo "  proxy version: '$PORTAL_VERSION', _initialized byte: 0x$PORTAL_INIT_BYTE"

if echo "$PORTAL_VERSION" | grep -q "3.10.0" || [ "$PORTAL_INIT_BYTE" = "02" ]; then
  echo "  OptimismPortal2 proxy already upgraded — skipping deploy & upgrade."
else
  echo "  Removing old OptimismPortal2 from artifact to allow re-deploy..."
  jq 'del(.OptimismPortal2)' "$DEPLOYMENT_OUTFILE" > "$DEPLOYMENT_OUTFILE.tmp" \
    && mv "$DEPLOYMENT_OUTFILE.tmp" "$DEPLOYMENT_OUTFILE"

  export IMPL_SALT="opfp-upgrade-$(date +%s)"
  forge script scripts/Deploy.s.sol:Deploy \
    --private-key "$GS_ADMIN_PRIVATE_KEY" \
    --broadcast \
    --rpc-url "$L1_RPC_URL" \
    --sig "deployOptimismPortal2()" \
    --skip-simulation

  # ---------- Step 0b: 升级 OptimismPortal 代理为 OptimismPortal2（使用 reinitialize） ----------
  echo ""
  echo "Step 0b: initializeOptimismPortal2() ..."
  forge script scripts/Deploy.s.sol:Deploy \
    --private-key "$GS_ADMIN_PRIVATE_KEY" \
    --broadcast \
    --rpc-url "$L1_RPC_URL" \
    --sig "initializeOptimismPortal2()" \
    --skip-simulation
fi

# ---------- Step 1a: 部署新的 AnchorStateRegistry 实现（包含 reinitialize 方法） ----------
echo ""
echo "Step 1a: deployAnchorStateRegistry() — deploying new implementation with reinitialize()..."
echo "  Removing old AnchorStateRegistry from artifact to allow re-deploy..."
jq 'del(.AnchorStateRegistry)' "$DEPLOYMENT_OUTFILE" > "$DEPLOYMENT_OUTFILE.tmp" \
  && mv "$DEPLOYMENT_OUTFILE.tmp" "$DEPLOYMENT_OUTFILE"

export IMPL_SALT="opfp-anchor-$(date +%s)"
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "deployAnchorStateRegistry()" \
  --skip-simulation

# ---------- Step 1b: 初始化 AnchorStateRegistry（从 op-node 取 genesis 输出根） ----------
echo ""
echo "Step 1b: initializeAnchorStateRegistry() ..."
bash "$SCRIPT_DIR/initialize-anchorState.sh"

# ---------- Step 2a: 从 Safe 取回 DisputeGameFactory ownership ----------
echo ""
echo "Step 2a: reclaimDisputeGameFactoryOwnership() ..."
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "reclaimDisputeGameFactoryOwnership()" \
  --skip-simulation

# ---------- Step 2b: 设置 PermissionedDisputeGame 实现 ----------
echo ""
echo "Step 2b: setPermissionedCannonFaultGameImplementation(true) ..."
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "setPermissionedCannonFaultGameImplementation(bool)" true \
  --skip-simulation

# ---------- Step 2c: 把 ownership 转回 Safe ----------
echo ""
echo "Step 2c: transferDisputeGameFactoryOwnership() ..."
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "transferDisputeGameFactoryOwnership()" \
  --skip-simulation

cd "$BASE_PATH"

# 拷回 artifact 到用户配置目录
if [ "$FORGE_ARTIFACT" != "$USER_ARTIFACT" ]; then
  cp "$FORGE_ARTIFACT" "$USER_ARTIFACT"
  echo "Artifact synced back to $USER_ARTIFACT"
fi

# 4. 更新 .envrc
echo ""
echo "Step 4: Updating .envrc (USE_FAULT_PROOFS=true, GAME_TYPE=1) ..."
if grep -q '^export USE_FAULT_PROOFS=' .envrc 2>/dev/null; then
  sed -i.bak 's/^export USE_FAULT_PROOFS=.*/export USE_FAULT_PROOFS=true/' .envrc
else
  echo 'export USE_FAULT_PROOFS=true' >> .envrc
fi
if grep -q '^export GAME_TYPE=' .envrc 2>/dev/null; then
  sed -i.bak 's/^export GAME_TYPE=.*/export GAME_TYPE=1/' .envrc
else
  echo 'export GAME_TYPE=1' >> .envrc
fi
rm -f .envrc.bak

echo ""
echo "=== Upgrade complete ==="
echo "  - USE_FAULT_PROOFS=true, GAME_TYPE=1 (PERMISSIONED_CANNON)"
echo "  - Restart op-proposer so it uses DisputeGameFactory."
echo "  - Optional: bash scripts/chain-stop.sh && bash scripts/chain-start.sh $CHAIN_ENV"
echo ""
