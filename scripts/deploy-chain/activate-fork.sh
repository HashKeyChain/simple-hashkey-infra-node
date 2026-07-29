#!/bin/bash
#
# 启动新分叉（在已运行的链上推进硬分叉）。
#
# 背景：链初次 setup 只从 fjord 起步（部署工具产出纯 fjord 基线），其余分叉在 .envrc 的
# FORK_*_TIME 留空。要激活新分叉时，分叉时间是单一真源（.envrc 的 FORK_*_TIME），本脚本
# 是唯一把它写进配置的地方，然后重启链：
#   - rollup.json 的 *_time（op-node 读）        <- 本脚本 [2/4] sync_fork
#   - genesis.json 的 config.*Time（geth/reth 共用）<- 本脚本 [2/4] 调 bake-genesis-forks.sh
#   - 随后 [3/4] 重跑 geth init 只更新分叉表、保留链数据。
#
# 使用流程：
#   1. 编辑 .envrc，把要激活的分叉 FORK_*_TIME 填成目标 unix 时间戳；
#      建议取"当前之后"的时间（如 now+60），这样能观察到 pre->post 的过渡区块；
#      填 0 表示创世即激活（仅对全新链有意义）；留空表示不启动该分叉。
#   2. 运行本脚本：它自动 停 L2 -> 同步 rollup.json -> 重启 L2（chain-start 烘入 genesis 并重跑 geth init）。
#      注意：本脚本不重启 anvil、不铲 op-geth datadir；geth init 只更新分叉表，链从当前高度继续，
#      分叉在目标时间激活。
#
# 用法:
#   bash scripts/activate-fork.sh [local|remote]
#
# 若不传参，根据 L1_RPC_URL 自动判断（含 localhost/127.0.0.1 视为 local）。
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

# ---------- 解析运行环境：local | remote ----------
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
  echo "Usage: bash scripts/activate-fork.sh [local|remote]"
  exit 1
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

ROLLUP_FILE="$BASE_PATH/config/$DEPLOYMENT_CONTEXT/rollup.json"
if [ ! -f "$ROLLUP_FILE" ]; then
  echo "Error: rollup.json 不存在: $ROLLUP_FILE" >&2
  echo "       先运行 bash scripts/chain-setup.sh $CHAIN_ENV 生成配置。" >&2
  exit 1
fi

# ---------- 打印将要生效的分叉配置（来源：.envrc FORK_*_TIME）----------
echo "============================================"
echo "  Activate fork ($CHAIN_ENV)"
echo "============================================"
echo "分叉时间（来源 .envrc FORK_*_TIME，空=不启动）:"
printf '  %-9s %s\n' fjord    "${FORK_FJORD_TIME:-<未设置>}"
printf '  %-9s %s\n' granite  "${FORK_GRANITE_TIME:-<未设置>}"
printf '  %-9s %s\n' holocene "${FORK_HOLOCENE_TIME:-<未设置>}"
printf '  %-9s %s\n' isthmus  "${FORK_ISTHMUS_TIME:-<未设置>}"
printf '  %-9s %s\n' jovian   "${FORK_JOVIAN_TIME:-<未设置>}"
echo ""

# ---------- 软校验：单调递增 + 是否已是过去时间 ----------
# 只告警不拦截：分叉时间应按 fjord<=granite<=holocene<=isthmus<=jovian 递增；
# 若目标时间已早于当前 L1 时间，重启后该分叉会在下一个区块立即激活，看不到过渡区块。
NOW=$(cast block latest --rpc-url "$L1_RPC_URL" -j 2>/dev/null | jq -r '.timestamp' 2>/dev/null | xargs printf '%d\n' 2>/dev/null || echo "")
prev=""
for pair in "fjord:${FORK_FJORD_TIME:-}" "granite:${FORK_GRANITE_TIME:-}" \
            "holocene:${FORK_HOLOCENE_TIME:-}" "isthmus:${FORK_ISTHMUS_TIME:-}" \
            "jovian:${FORK_JOVIAN_TIME:-}"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [ -z "$val" ] && continue
  if [ -n "$prev" ] && [ "$val" -lt "$prev" ]; then
    echo "WARN: ${name}=${val} 小于前一个分叉时间 ${prev}，分叉时间应单调递增，请检查。"
  fi
  prev="$val"
  if [ -n "$NOW" ] && [ "$val" != "0" ] && [ "$val" -lt "$NOW" ]; then
    echo "WARN: ${name}=${val} 已早于当前 L1 时间 ${NOW}，重启后将立即激活（无过渡区块）。"
  fi
