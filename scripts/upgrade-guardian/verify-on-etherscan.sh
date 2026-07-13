#!/usr/bin/env bash
#
# 独立 verify 脚本：把已部署的 SuperchainConfigWithSetGuardian impl 在 Etherscan
# 上做 source code verification。
#
# 适用场景：
#   - deploy-impl.sh 跑完但 verify 失败（网络/Etherscan API 抽风等）
#   - 当时 deploy 时没设 ETHERSCAN_API_KEY
#
# 必需环境变量：
#   ETHERSCAN_API_KEY   - Etherscan v2 API key
#
# 可选：
#   IMPL_ADDRESS        - 默认从 deployed.json 读 newImpl
#   WT                  - 默认 worktree 路径
#   OUT_FILE            - 默认 deployed.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
WT="${WT:-$REPO_ROOT/optimism-v2.0.0-beta.3/packages/contracts-bedrock}"

if [ -z "${ETHERSCAN_API_KEY:-}" ]; then
  echo "ERROR: 缺少环境变量 ETHERSCAN_API_KEY" >&2
  exit 1
fi

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE。请先运行 deploy-impl.sh" >&2
  exit 1
fi

if [ -z "${IMPL_ADDRESS:-}" ]; then
  IMPL_ADDRESS=$(jq -r '.addresses.newImpl' "$OUT_FILE")
fi

# 永远从 deployed.json 读 chainId，避免 shell 里有 .envrc 之类的残留 CHAIN_ID 变量被误用
CHAIN_ID=$(jq -r '.chainId' "$OUT_FILE")
if [ -z "$CHAIN_ID" ] || [ "$CHAIN_ID" = "null" ]; then
  echo "ERROR: deployed.json 里没有 chainId 字段" >&2
  exit 1
fi

# Etherscan v2 mainnet/各 L1 都通过 chainId 区分，但 HSK L2 之类不在它支持列表
if [ "$CHAIN_ID" != "1" ]; then
  echo "WARNING: 当前 deployed.json chainId=$CHAIN_ID，可能不在 Etherscan 支持列表里" >&2
fi

echo "================================================================"
echo " Verifying $IMPL_ADDRESS on Etherscan (chain $CHAIN_ID)"
echo "================================================================"
echo ""

# 用编译时同样的参数跑 verify-contract（forge 会重新编译以确保 metadata 一致）
( cd "$WT" && forge verify-contract \
    --chain "$CHAIN_ID" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --watch \
    "$IMPL_ADDRESS" \
    src/redeploy/SuperchainConfigWithSetGuardian.sol:SuperchainConfigWithSetGuardian \
)

echo ""
echo "Etherscan: https://etherscan.io/address/$IMPL_ADDRESS#code"
