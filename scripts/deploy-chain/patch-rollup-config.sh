#!/bin/bash
#
# 把部署生成的 rollup.json 修正为“运行时 op-node(cgt-jovian/v1.16.5)”可用的形态。
# 由 chain-setup.sh 在部署完成后自动调用，也可单独执行。全部操作幂等，可重复运行。
#
# 背景：deploy-contracts.sh 用 op-contracts/v2.0.0-beta.3 的 op-node 生成 rollup.json
# （因为它认识 deploy-config 里的 CGT 字段），但实际启动用的是 cgt-jovian/v1.16.5 op-node，
# 两者对 rollup.json 的字段要求不一致，需要下面的兼容性修正。
#
# 用法:
#   bash scripts/deploy-chain/patch-rollup-config.sh [local|remote]
#
# 参数:
#   local  - 额外用当前 anvil 刷新 genesis.l1.hash（anvil 每次重建 hash 都变）
#   remote - 跳过 genesis.l1.hash 刷新（真实 L1 部署时已写入正确 hash，不应改动）
#
# 若不传参，则按 L1_RPC_URL 自动判断（含 localhost/127.0.0.1 视为 local）。
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

# 若由 chain-setup 调用且已设置，不要被 .envrc 覆盖
# （local 用 localhost L1、config/<context>）。standalone 执行时回退到 .envrc。
_CALLER_L1_RPC="${L1_RPC_URL:-}"
_CALLER_DEPLOYMENT_CONFIG_PATH="${DEPLOYMENT_CONFIG_PATH:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"
[ -n "$_CALLER_DEPLOYMENT_CONFIG_PATH" ] && export DEPLOYMENT_CONFIG_PATH="$_CALLER_DEPLOYMENT_CONFIG_PATH"

# 解析运行环境：local | remote
CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  echo "Usage: bash scripts/deploy-chain/patch-rollup-config.sh [local|remote]"
  exit 1
fi

ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
if [ ! -f "$ROLLUP_FILE" ]; then
  echo "Error: rollup.json not found at $ROLLUP_FILE" >&2
  echo "       先运行 bash scripts/deploy-chain/chain-setup.sh $CHAIN_ENV 生成配置。" >&2
  exit 1
fi

echo "=== Patch rollup.json compatibility ($CHAIN_ENV) ==="
echo "  file: $ROLLUP_FILE"

# 同目录临时文件，避免跨文件系统 mv 以及多 context 并发写 /tmp 互相覆盖。
TMP_FILE="$ROLLUP_FILE.tmp"

# ---------- [1/3] genesis.l1.hash：仅 local ----------
# anvil 每次重建，同一 block number 的 hash 都会变；用当前 anvil 按 rollup.json 里
# 已记录的 genesis.l1.number 重新取 hash 写回。remote 是真实 L1，部署时已写入正确
# hash，不应改动。
if [ "$CHAIN_ENV" = "local" ]; then
  L1_GENESIS_NUMBER=$(jq -r '.genesis.l1.number' "$ROLLUP_FILE")
  L1_GENESIS_HASH=$(cast block "$L1_GENESIS_NUMBER" --rpc-url "$L1_RPC_URL" --json | jq -r '.hash')
  if [ -z "$L1_GENESIS_HASH" ] || [ "$L1_GENESIS_HASH" = "null" ]; then
    echo "Error: 无法从 $L1_RPC_URL 取到 L1 block $L1_GENESIS_NUMBER 的 hash" >&2
    exit 1
  fi
  jq --arg hash "$L1_GENESIS_HASH" '.genesis.l1.hash = $hash' \
    "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  echo "  [1/3] genesis.l1.hash -> $L1_GENESIS_HASH (block $L1_GENESIS_NUMBER)"
else
  echo "  [1/3] genesis.l1.hash 刷新跳过 (remote 使用真实 L1 hash)"
fi

# ---------- [2/3] 删除 da_challenge_contract_address ----------
# beta.3 op-node 会写入该字段，但运行时 cgt-jovian/v1.16.5 op-node 不认识，需删除。
jq 'del(.da_challenge_contract_address)' \
  "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
echo "  [2/3] da_challenge_contract_address 已移除"

# ---------- [3/4] 确保 chain_op_config 存在 ----------
# 运行时 op-node 需要 EIP-1559 参数；缺失会导致启动异常。值与本链一致。
jq '.chain_op_config = {
  "eip1559Elasticity": 6,
  "eip1559Denominator": 50,
  "eip1559DenominatorCanyon": 250
}' "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
echo "  [3/4] chain_op_config 已确保"

# ---------- [4/4] fork 激活时间：从 .envrc 单一真源同步到 rollup.json ----------
# op-geth 的 --override.* 与 rollup.json 的 *_time 必须一致，两者都从 .envrc 的
# FORK_*_TIME 派生（geth 侧见 OP_GETH_OVERRIDE_FLAGS）。此处把同一批值写进 rollup.json：
# 变量非空 → 写入该时间戳；变量为空 → 置 null（表示该 fork 未调度）。
sync_fork() {  # $1=rollup.json 里的 fork 名  $2=对应 FORK_*_TIME 值
  local key="$1" val="$2"
  if [ -n "$val" ]; then
    jq --argjson t "$val" ".${key}_time = \$t" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  else
    jq ".${key}_time = null" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  fi
  echo "      ${key}_time = ${val:-null}"
}
echo "  [4/4] 同步 fork 激活时间（来源：.envrc FORK_*_TIME）"
sync_fork fjord    "${FORK_FJORD_TIME:-}"
sync_fork granite  "${FORK_GRANITE_TIME:-}"
sync_fork holocene "${FORK_HOLOCENE_TIME:-}"
sync_fork isthmus  "${FORK_ISTHMUS_TIME:-}"
sync_fork jovian   "${FORK_JOVIAN_TIME:-}"

echo "=== Patch complete ==="
