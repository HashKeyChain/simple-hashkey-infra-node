#!/usr/bin/env bash
#
# 把 deploy.sh 部署出来的 3 个 FeeVault impl 在 HSK mainnet Blockscout 上 verify。
# 这一步会让浏览器上的合约名分别显示为 BaseFeeVault / L1FeeVault / SequencerFeeVault
# （即使 BaseFeeVault 和 L1FeeVault 的 deployedBytecode 完全相同，因为 verify 是按
#  fully-qualified contract name 走的）。
#
# 前置：
#   - deploy.sh 已成功，produced scripts/redeploy-fee-vaults/deployed.json
#   - worktree 里已经 forge build 过同样的合约（deploy.sh 已经强制这点）
#   - 当前 foundry profile 跟 deploy 时一致（v2 contracts-bedrock 默认 profile 即可）
#
# 可选环境变量：
#   BLOCKSCOUT_URL       默认 https://hashkey.blockscout.com
#   OUT_FILE             默认 同目录下 deployed.json
#   WT                   默认 项目内 worktree 路径
#   ONLY                 默认 空 (3 个都 verify)；可设为 BaseFeeVault / L1FeeVault / SequencerFeeVault 单独 verify
#   FORCE_REVERIFY       默认 1 (=1 时附加 --skip-is-verified-check，强制重新提交 source，
#                              用于 Blockscout 已按 bytecode-match 自动 verify 但显示成另一个合约名的场景)
#
# 用法：
#   bash scripts/redeploy-fee-vaults/verify-on-blockscout.sh
#   ONLY=BaseFeeVault bash scripts/redeploy-fee-vaults/verify-on-blockscout.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
WT="${WT:-$REPO_ROOT/optimism-v2.0.0-beta.3/packages/contracts-bedrock}"
BLOCKSCOUT_URL="${BLOCKSCOUT_URL:-https://hashkey.blockscout.com}"
ONLY="${ONLY:-}"
FORCE_REVERIFY="${FORCE_REVERIFY:-1}"

# 默认强制重 verify。Blockscout 的 bytecode-match 自动 verify 会把
# BaseFeeVault 和 L1FeeVault（deployedBytecode 完全相同）都贴成同一个合约名，
# 不强制重新提交 source 就改不过来。FORCE_REVERIFY=0 可恢复 forge 默认行为。
SKIP_CHECK_FLAG=()
if [ "$FORCE_REVERIFY" = "1" ]; then
  SKIP_CHECK_FLAG=(--skip-is-verified-check)
fi

# Blockscout 的 verify API endpoint
VERIFIER_URL="${BLOCKSCOUT_URL%/}/api/"

for c in cast jq forge; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: 需要 $c 在 PATH 上" >&2; exit 1; }
done

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE。请先运行 deploy.sh" >&2
  exit 1
fi

# 从 deployed.json 读所有参数
L2_RPC_URL=$(jq -r '.rpcUrl' "$OUT_FILE")
CHAIN_ID=$(jq -r '.chainId' "$OUT_FILE")
NEW_RECIPIENT=$(jq -r '.constructor.recipient' "$OUT_FILE")
MIN_WITHDRAWAL=$(jq -r '.constructor.minWithdrawalAmountWei' "$OUT_FILE")
WITHDRAWAL_NETWORK=$(jq -r '.constructor.withdrawalNetwork' "$OUT_FILE")
ADDR_BASE=$(jq -r '.impls.BaseFeeVault.address // empty' "$OUT_FILE")
ADDR_L1F=$(jq -r '.impls.L1FeeVault.address // empty' "$OUT_FILE")
ADDR_SEQ=$(jq -r '.impls.SequencerFeeVault.address // empty' "$OUT_FILE")

for v in "$ADDR_BASE" "$ADDR_L1F" "$ADDR_SEQ"; do
  [ -z "$v" ] || [ "$v" = "null" ] && { echo "ERROR: deployed.json 缺少 vault 地址" >&2; exit 1; }
done

# constructor args abi-encode（3 个 vault 用同一组 constructor）
# FeeVault.constructor(address _recipient, uint256 _minWithdrawalAmount, WithdrawalNetwork _withdrawalNetwork)
# WithdrawalNetwork 是 enum {L1, L2}, 在 ABI 里是 uint8
CTOR_ARGS_HEX=$(cast abi-encode \
  'constructor(address,uint256,uint8)' \
  "$NEW_RECIPIENT" "$MIN_WITHDRAWAL" "$WITHDRAWAL_NETWORK")

# 去掉前导 0x，forge verify-contract 接受带或不带 0x 都行，但去掉更稳
CTOR_ARGS_HEX_NO0X="${CTOR_ARGS_HEX#0x}"

