#!/bin/bash
#
# 在本地 anvil 上把 Multicall3 部署到 canonical 地址 0xcA11bde05977b3631167028862bE2a173976CA11。
#
# 为什么需要：op-challenger / op-service 的 batching 库通过 Multicall3 的 aggregate3 聚合读取
# DisputeGameFactory（gameCount、大 preimage claims 等）。本地 anvil 默认不预置 Multicall3，
# 缺失时 challenger 会持续报 "failed to fetch batch: Resource not found"。
#
# 部署方式：官方 keyless 预签名交易（Nick's method，见 mds1/multicall）。该交易不含 chainId
# （pre-EIP-155），由固定 deployer(0x05f32…)以 nonce 0 广播，因此在任何链都部署到同一 canonical
# 地址。gasLimit=1,000,000、gasPrice=100 gwei，故部署前需给 deployer 至少 0.1 ETH。
# 预签名交易内容存放在同目录 multicall3-presigned.tx（原始 3.9KB hex，避免内联）。
#
# 幂等：Multicall3 已存在则跳过。仅用于本地 anvil（真实链上 Multicall3 早已部署，无需运行）。
#
# 用法:
#   bash scripts/deploy-multicall3.sh
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

# 若由 chain-setup 调用且已设置，不要被 .envrc 覆盖（local 用 localhost L1）。
_CALLER_L1_RPC="${L1_RPC_URL:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"

MC3_ADDR=0xcA11bde05977b3631167028862bE2a173976CA11
MC3_DEPLOYER=0x05f32b3cc3888453ff71b01135b34ff8e41263f2
RAW_TX_FILE="$SCRIPT_DIR/multicall3-presigned.tx"

[ -f "$RAW_TX_FILE" ] || { echo "ERROR: 缺少预签名交易文件 $RAW_TX_FILE" >&2; exit 1; }
MC3_RAW_TX=$(tr -d ' \n\r\t' < "$RAW_TX_FILE")

# 幂等：已部署则跳过
CODE=$(cast code "$MC3_ADDR" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo 0x)
if [ "${#CODE}" -gt 3 ]; then
  echo "Multicall3 已存在于 ${MC3_ADDR}（code len ${#CODE}），跳过部署。"
  exit 0
fi

echo "Deploying Multicall3 to $MC3_ADDR (keyless presigned tx)..."

# 给 keyless deployer 打足 gas（本地 anvil 直接改余额，不受 block-time 影响）。1 ETH 足够。
cast rpc anvil_setBalance "$MC3_DEPLOYER" 0xde0b6b3a7640000 --rpc-url "$L1_RPC_URL" >/dev/null

# 广播预签名交易并等待打包。
cast publish "$MC3_RAW_TX" --rpc-url "$L1_RPC_URL" >/dev/null

# 验证
CODE=$(cast code "$MC3_ADDR" --rpc-url "$L1_RPC_URL" 2>/dev/null || echo 0x)
if [ "${#CODE}" -gt 3 ]; then
  echo "Multicall3 部署成功（code len ${#CODE}）。"
else
  echo "ERROR: Multicall3 部署失败，$MC3_ADDR 仍无代码。" >&2
  echo "       检查 anvil base fee 是否 > 100 gwei，或 deployer 余额是否充足。" >&2
  exit 1
fi
