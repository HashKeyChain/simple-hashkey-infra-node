#!/usr/bin/env bash
#
# 在 HSK mainnet L2 上重新部署 3 个 FeeVault 实现合约
# （op-contracts/v2.0.0-beta.3，字节码已与 mainnet 现 impl 校验一致）
#
# 必需环境变量：
#   L2_DEPLOY_PK    - L2 部署账户私钥（需要少量 HSK 付 gas）
#
# 可选环境变量（缺省为本次需求的目标值）：
#   L2_RPC_URL          默认 https://mainnet.hsk.xyz
#   NEW_RECIPIENT       默认 0xe9d87622269c6490d776be2f6ab5dcc9ecf76fde
#   MIN_WITHDRAWAL_WEI  默认 10000000000000000000   (10 HSK = 1e19 wei)
#   WITHDRAWAL_NETWORK  默认 1                        (0=L1, 1=L2)
#   WT                  默认 项目内 worktree 路径
#   OUT_FILE            默认 同目录下 deployed.json
#   GAS_LIMIT           不设则用 forge create 自动 estimate；想保守可显式设个值，例如 2000000
#
# 用法：
#   export L2_DEPLOY_PK=0x....
#   bash scripts/redeploy-fee-vaults/deploy.sh
#
# 部署完成后会写一个 deployed.json，供 safe-batch.sh 消费。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ----- 默认参数 -----
L2_RPC_URL="${L2_RPC_URL:-https://mainnet.hsk.xyz}"
NEW_RECIPIENT="${NEW_RECIPIENT:-0xe9d87622269c6490d776be2f6ab5dcc9ecf76fde}"
MIN_WITHDRAWAL_WEI="${MIN_WITHDRAWAL_WEI:-10000000000000000000}"
WITHDRAWAL_NETWORK="${WITHDRAWAL_NETWORK:-1}"
WT="${WT:-$REPO_ROOT/optimism-v2.0.0-beta.3/packages/contracts-bedrock}"
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
# forge 1.5+ 的 forge create 没有 --gas-estimate-multiplier；想保守留 buffer 就显式设 GAS_LIMIT
GAS_LIMIT="${GAS_LIMIT:-}"
if [ -n "${GAS_BUFFER_PCT:-}" ]; then
  echo "NOTE: GAS_BUFFER_PCT 在 forge 1.5+ 的 forge create 里没有等价开关，已忽略。" >&2
  echo "      如想保守留 gas 余量，请直接设置 GAS_LIMIT=<gas>（例如 2000000）。" >&2
fi

# ----- 校验 -----
if [ -z "${L2_DEPLOY_PK:-}" ]; then
  echo "ERROR: 缺少环境变量 L2_DEPLOY_PK（部署账户私钥）" >&2
  exit 1
fi

if [ ! -d "$WT" ]; then
  echo "ERROR: worktree 不存在: $WT" >&2
  echo "       请先在 optimism submodule 上 'git worktree add ... op-contracts/v2.0.0-beta.3'" >&2
  exit 1
fi

if [ ! -f "$WT/forge-artifacts/BaseFeeVault.sol/BaseFeeVault.json" ]; then
  echo "ERROR: 还没编译。请在 $WT 下跑：" >&2
  echo "       forge build --use 0.8.15 src/L2/BaseFeeVault.sol src/L2/L1FeeVault.sol src/L2/SequencerFeeVault.sol" >&2
  exit 1
fi

# ----- 派生部署者地址 + 余额检查 -----
DEPLOYER=$(cast wallet address --private-key "$L2_DEPLOY_PK")
BAL_WEI=$(cast balance --rpc-url "$L2_RPC_URL" "$DEPLOYER")
BAL_HSK=$(cast --to-unit "$BAL_WEI" ether)

echo "================================================================"
echo " FeeVault Re-deploy on HSK mainnet L2"
echo "================================================================"
echo "  L2 RPC:           $L2_RPC_URL  (chain $(cast chain-id --rpc-url "$L2_RPC_URL"))"
echo "  Deployer:         $DEPLOYER"
echo "  Deployer balance: $BAL_HSK HSK"
echo ""
echo "  Constructor args (3 个 vault 都用同一组):"
echo "    _recipient           = $NEW_RECIPIENT"
echo "    _minWithdrawalAmount = $MIN_WITHDRAWAL_WEI wei"
echo "                         = $(cast --to-unit "$MIN_WITHDRAWAL_WEI" ether) HSK"
echo "    _withdrawalNetwork   = $WITHDRAWAL_NETWORK  ($([ "$WITHDRAWAL_NETWORK" = "0" ] && echo L1 || echo L2))"
echo ""
echo "  Worktree: $WT"
echo "  Output:   $OUT_FILE"
echo "================================================================"
echo ""