# 从 artifact 反查实际编译时的 compiler/evm 版本，避免 foundry.toml 漂移
# (e.g. foundry.toml 现在写 cancun，但 solc 0.8.15 不支持 cancun，artifact 实际是 london)
read_compile_params() {
  local NAME="$1"
  local ART="$WT/forge-artifacts/${NAME}.sol/${NAME}.json"
  if [ ! -f "$ART" ]; then
    echo "ERROR: artifact 不存在: $ART (需要先在 worktree 跑 forge build)" >&2
    exit 1
  fi
  local cv ev
  cv=$(jq -r '.metadata.compiler.version' "$ART")
  ev=$(jq -r '.metadata.settings.evmVersion' "$ART")
  printf '%s|%s' "v$cv" "$ev"
}

# 用 BaseFeeVault 的参数做整体显示（3 个 vault 是同一组 profile 编出来的）
PARAMS=$(read_compile_params BaseFeeVault)
COMPILER_VERSION="${PARAMS%%|*}"
EVM_VERSION="${PARAMS##*|}"

echo "================================================================"
echo " Verify FeeVault impls on Blockscout"
echo "================================================================"
echo "  Blockscout URL:   $BLOCKSCOUT_URL"
echo "  Verifier API:     $VERIFIER_URL"
echo "  L2 chainId:       $CHAIN_ID"
echo "  Worktree:         $WT"
echo ""
echo "  Constructor (3 个 vault 一致):"
echo "    _recipient            = $NEW_RECIPIENT"
echo "    _minWithdrawalAmount  = $MIN_WITHDRAWAL"
echo "    _withdrawalNetwork    = $WITHDRAWAL_NETWORK ($([ "$WITHDRAWAL_NETWORK" = "0" ] && echo L1 || echo L2))"
echo "  ABI-encoded ctor args: 0x$CTOR_ARGS_HEX_NO0X"
echo "  compiler (from artifact): $COMPILER_VERSION"
echo "  evm-version (from artifact): $EVM_VERSION"
echo "  FORCE_REVERIFY:        $FORCE_REVERIFY ($([ "$FORCE_REVERIFY" = "1" ] && echo "强制重 verify，跳过 already-verified 预检查" || echo "保留 forge 默认 already-verified 跳过行为"))"
echo "================================================================"
echo ""

verify_one() {
  local NAME="$1"
  local ADDR="$2"
  local SRC="src/L2/${NAME}.sol:${NAME}"

  if [ -n "$ONLY" ] && [ "$ONLY" != "$NAME" ]; then
    echo "── $NAME (skipped, ONLY=$ONLY) ──"
    return 0
  fi

  echo "── Verifying $NAME @ $ADDR ──"
  echo "  contract: $SRC"
  echo ""

  # 注意：
  #   --verifier blockscout            告诉 forge 用 Blockscout 协议
  #   --verifier-url ${BLOCKSCOUT}/api 走 Blockscout 的 Smart Contract Verification endpoint
  #   --chain-id <id>                  HSK mainnet 不在 forge 内置 alias 里，所以传数字 id
  #   --constructor-args <hex>         abi-encoded，不需要重新展开 args
  #   --watch                          forge 会轮询 verify 状态直到结束
  #   --skip-is-verified-check         (默认开) 跳过 forge "已 verified 就直接 return" 的预检查，
  #                                    强制把 source 重新提交给 Blockscout，
  #                                    用于纠正 bytecode-match 自动 verify 出错的合约名
  # 每个 vault 单独从自己的 artifact 读 compiler/evm，3 个理论上一致
  local pair cv ev
  pair=$(read_compile_params "$NAME")
  cv="${pair%%|*}"
  ev="${pair##*|}"

  set +e
  ( cd "$WT" && forge verify-contract \
      --verifier blockscout \
      --verifier-url "$VERIFIER_URL" \
      --chain-id "$CHAIN_ID" \
      --compiler-version "$cv" \
      --evm-version "$ev" \
      --constructor-args "0x$CTOR_ARGS_HEX_NO0X" \
      --watch \
      "${SKIP_CHECK_FLAG[@]}" \
      "$ADDR" \
      "$SRC" \
  )
  local rc=$?
  set -e

  echo ""
  if [ $rc -eq 0 ]; then
    echo "  $NAME: VERIFIED -> $BLOCKSCOUT_URL/address/$ADDR?tab=contract"
  else
    echo "  $NAME: verify exit=$rc，请检查上方输出。可单独重试："
    echo "         ONLY=$NAME bash scripts/redeploy-fee-vaults/verify-on-blockscout.sh"
  fi
  echo ""
}

verify_one BaseFeeVault      "$ADDR_BASE"
verify_one L1FeeVault        "$ADDR_L1F"
verify_one SequencerFeeVault "$ADDR_SEQ"

echo "================================================================"
echo " Done. 浏览器链接："
echo "   BaseFeeVault:      $BLOCKSCOUT_URL/address/$ADDR_BASE?tab=contract"
echo "   L1FeeVault:        $BLOCKSCOUT_URL/address/$ADDR_L1F?tab=contract"
echo "   SequencerFeeVault: $BLOCKSCOUT_URL/address/$ADDR_SEQ?tab=contract"
echo "================================================================"
