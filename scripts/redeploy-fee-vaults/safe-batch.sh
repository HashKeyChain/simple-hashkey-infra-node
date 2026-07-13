#!/usr/bin/env bash
#
# 读取 deployed.json，生成 L1 Safe Tx Builder 可直接 "Load file" 导入的 batch JSON。
# 该 batch 包含 3 笔 L1 交易，每笔调用 OptimismPortal.depositTransaction 触发 L2 上
# ProxyAdmin.upgrade(vault, newImpl)，把 3 个 FeeVault proxy 切到新部署的 implementation。
#
# 调用栈：
#   L1 Safe (PAO)
#     └─ OptimismPortal.depositTransaction(_to=L2_ProxyAdmin, _value=0, _gasLimit, false, _data)
#                └─ (deposit derived on L2, sender = aliased Safe address)
#                       └─ L2 ProxyAdmin.upgrade(vaultProxy, newImpl)
#                              └─ Proxy.upgradeTo(newImpl)
#
# 必需前置：
#   - deploy.sh 已成功，produced scripts/redeploy-fee-vaults/deployed.json
#   - cast + jq 在 PATH 上
#
# 可选环境变量：
#   L1_RPC_URL        默认 https://ethereum-rpc.publicnode.com   (用于 L1 sanity)
#   L1_CHAIN_ID       默认 1                                     (写进 Safe Tx Builder JSON)
#   OPTIMISM_PORTAL   默认 0xe7Aa79B59CAc06F9706D896a047fEb9d3BDA8bD3 (HSK mainnet 的 OptimismPortalProxy)
#   L1_SAFE_OWNER     默认 0x441F31C4cdf772558D4EA31f3114de59aE145E7c (L1 PAO Safe, 即 L2 ProxyAdmin owner 在 L1 的真身)
#   L2_GAS_LIMIT      默认 300000                                (深 deposit 在 L2 执行 upgrade 的 gas 限额)
#   OUT_FILE          默认 同目录下 deployed.json                 (输入)
#   SAFE_BATCH_OUT    默认 同目录下 safe-batch.json               (输出)
#   STRICT            默认 1 (=1 时, 当 vault 当前 impl 已经等于目标 impl 会 abort; =0 时仅 warn)
#   SKIP_L1_CHECK     默认 0 (=1 时跳过 L1 chainId 防呆, 便于离线生成 calldata)
#
# 用法：
#   bash scripts/redeploy-fee-vaults/safe-batch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- 默认参数 ----------
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
SAFE_BATCH_OUT="${SAFE_BATCH_OUT:-$SCRIPT_DIR/safe-batch.json}"

L1_RPC_URL="${L1_RPC_URL:-https://ethereum-rpc.publicnode.com}"
L1_CHAIN_ID="${L1_CHAIN_ID:-1}"
OPTIMISM_PORTAL="${OPTIMISM_PORTAL:-0xe7Aa79B59CAc06F9706D896a047fEb9d3BDA8bD3}"
L1_SAFE_OWNER="${L1_SAFE_OWNER:-0x441F31C4cdf772558D4EA31f3114de59aE145E7c}"
L2_GAS_LIMIT="${L2_GAS_LIMIT:-300000}"
STRICT="${STRICT:-1}"
SKIP_L1_CHECK="${SKIP_L1_CHECK:-0}"

# L2 predeploys（固定）
L2_PROXY_ADMIN=0x4200000000000000000000000000000000000018
BASE_FEE_VAULT=0x4200000000000000000000000000000000000019
L1_FEE_VAULT=0x420000000000000000000000000000000000001A
SEQUENCER_FEE_VAULT=0x4200000000000000000000000000000000000011

# EIP-1967 implementation slot
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

# ---------- 工具检查 ----------
for c in cast jq; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: 需要 $c 在 PATH 上" >&2; exit 1; }
done

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE，请先运行 deploy.sh" >&2
  exit 1
fi