# 0.001 HSK = 1e15 wei，每个合约部署 ~0.0005 HSK，3 个共 ~0.002 HSK
MIN_BAL_WEI=2000000000000000  # 0.002 HSK
if [ "$(echo "$BAL_WEI" | sed 's/[^0-9]//g')" -lt "$MIN_BAL_WEI" ] 2>/dev/null; then
  echo "WARNING: 部署账户余额不足 0.002 HSK，部署可能失败"
  echo "         （如果你确认 gas 够，请回车继续）"
  read -r -p "继续？(y/N) " ans
  [ "$ans" = "y" ] || exit 1
fi

read -r -p "Proceed with deployment? (y/N) " ans
[ "$ans" = "y" ] || { echo "Aborted."; exit 0; }

# ----- 部署 -----
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

deploy_one() {
  local NAME="$1"
  local SRC="src/L2/${NAME}.sol:${NAME}"
  local LOG="$TMPDIR/${NAME}.log"

  echo "==> Deploying $NAME ..."
  # 用数组拼参数，便于按需追加 --gas-limit；forge 1.5 的 forge create 没有 --gas-estimate-multiplier
  local -a CREATE_ARGS
  CREATE_ARGS=(
    --rpc-url "$L2_RPC_URL"
    --private-key "$L2_DEPLOY_PK"
    --broadcast
  )
  if [ -n "$GAS_LIMIT" ]; then
    CREATE_ARGS+=(--gas-limit "$GAS_LIMIT")
  fi
  # 注意：CONTRACT 必须放在 --constructor-args 之前，
  # 否则 forge 把 CONTRACT 当作另一个 constructor arg 吞掉，报 "<CONTRACT> not provided"
  CREATE_ARGS+=("$SRC")
  CREATE_ARGS+=(--constructor-args "$NEW_RECIPIENT" "$MIN_WITHDRAWAL_WEI" "$WITHDRAWAL_NETWORK")

  ( cd "$WT" && forge create "${CREATE_ARGS[@]}" ) 2>&1 | tee "$LOG"

  local ADDR
  ADDR=$(grep -E '^Deployed to:' "$LOG" | head -1 | awk '{print $3}')
  local TX
  TX=$(grep -E '^Transaction hash:' "$LOG" | head -1 | awk '{print $3}')

  if [ -z "$ADDR" ] || [ -z "$TX" ]; then
    echo "ERROR: 解析 $NAME 部署输出失败" >&2
    cat "$LOG" >&2
    exit 1
  fi

  echo "    ${NAME}: $ADDR (tx $TX)"
  echo ""

  # 暂存到 tmp，最后一次性 jq 合并
  printf '%s\n' "$NAME $ADDR $TX" >> "$TMPDIR/all.txt"
}

deploy_one BaseFeeVault
deploy_one L1FeeVault
deploy_one SequencerFeeVault

# ----- 写 deployed.json -----
mkdir -p "$(dirname "$OUT_FILE")"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo "{"
  echo "  \"timestamp\": \"$TS\","
  echo "  \"chainId\": $(cast chain-id --rpc-url "$L2_RPC_URL"),"
  echo "  \"rpcUrl\": \"$L2_RPC_URL\","
  echo "  \"deployer\": \"$DEPLOYER\","
  echo "  \"constructor\": {"
  echo "    \"recipient\": \"$NEW_RECIPIENT\","
  echo "    \"minWithdrawalAmountWei\": \"$MIN_WITHDRAWAL_WEI\","
  echo "    \"withdrawalNetwork\": $WITHDRAWAL_NETWORK"
  echo "  },"
  echo "  \"impls\": {"
  first=1
  while read -r NAME ADDR TX; do
    [ $first -eq 0 ] && echo ","
    first=0
    printf '    "%s": { "address": "%s", "deployTx": "%s" }' "$NAME" "$ADDR" "$TX"
  done < "$TMPDIR/all.txt"
  echo ""
  echo "  }"
  echo "}"
} > "$OUT_FILE"

echo "================================================================"
echo " Deployment SUCCEEDED"
echo "================================================================"
cat "$OUT_FILE"
echo ""
echo "下一步：bash scripts/redeploy-fee-vaults/verify.sh"
