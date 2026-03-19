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
  export DEPLOYMENT_OUTFILE="$DEPLOYMENT_CONFIG_PATH/artifact.json"
  export DEPLOY_CONFIG_PATH="$CONTRACTS_BEDROCK_PATH/deploy-config/local.json"
else
  export DEPLOYMENT_OUTFILE="${DEPLOYMENT_OUTFILE:-$CONTRACTS_BEDROCK_PATH/deployments/artifact.json}"
  export DEPLOY_CONFIG_PATH="${DEPLOY_CONFIG_PATH:-$CONTRACTS_BEDROCK_PATH/deploy-config/$DEPLOYMENT_CONTEXT.json}"
fi

echo "=== Upgrade to PermissionedDisputeGame (Fault Proofs) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "DEPLOYMENT_OUTFILE=$DEPLOYMENT_OUTFILE"
echo "DEPLOY_CONFIG_PATH=$DEPLOY_CONFIG_PATH"
echo ""

# 检查 L1 和 op-node
if ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; then
  echo "Error: L1 RPC not reachable at $L1_RPC_URL. Start L1 first."
  exit 1
fi
if ! curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "$OP_NODE_RPC_URL" &>/dev/null; then
  echo "Error: op-node RPC not reachable at $OP_NODE_RPC_URL. Start chain (op-node) first."
  exit 1
fi

if [ ! -f "$DEPLOYMENT_OUTFILE" ]; then
  echo "Error: artifact not found at $DEPLOYMENT_OUTFILE. Run chain-setup first."
  exit 1
fi

# 更新 deploy config：useFaultProofs=true, respectedGameType=1 (PERMISSIONED_CANNON)
if [ ! -f "$DEPLOY_CONFIG_PATH" ]; then
  echo "Error: deploy config not found at $DEPLOY_CONFIG_PATH"
  exit 1
fi
echo "Updating deploy config (useFaultProofs=true, respectedGameType=1)..."
jq '. + {"useFaultProofs": true, "respectedGameType": 1}' "$DEPLOY_CONFIG_PATH" > "$DEPLOY_CONFIG_PATH.tmp" && mv "$DEPLOY_CONFIG_PATH.tmp" "$DEPLOY_CONFIG_PATH"

# 进入合约目录并确保版本
cd "$CONTRACTS_BEDROCK_PATH"
rm -rf lib/openzeppelin-contracts-v5 lib/solady-v0.0.245 lib/superchain-registry 2>/dev/null || true
git checkout "$OP_CONTRACTS_REF"

export CONTRACT_ADDRESSES_PATH="$DEPLOYMENT_OUTFILE"

# 1. 升级 OptimismPortal 代理为 OptimismPortal2
echo ""
echo "Step 1: initializeOptimismPortal2() ..."
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "initializeOptimismPortal2()" \
  --skip-simulation

# 2. 初始化 AnchorStateRegistry（从 op-node 取 genesis 输出根）
echo ""
echo "Step 2: initializeAnchorStateRegistry() ..."
bash "$SCRIPT_DIR/initialize-anchorState.sh"

# 3. 设置 PermissionedDisputeGame 实现
echo ""
echo "Step 3: setPermissionedCannonFaultGameImplementation(true) ..."
forge script scripts/Deploy.s.sol:Deploy \
  --private-key "$GS_ADMIN_PRIVATE_KEY" \
  --broadcast \
  --rpc-url "$L1_RPC_URL" \
  --sig "setPermissionedCannonFaultGameImplementation(bool)" \
  --sig-args true \
  --skip-simulation

cd "$BASE_PATH"

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
