#!/usr/bin/env bash
#
# 升级前 / 升级后状态检查
#
# 用法（任意阶段都可跑）：
#   bash scripts/upgrade-guardian/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE。请先运行 deploy-impl.sh" >&2
  exit 1
fi

L1_RPC_URL=$(jq -r '.rpcUrl' "$OUT_FILE")
NEW_IMPL=$(jq -r '.addresses.newImpl' "$OUT_FILE")
ORIGINAL_IMPL=$(jq -r '.addresses.originalImpl' "$OUT_FILE")
SC_PROXY=$(jq -r '.addresses.superchainConfigProxy' "$OUT_FILE")
SC_PROXY_ADMIN=$(jq -r '.addresses.superchainConfigProxyAdmin' "$OUT_FILE")
PAO_SAFE=$(jq -r '.addresses.paoSafe' "$OUT_FILE")

SLOT_IMPL=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
SLOT_ADMIN=0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103

echo "================================================================"
echo " SuperchainConfig state ($SC_PROXY)"
echo "================================================================"

CUR_IMPL_RAW=$(cast storage --rpc-url "$L1_RPC_URL" "$SC_PROXY" "$SLOT_IMPL")
CUR_IMPL="0x${CUR_IMPL_RAW: -40}"
CUR_ADMIN_RAW=$(cast storage --rpc-url "$L1_RPC_URL" "$SC_PROXY" "$SLOT_ADMIN")
CUR_ADMIN="0x${CUR_ADMIN_RAW: -40}"
CUR_GUARDIAN=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY" 'guardian()(address)')
CUR_PAUSED=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY" 'paused()(bool)')
CUR_VERSION=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY" 'version()(string)')
CUR_PA_OWNER=$(cast call --rpc-url "$L1_RPC_URL" "$SC_PROXY_ADMIN" 'owner()(address)')

printf "  %-26s %s\n" "implementation:"        "$CUR_IMPL"
printf "  %-26s %s\n" "ProxyAdmin (admin slot):" "$CUR_ADMIN"
printf "  %-26s %s\n" "ProxyAdmin.owner():"     "$CUR_PA_OWNER"
printf "  %-26s %s\n" "guardian():"             "$CUR_GUARDIAN"
printf "  %-26s %s\n" "paused():"               "$CUR_PAUSED"
printf "  %-26s %s\n" "version():"              "$CUR_VERSION"
echo ""

# 推断当前阶段
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ "$(lc "$CUR_IMPL")" = "$(lc "$ORIGINAL_IMPL")" ]; then
  STAGE="original (尚未升级 / 已回滚)"
elif [ "$(lc "$CUR_IMPL")" = "$(lc "$NEW_IMPL")" ]; then
  STAGE="transient (新 impl 已生效，⚠️ 别忘了 Tx 3 回滚)"
else
  STAGE="unknown impl: $CUR_IMPL"
fi

echo "================================================================"
echo " Current stage: $STAGE"
echo "================================================================"

# 检查 ProxyAdmin owner 是 PAO Safe
if [ "$(lc "$CUR_PA_OWNER")" != "$(lc "$PAO_SAFE")" ]; then
  echo "WARNING: ProxyAdmin owner 不是 deployed.json 里的 PAO Safe!"
  echo "         on-chain: $CUR_PA_OWNER"
  echo "         expected: $PAO_SAFE"
fi

if [ "$(lc "$CUR_ADMIN")" != "$(lc "$SC_PROXY_ADMIN")" ]; then
  echo "WARNING: SuperchainConfigProxy 的 admin slot 不是预期的 ProxyAdmin"
  echo "         on-chain: $CUR_ADMIN"
  echo "         expected: $SC_PROXY_ADMIN"
fi
