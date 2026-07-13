#!/usr/bin/env bash
#
# 部署后验证：3 个新 impl 的 immutable 都和构造参数对得上 + 字节码与 mainnet 现 impl 模板一致
#
# 用法：
#   bash scripts/redeploy-fee-vaults/verify.sh
# 或指定其他 deployed.json：
#   OUT_FILE=/path/to/deployed.json bash scripts/redeploy-fee-vaults/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
WT="${WT:-$REPO_ROOT/optimism-v2.0.0-beta.3/packages/contracts-bedrock}"

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE。请先运行 deploy.sh" >&2
  exit 1
fi

L2_RPC_URL=$(jq -r '.rpcUrl' "$OUT_FILE")
EXP_RECIPIENT=$(jq -r '.constructor.recipient' "$OUT_FILE")
EXP_MIN=$(jq -r '.constructor.minWithdrawalAmountWei' "$OUT_FILE")
EXP_NET=$(jq -r '.constructor.withdrawalNetwork' "$OUT_FILE")
EXP_VERSION='"1.5.0-beta.2"'

# mainnet 现 impl 地址（用于字节码模板比对）
MAINNET_IMPL_BASE=0x6d4bec23eeec8d5adefcc628533ce507391cd403
MAINNET_IMPL_L1F=0xf857010f8f434dd186be77e5d544bffa96615848
MAINNET_IMPL_SEQ=0xcc159473521dcc6e711f3002301f856b1f616290

echo "================================================================"
echo " Verification of newly-deployed FeeVault impls"
echo "================================================================"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

verify_one() {
  local NAME="$1"
  local NEW_IMPL="$2"
  local MAINNET_IMPL="$3"
  local CHECK_L1FEEWALLET="$4"

  echo ""
  echo "── $NAME @ $NEW_IMPL ──"

  local v r m n
  v=$(cast call --rpc-url "$L2_RPC_URL" "$NEW_IMPL" 'version()(string)')
  r=$(cast call --rpc-url "$L2_RPC_URL" "$NEW_IMPL" 'RECIPIENT()(address)')
  m=$(cast call --rpc-url "$L2_RPC_URL" "$NEW_IMPL" 'MIN_WITHDRAWAL_AMOUNT()(uint256)' | awk '{print $1}')
  n=$(cast call --rpc-url "$L2_RPC_URL" "$NEW_IMPL" 'WITHDRAWAL_NETWORK()(uint8)')

  printf "  %-26s expect=%s  got=%s  %s\n" "version"          "$EXP_VERSION"  "$v" "$([ "$v" = "$EXP_VERSION" ] && echo OK || echo FAIL)"
  printf "  %-26s expect=%s  got=%s  %s\n" "RECIPIENT()"      "$EXP_RECIPIENT" "$r" "$([ "$(lc "$r")" = "$(lc "$EXP_RECIPIENT")" ] && echo OK || echo FAIL)"
  printf "  %-26s expect=%s  got=%s  %s\n" "MIN_WITHDRAWAL_AMOUNT()" "$EXP_MIN" "$m" "$([ "$m" = "$EXP_MIN" ] && echo OK || echo FAIL)"
  printf "  %-26s expect=%s  got=%s  %s\n" "WITHDRAWAL_NETWORK()"   "$EXP_NET" "$n" "$([ "$n" = "$EXP_NET" ] && echo OK || echo FAIL)"

  if [ "$CHECK_L1FEEWALLET" = "1" ]; then
    local lw
    lw=$(cast call --rpc-url "$L2_RPC_URL" "$NEW_IMPL" 'l1FeeWallet()(address)')
    printf "  %-26s expect=%s  got=%s  %s\n" "l1FeeWallet()"  "$EXP_RECIPIENT" "$lw" "$([ "$(lc "$lw")" = "$(lc "$EXP_RECIPIENT")" ] && echo OK || echo FAIL)"
  fi

  # 字节码模板对比（immutable 涂 0 后 hash 必须等于 mainnet 现 impl）
  echo "  bytecode template diff vs mainnet $MAINNET_IMPL:"
  local NEW_CODE MAINNET_CODE
  NEW_CODE=$(cast code --rpc-url "$L2_RPC_URL" "$NEW_IMPL")
  MAINNET_CODE=$(cast code --rpc-url "$L2_RPC_URL" "$MAINNET_IMPL")

  WT="$WT" NAME="$NAME" NEW_CODE="$NEW_CODE" MAINNET_CODE="$MAINNET_CODE" python3 << 'PY'
import json, os, hashlib, sys
WT = os.environ['WT']
NAME = os.environ['NAME']
NEW = os.environ['NEW_CODE']
MAINNET = os.environ['MAINNET_CODE']

with open(f'{WT}/forge-artifacts/{NAME}.sol/{NAME}.json') as f:
    art = json.load(f)
imm = art['deployedBytecode'].get('immutableReferences', {}) or {}

def normalize(hex_code: str) -> bytes:
    body = hex_code[2:] if hex_code.startswith('0x') else hex_code
    arr = bytearray.fromhex(body)
    for refs in imm.values():
        for r in refs:
            for i in range(r['start'], r['start'] + r['length']):
                arr[i] = 0
    return bytes(arr)

new_norm = normalize(NEW)
main_norm = normalize(MAINNET)
new_h = hashlib.sha256(new_norm).hexdigest()[:16]
main_h = hashlib.sha256(main_norm).hexdigest()[:16]
match = (new_norm == main_norm)
print(f'    new hash:     {new_h}')
print(f'    mainnet hash: {main_h}')
print(f'    result:       {"OK (templates match)" if match else "FAIL (templates differ)"}')
sys.exit(0 if match else 1)
PY
}

verify_one BaseFeeVault       "$(jq -r '.impls.BaseFeeVault.address'      "$OUT_FILE")" "$MAINNET_IMPL_BASE" 0
verify_one L1FeeVault         "$(jq -r '.impls.L1FeeVault.address'        "$OUT_FILE")" "$MAINNET_IMPL_L1F"  0
verify_one SequencerFeeVault  "$(jq -r '.impls.SequencerFeeVault.address' "$OUT_FILE")" "$MAINNET_IMPL_SEQ"  1

echo ""
echo "================================================================"
echo " Verification done"
echo "================================================================"
echo ""
echo "下一步：基于 deployed.json 生成 Safe batch upgrade JSON"
echo "        bash scripts/redeploy-fee-vaults/safe-batch.sh"