# ---------- 读取 deployed.json ----------
L2_RPC_URL=$(jq -r '.rpcUrl' "$OUT_FILE")
NEW_RECIPIENT=$(jq -r '.constructor.recipient' "$OUT_FILE")
MIN_WITHDRAWAL=$(jq -r '.constructor.minWithdrawalAmountWei' "$OUT_FILE")
WITHDRAWAL_NETWORK=$(jq -r '.constructor.withdrawalNetwork' "$OUT_FILE")
NEW_BASE=$(jq -r '.impls.BaseFeeVault.address // empty' "$OUT_FILE")
NEW_L1F=$(jq -r '.impls.L1FeeVault.address // empty' "$OUT_FILE")
NEW_SEQ=$(jq -r '.impls.SequencerFeeVault.address // empty' "$OUT_FILE")

for v in "$NEW_BASE" "$NEW_L1F" "$NEW_SEQ"; do
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    echo "ERROR: deployed.json 缺少某个 vault 的 impl 地址" >&2
    cat "$OUT_FILE" >&2
    exit 1
  fi
done

# ---------- L1 chainId 防呆 ----------
if [ "$SKIP_L1_CHECK" = "1" ]; then
  echo "NOTE: SKIP_L1_CHECK=1，跳过 L1 chainId 校验（仅离线生成 calldata 时使用）"
else
  ACTUAL_L1_CHAIN_ID=$(cast chain-id --rpc-url "$L1_RPC_URL" 2>&1 || true)
  if [ "$ACTUAL_L1_CHAIN_ID" != "$L1_CHAIN_ID" ]; then
    echo "ERROR: L1_RPC_URL 实际 chainId=$ACTUAL_L1_CHAIN_ID, 期望 $L1_CHAIN_ID" >&2
    echo "       请检查 L1_RPC_URL='$L1_RPC_URL' 是否指向正确网络" >&2
    echo "       离线生成时可用 SKIP_L1_CHECK=1 跳过" >&2
    exit 1
  fi
fi

# ---------- helpers ----------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

read_current_impl() {
  # EIP-1967 slot 读取当前 implementation；失败返回空串以便上层判断
  local vault="$1" raw
  if raw=$(cast storage --rpc-url "$L2_RPC_URL" "$vault" "$IMPL_SLOT" 2>/dev/null); then
    printf '0x%s' "${raw: -40}"
  else
    printf ''
  fi
}

# 计算两层 calldata：
#   inner  = ProxyAdmin.upgrade(vault, newImpl)
#   outer  = OptimismPortal.depositTransaction(L2_ProxyAdmin, 0, L2_GAS_LIMIT, false, inner)
build_calldata() {
  local vault="$1" new_impl="$2"
  local inner outer
  inner=$(cast calldata 'upgrade(address,address)' "$vault" "$new_impl")
  outer=$(cast calldata 'depositTransaction(address,uint256,uint64,bool,bytes)' \
    "$L2_PROXY_ADMIN" 0 "$L2_GAS_LIMIT" false "$inner")
  printf '%s|%s' "$inner" "$outer"
}

# ---------- 输出 header ----------
echo "================================================================"
echo " Generate Safe Tx Builder batch JSON for FeeVault upgrade"
echo "================================================================"
echo "  L1 Safe (PAO):           $L1_SAFE_OWNER"
echo "  L1 RPC:                  $L1_RPC_URL  (chain $L1_CHAIN_ID)"
echo "  OptimismPortal (L1):     $OPTIMISM_PORTAL"
echo "  L2 ProxyAdmin (L2):      $L2_PROXY_ADMIN"
echo "  L2 RPC (sanity only):    $L2_RPC_URL"
echo "  L2 gas limit per upgrade:$L2_GAS_LIMIT"
echo ""
echo "  Constructor used at deploy time:"
echo "    recipient            = $NEW_RECIPIENT"
echo "    minWithdrawalWei     = $MIN_WITHDRAWAL"
echo "    withdrawalNetwork    = $WITHDRAWAL_NETWORK ($([ "$WITHDRAWAL_NETWORK" = "0" ] && echo L1 || echo L2))"
echo "================================================================"

# ---------- 收集每个 vault 的 sanity + calldata ----------
ARR_FILE=$(mktemp)
TXT_TMP=$(mktemp)
trap 'rm -f "$ARR_FILE" "$TXT_TMP"' EXIT

echo '[]' > "$ARR_FILE"

