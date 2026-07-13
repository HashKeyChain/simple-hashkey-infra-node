#!/usr/bin/env bash
#
# 在 ETH mainnet 上部署一份 SuperchainConfigWithSetGuardian impl，
# 用于 transient upgrade 模式临时改 SuperchainConfigProxy.guardian。
#
# 必需环境变量：
#   DEPLOYER_PK         - L1（ETH mainnet）部署账户私钥，需要约 0.01 ETH gas
#
# 可选环境变量：
#   ETHERSCAN_API_KEY   - 给了的话部署完会顺便提交 verified source 到 Etherscan
#   L1_RPC_URL          默认 https://ethereum-rpc.publicnode.com
#   WT                  默认 项目内 worktree 路径
#   OUT_FILE            默认 同目录下 deployed.json
#
# 部署后写一份 deployed.json，供 safe-batch.sh / verify.sh 消费。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

L1_RPC_URL="${L1_RPC_URL:-https://ethereum-rpc.publicnode.com}"
WT="${WT:-$REPO_ROOT/optimism-v2.0.0-beta.3/packages/contracts-bedrock}"
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"

# 已知 mainnet 上的合约地址
SC_PROXY=0xfd1255b6c09D939E7F3896A16C32CDBCD6F8B40A
SC_PROXY_ADMIN=0x7986ed289935a0f47fc434c00cde309fe2c51f1c
ORIGINAL_IMPL=0x1d31a15050dbe75c6c060d6da696332a5cb943e1
PAO_SAFE=0x441F31C4cdf772558D4EA31f3114de59aE145E7c

# 防呆：必须是 ETH mainnet（chain 1），否则上面那些 mainnet 合约地址全是查不到的
ACTUAL_CHAIN_ID=$(cast chain-id --rpc-url "$L1_RPC_URL" 2>&1 || true)
if [ "$ACTUAL_CHAIN_ID" != "1" ]; then
  echo "ERROR: L1_RPC_URL 指向的不是 ETH mainnet (chain 1)" >&2
  echo "  L1_RPC_URL = $L1_RPC_URL" >&2
  echo "  detected chainId = $ACTUAL_CHAIN_ID" >&2
  echo "" >&2
  echo "  请 export L1_RPC_URL=https://ethereum-rpc.publicnode.com  （或其他 mainnet RPC）" >&2
  echo "  如果 shell 里残留了 .envrc 的 testnet URL，先 unset L1_RPC_URL 即可。" >&2
  exit 1
fi

if [ -z "${DEPLOYER_PK:-}" ]; then
  echo "ERROR: 缺少环境变量 DEPLOYER_PK（ETH mainnet 部署账户私钥）" >&2
  exit 1
fi

