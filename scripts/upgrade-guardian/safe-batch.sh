#!/usr/bin/env bash
#
# 生成 PAO Safe 的 3 笔 batch（用来 transient upgrade SuperchainConfig 改 guardian）
# 输出 2 种格式：
#   1. raw calldata 列表（可手贴 Safe Tx Builder）
#   2. Safe Tx Builder JSON（可在 Safe Web UI 直接 import）
#
# 用法：
#   bash scripts/upgrade-guardian/safe-batch.sh <NEW_GUARDIAN>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${OUT_FILE:-$SCRIPT_DIR/deployed.json}"
BATCH_OUT="${BATCH_OUT:-$SCRIPT_DIR/safe-batch.json}"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <NEW_GUARDIAN>" >&2
  exit 1
fi
NEW_GUARDIAN="$1"

if [ ! -f "$OUT_FILE" ]; then
  echo "ERROR: 找不到 $OUT_FILE。请先运行 deploy-impl.sh" >&2
  exit 1
fi

NEW_IMPL=$(jq -r '.addresses.newImpl' "$OUT_FILE")
ORIGINAL_IMPL=$(jq -r '.addresses.originalImpl' "$OUT_FILE")
SC_PROXY=$(jq -r '.addresses.superchainConfigProxy' "$OUT_FILE")
SC_PROXY_ADMIN=$(jq -r '.addresses.superchainConfigProxyAdmin' "$OUT_FILE")
PAO_SAFE=$(jq -r '.addresses.paoSafe' "$OUT_FILE")
CHAIN_ID=$(jq -r '.chainId' "$OUT_FILE")

# Validate NEW_GUARDIAN format
if ! echo "$NEW_GUARDIAN" | grep -Ei '^0x[0-9a-f]{40}$' >/dev/null; then
  echo "ERROR: NEW_GUARDIAN 不是合法的 0x-prefixed 地址: $NEW_GUARDIAN" >&2
  exit 1
fi

echo "================================================================"
echo " Generating Safe batch for transient upgrade"
echo "================================================================"
echo "  PAO Safe (signer):     $PAO_SAFE"
echo "  ProxyAdmin:            $SC_PROXY_ADMIN"
echo "  SuperchainConfigProxy: $SC_PROXY"
echo "  New impl (with setter):$NEW_IMPL"
echo "  Original impl (revert):$ORIGINAL_IMPL"
echo "  NEW_GUARDIAN:          $NEW_GUARDIAN"
echo "================================================================"

# 3 笔的 calldata
TX1_DATA=$(cast calldata "upgrade(address,address)" "$SC_PROXY" "$NEW_IMPL")
TX2_DATA=$(cast calldata "setGuardian(address)" "$NEW_GUARDIAN")
TX3_DATA=$(cast calldata "upgrade(address,address)" "$SC_PROXY" "$ORIGINAL_IMPL")

cat <<EOF

== Tx 1: upgrade SuperchainConfig 到带 setter 的 impl ==
  to:    $SC_PROXY_ADMIN
  value: 0
  data:  $TX1_DATA

== Tx 2: 直接调 SuperchainConfigProxy.setGuardian (transparent fallback 到 impl) ==
  to:    $SC_PROXY
  value: 0
  data:  $TX2_DATA

== Tx 3: 把 SuperchainConfig impl 升回原版 ==
  to:    $SC_PROXY_ADMIN
  value: 0
  data:  $TX3_DATA

EOF

# Safe Tx Builder JSON（可在 https://app.safe.global Tx Builder 直接 import）
TS_SEC=$(date +%s)
TS_MS=$((TS_SEC * 1000))
cat > "$BATCH_OUT" <<EOF
{
  "version": "1.0",
  "chainId": "$CHAIN_ID",
  "createdAt": $TS_MS,
  "meta": {
    "name": "Transient upgrade SuperchainConfig.guardian",
    "description": "Upgrade SC impl -> setGuardian($NEW_GUARDIAN) -> rollback to original impl",
    "txBuilderVersion": "1.16.5",
    "createdFromSafeAddress": "$PAO_SAFE",
    "createdFromOwnerAddress": "",
    "checksum": ""
  },
  "transactions": [
    {
      "to": "$SC_PROXY_ADMIN",
      "value": "0",
      "data": "$TX1_DATA",
      "contractMethod": null,
      "contractInputsValues": null
    },
    {
      "to": "$SC_PROXY",
      "value": "0",
      "data": "$TX2_DATA",
      "contractMethod": null,
      "contractInputsValues": null
    },
    {
      "to": "$SC_PROXY_ADMIN",
      "value": "0",
      "data": "$TX3_DATA",
      "contractMethod": null,
      "contractInputsValues": null
    }
  ]
}
EOF

echo "================================================================"
echo " Safe Tx Builder JSON written: $BATCH_OUT"
echo "================================================================"
echo ""
echo "在 https://app.safe.global → 你的 Safe ($PAO_SAFE) → Apps → Tx Builder → 右上角"
echo "Drag & drop $BATCH_OUT 即可加载这 3 笔；收 3-of-5 签名后执行。"
