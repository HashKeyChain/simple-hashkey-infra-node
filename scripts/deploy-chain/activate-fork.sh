#!/bin/bash
#
# 启动新分叉（在已运行的链上推进硬分叉）。
#
# 背景：链初次 setup 只从 fjord 起步，其余分叉在 .envrc 的 FORK_*_TIME 留空。要激活新分叉时，
# 分叉时间是单一真源（.envrc 的 FORK_*_TIME），本脚本把它同步到两个消费方并重启链：
#   - rollup.json 的 *_time（op-node 读）           <- scripts/patch-rollup-config.sh
#   - op-geth 的 --override.*（op-geth 读）          <- scripts/run-op-geth.sh 启动时现场组装
#
# 使用流程：
#   1. 编辑 .envrc，把要激活的分叉 FORK_*_TIME 填成目标 unix 时间戳；
#      建议取"当前之后"的时间（如 now+60），这样能观察到 pre->post 的过渡区块；
#      填 0 表示创世即激活（仅对全新链有意义）；留空表示不启动该分叉。
#   2. 运行本脚本：它自动 停 L2 -> 同步 rollup.json -> 重启 L2（geth 现场组装 override）。
#      注意：本脚本不重启 anvil、不重建 op-geth datadir，链从当前高度继续，分叉在目标时间激活。
#
# 用法:
#   bash scripts/deploy-chain/activate-fork.sh [local|remote]
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
  echo "Usage: bash scripts/deploy-chain/activate-fork.sh [local|remote]"
  exit 1
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

ROLLUP_FILE="$BASE_PATH/config/$DEPLOYMENT_CONTEXT/rollup.json"
if [ ! -f "$ROLLUP_FILE" ]; then
  echo "Error: rollup.json 不存在: $ROLLUP_FILE" >&2
  echo "       先运行 bash scripts/deploy-chain/chain-setup.sh $CHAIN_ENV 生成配置。" >&2
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

# ---------- [1/3] 停 L2（保留 anvil / op-geth datadir）----------
echo "[1/3] 停止 L2 组件..."
bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh"
echo ""

# ---------- [2/3] 同步 rollup.json 的 fork 时间（op-node 侧）----------
# patch-rollup-config.sh 的 [4/4] 会把 .envrc 的 FORK_*_TIME 写进 rollup.json；
# 其余步骤（genesis.l1.hash/da_challenge/chain_op_config）对已 setup 的链是幂等 no-op。
echo "[2/3] 同步 rollup.json fork 时间..."
bash "$SCRIPT_DIR/patch-rollup-config.sh" "$CHAIN_ENV"
echo ""

# ---------- [3/3] 重启 L2（op-geth 侧 override 由 run-op-geth.sh 现场组装）----------
echo "[3/3] 重启 L2..."
bash "$BASE_PATH/scripts/chain-ops/chain-start.sh" "$CHAIN_ENV"

echo ""
echo "=== Fork 激活流程完成 ==="
echo "验证：分叉到点后观察 L2 区块行为；rollup.json 的 *_time 见 $ROLLUP_FILE"