# Etherscan verify 是可选的（没 API key 也照样部署，只是少了源码验证）
VERIFY_ARGS=()
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  VERIFY_ARGS=(--verify --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY")
  VERIFY_HINT="✅ 启用 (将提交 verified source 到 Etherscan)"
else
  VERIFY_HINT="⚠️  跳过 (没设 ETHERSCAN_API_KEY)"
fi

if [ ! -f "$WT/forge-artifacts/SuperchainConfigWithSetGuardian.sol/SuperchainConfigWithSetGuardian.json" ]; then
  echo "ERROR: 还没编译。请先在 worktree 里跑：" >&2
  echo "  cd $WT && forge build --use 0.8.15 src/redeploy/SuperchainConfigWithSetGuardian.sol" >&2
  exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PK")
BAL_WEI=$(cast balance --rpc-url "$L1_RPC_URL" "$DEPLOYER")
BAL_ETH=$(cast --to-unit "$BAL_WEI" ether)

# Sanity check：链上当前实际状态
CURRENT_IMPL_RAW=$(cast storage --rpc-url "$L1_RPC_URL" "$SC_PROXY" \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
CURRENT_IMPL="0x${CURRENT_IMPL_RAW: -40}"
CURRENT_GUARDIAN=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY" 'guardian()(address)')
PA_OWNER=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY_ADMIN" 'owner()(address)')

echo "================================================================"
echo " Deploy SuperchainConfigWithSetGuardian on ETH mainnet"
echo "================================================================"
echo "  L1 RPC:           $L1_RPC_URL  (chain $(cast chain-id --rpc-url "$L1_RPC_URL"))"
echo "  Deployer:         $DEPLOYER"
echo "  Deployer balance: $BAL_ETH ETH"
echo ""
echo "  目标 SuperchainConfigProxy:    $SC_PROXY"
echo "    current implementation:    $CURRENT_IMPL"
echo "    expect ORIGINAL_IMPL  =    $ORIGINAL_IMPL"
echo "    current guardian:          $CURRENT_GUARDIAN"
echo ""
echo "  ProxyAdmin:                    $SC_PROXY_ADMIN"
echo "    owner (= PAO Safe):        $PA_OWNER"
echo "    expect PAO_SAFE       =    $PAO_SAFE"
echo ""
echo "  Etherscan verify:           $VERIFY_HINT"
echo "================================================================"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ "$(lc "$CURRENT_IMPL")" != "$(lc "$ORIGINAL_IMPL")" ]; then
  echo "WARNING: 当前 SuperchainConfig impl 不是预期的 ORIGINAL_IMPL"
  echo "         实际:  $CURRENT_IMPL"
  echo "         预期:  $ORIGINAL_IMPL"
  echo "         如果你已经是新版本/有别的部署，请先确认"
fi
if [ "$(lc "$PA_OWNER")" != "$(lc "$PAO_SAFE")" ]; then
  echo "WARNING: ProxyAdmin owner 不是预期的 PAO Safe"
  echo "         实际: $PA_OWNER"
  echo "         预期: $PAO_SAFE"
fi

read -r -p "Proceed with deployment? (y/N) " ans
[ "$ans" = "y" ] || { echo "Aborted."; exit 0; }

echo ""
echo "==> Deploying..."
LOG=$(mktemp)
# 临时关掉 errexit/pipefail：forge create 在 verify 阶段失败也会非 0 退出，
# 但部署本身可能已经成功，我们要继续解析 LOG 拿到 newImpl 地址再决定后续动作
set +e
( cd "$WT" && forge create --rpc-url "$L1_RPC_URL" \
    --private-key "$DEPLOYER_PK" \
    --broadcast \
    "${VERIFY_ARGS[@]}" \
    src/redeploy/SuperchainConfigWithSetGuardian.sol:SuperchainConfigWithSetGuardian \
) 2>&1 | tee "$LOG"
set -e

NEW_IMPL=$(grep -E '^Deployed to:' "$LOG" | head -1 | awk '{print $3}')
TX=$(grep -E '^Transaction hash:' "$LOG" | head -1 | awk '{print $3}')

if [ -z "$NEW_IMPL" ]; then
  echo "ERROR: 部署失败" >&2
  exit 1
fi

# 解析 verify 结果（forge create --verify 会在末尾打印 "Successfully verified contract" 或类似）
VERIFY_STATUS="not-attempted"
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  if grep -qE 'Successfully verified contract|Pass - Verified' "$LOG"; then
    VERIFY_STATUS="success"
  elif grep -qE 'Already Verified' "$LOG"; then
    VERIFY_STATUS="already-verified"
  elif grep -qE 'Invalid API Key' "$LOG"; then
    VERIFY_STATUS="failed-invalid-api-key (export 一个真正的 ETHERSCAN_API_KEY 后跑 verify-on-etherscan.sh)"
  elif grep -qiE 'fail|error' "$LOG"; then
    VERIFY_STATUS="failed (见上面日志，可用 verify-on-etherscan.sh 重试)"
  else
    VERIFY_STATUS="unknown (forge 输出未识别，建议手动确认 https://etherscan.io/address/$NEW_IMPL#code)"
  fi
  echo ""
  echo "==> Etherscan verify status: $VERIFY_STATUS"
fi

# Sanity check：新 impl 直接调 guardian() 应该返回 0（因为 impl 自己 storage 里 GUARDIAN_SLOT=0）
NEW_IMPL_GUARDIAN=$(cast call --rpc-url "$L1_RPC_URL" "$NEW_IMPL" 'guardian()(address)')
NEW_IMPL_VERSION=$(cast call --rpc-url "$L1_RPC_URL" "$NEW_IMPL" 'version()(string)')

# 写 deployed.json
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$OUT_FILE" <<EOF
{
  "timestamp": "$TS",
  "chainId": $(cast chain-id --rpc-url "$L1_RPC_URL"),
  "rpcUrl": "$L1_RPC_URL",
  "deployer": "$DEPLOYER",
  "deployTx": "$TX",
  "etherscanVerify": "$VERIFY_STATUS",
  "addresses": {
    "newImpl":              "$NEW_IMPL",
    "originalImpl":         "$ORIGINAL_IMPL",
    "superchainConfigProxy": "$SC_PROXY",
    "superchainConfigProxyAdmin": "$SC_PROXY_ADMIN",
    "paoSafe":              "$PAO_SAFE"
  },
  "newImplSelfChecks": {
    "version":   $NEW_IMPL_VERSION,
    "guardian":  "$NEW_IMPL_GUARDIAN"
  }
}
EOF

echo ""
echo "================================================================"
echo " DEPLOYMENT SUCCEEDED"
echo "================================================================"
cat "$OUT_FILE"
echo ""
echo "  Etherscan: https://etherscan.io/address/$NEW_IMPL#code"
echo ""
echo "下一步：bash scripts/upgrade-guardian/safe-batch.sh <NEW_GUARDIAN>"