done
echo ""

# ---------- [1/4] 停 L2（保留 anvil / op-geth datadir）----------
echo "[1/4] 停止 L2 组件..."
bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh"
echo ""

# ---------- [2/4] 同步分叉时间到 rollup.json + genesis.json（分叉调度的唯一入口）----------
# 分叉时间单一真源 = .envrc 的 FORK_*_TIME。本脚本是唯一把它写进配置的地方：
#   - rollup.json 的 *_time（op-node 读）
#   - genesis.json 的 config.*Time（op-geth/reth 共用；调 bake-genesis-forks.sh）
# 二者同处、同次、同源，绝不相互漂移。变量非空→写入；为空→rollup 置 null / genesis 删 key。
# 运行时兼容修正（genesis.l1.hash/da_challenge/chain_op_config）已在 setup 阶段由
# patch-rollup-config.sh 做过且幂等，这里不重复。
echo "[2/4] 同步分叉时间到 rollup.json + genesis.json（源：.envrc FORK_*_TIME）..."
TMP_FILE="$ROLLUP_FILE.tmp"
sync_fork() {  # $1=rollup.json 里的 fork 名  $2=对应 FORK_*_TIME 值
  local key="$1" val="$2"
  if [ -n "$val" ]; then
    jq --argjson t "$val" ".${key}_time = \$t" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  else
    jq ".${key}_time = null" "$ROLLUP_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$ROLLUP_FILE"
  fi
  echo "    ${key}_time = ${val:-null}"
}
sync_fork fjord    "${FORK_FJORD_TIME:-}"
sync_fork granite  "${FORK_GRANITE_TIME:-}"
sync_fork holocene "${FORK_HOLOCENE_TIME:-}"
sync_fork isthmus  "${FORK_ISTHMUS_TIME:-}"
sync_fork jovian   "${FORK_JOVIAN_TIME:-}"
echo "  同步分叉表到 genesis.json（geth/reth 共用）..."
bash "$BASE_PATH/scripts/chain-ops/bake-genesis-forks.sh"
echo ""

# ---------- [3/4] 在既有链上 re-init op-geth（只更新分叉表、保留链数据）----------
# genesis 分叉表已在 [2/4] 同步补好（sync_fork 写 rollup + bake-genesis-forks.sh 烘 genesis）。
# 这里只需对既有 op-geth datadir 重跑 geth init：geth init 对创世 hash 匹配的库是非破坏的，
# 只把分叉表写回 DB、保全部块数据（把尚未到达的未来分叉写入是兼容的；若想把已过去的分叉往前改，
# geth 会以 mismatching 报错拦截）。reth 系与 geth 共用同一份 genesis，无需单独处理。
echo "[3/4] re-init op-geth（保留链数据，只更新分叉表）..."
OP_GETH_DATA_PATH="$BASE_PATH/data/op-geth"
GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
if [ -d "$OP_GETH_DATA_PATH/geth" ]; then
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$GENESIS_FILE"
else
  echo "  op-geth datadir 尚未初始化，跳过 re-init（将由 chain-start 首次 init）。"
fi
echo ""

# ---------- [4/4] 重启 L2（geth 从更新后的 genesis 读分叉表；chain-start 不再 re-init）----------
echo "[4/4] 重启 L2..."
bash "$BASE_PATH/scripts/chain-ops/chain-start.sh" "$CHAIN_ENV"

echo ""
echo "=== Fork 激活流程完成 ==="
echo "验证：分叉到点后观察 L2 区块行为；rollup.json 的 *_time 见 $ROLLUP_FILE"