process_vault() {
  local name="$1" vault="$2" new_impl="$3"

  local cur_impl pair inner outer
  cur_impl=$(read_current_impl "$vault")
  pair=$(build_calldata "$vault" "$new_impl")
  inner="${pair%%|*}"
  outer="${pair##*|}"

  echo ""
  echo "── $name ──"
  echo "  L2 proxy:        $vault"
  if [ -n "$cur_impl" ]; then
    echo "  current impl:    $cur_impl"
  else
    echo "  current impl:    (read failed, skipped)"
  fi
  echo "  target impl:     $new_impl"
  echo "  inner upgrade()  calldata: $inner"
  echo "  outer depositTx  calldata: $outer"

  if [ -n "$cur_impl" ] && [ "$(lc "$cur_impl")" = "$(lc "$new_impl")" ]; then
    if [ "$STRICT" = "1" ]; then
      echo "ERROR: $name 当前 impl 已经等于目标 impl，无需升级。" >&2
      echo "       如果你确认要重新发起 upgrade（例如想测试 Safe 流程），用 STRICT=0 跳过此检查。" >&2
      exit 1
    else
      echo "  WARN: current impl 已经 = target impl，仍纳入 batch（STRICT=0）"
    fi
  fi

  jq --arg to "$OPTIMISM_PORTAL" --arg data "$outer" \
    '. + [{
       to: $to,
       value: "0",
       data: $data,
       contractMethod: null,
       contractInputsValues: null
     }]' "$ARR_FILE" > "$ARR_FILE.tmp"
  mv "$ARR_FILE.tmp" "$ARR_FILE"
}

process_vault BaseFeeVault      "$BASE_FEE_VAULT"      "$NEW_BASE"
process_vault L1FeeVault        "$L1_FEE_VAULT"        "$NEW_L1F"
process_vault SequencerFeeVault "$SEQUENCER_FEE_VAULT" "$NEW_SEQ"

# ---------- 拼最终 Safe Tx Builder JSON ----------
CREATED_AT_MS="$(date +%s)000"
DESCRIPTION="Upgrade 3 L2 FeeVault proxies (BaseFeeVault, L1FeeVault, SequencerFeeVault) to new implementations via L1 Safe -> OptimismPortal.depositTransaction -> L2 ProxyAdmin.upgrade. recipient=$NEW_RECIPIENT withdrawalNetwork=$WITHDRAWAL_NETWORK minWithdrawalWei=$MIN_WITHDRAWAL."

jq -n \
  --arg chainId "$L1_CHAIN_ID" \
  --argjson createdAt "$CREATED_AT_MS" \
  --arg safe "$L1_SAFE_OWNER" \
  --arg description "$DESCRIPTION" \
  --slurpfile txs "$ARR_FILE" \
  '{
    version: "1.0",
    chainId: $chainId,
    createdAt: $createdAt,
    meta: {
      name: "Redeploy FeeVaults - Upgrade",
      description: $description,
      txBuilderVersion: "1.16.5",
      createdFromSafeAddress: $safe,
      createdFromOwnerAddress: "",
      checksum: ""
    },
    transactions: ($txs[0])
  }' > "$SAFE_BATCH_OUT"

echo ""
echo "================================================================"
echo " Safe batch JSON written to:"
echo "   $SAFE_BATCH_OUT"
echo "================================================================"
echo ""
echo " 下一步："
echo "   1) 打开 https://app.safe.global, 切到 L1 mainnet (chain $L1_CHAIN_ID)"
echo "   2) 进入 Safe $L1_SAFE_OWNER"
echo "   3) Apps -> Tx Builder -> 右上角 'Load file' -> 选 $SAFE_BATCH_OUT"
echo "   4) 校对 3 笔 tx：To 全部 = $OPTIMISM_PORTAL，Value = 0"
echo "      Data 应分别 == 上面打印的 3 个 outer calldata"
echo "   5) Simulate -> 提交 batch -> 收够 owner 签名后 Execute"
echo ""
echo " L1 上 batch 执行成功后，需要等 op-node 派生 3 笔 deposit 到 L2 (一般 5~15 分钟)"
echo " 然后在 L2 上验证 (按 README.md 'Safe 多签升级' 末尾那段)"
