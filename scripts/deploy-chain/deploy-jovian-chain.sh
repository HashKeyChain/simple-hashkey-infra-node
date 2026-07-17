#!/bin/bash
#
# 一键部署并把链推进到指定分叉（默认 Jovian）。
#
# 背景：目前"部署时即为 Jovian 分叉"的代码尚未开发，无法直接生成 Jovian 创世。
# 唯一可行路径是与 runbook 一致的"时间激活"：
#   部署到 fjord 基线 → 起链 → 配置 granite..jovian 的未来激活时间 →
#   停链 / 同步 rollup.json / 重启（op-geth 现场组装 --override.*）→
#   墙钟到点后，链在若干区块内依次硬分叉，直到目标分叉。
# 本脚本把上面这套流程压成一条命令，便于反复搭建"与主网/测试网同分叉"的链去接 flashblocks。
#
# 分叉时间唯一真源仍是 .envrc 的 FORK_*_TIME：本脚本按当前 L2 时间现场计算后写回 .envrc，
# 再复用 chain-setup / chain-start / activate-fork，不引入新的真源。
#
# 用法:
#   bash scripts/deploy-chain/deploy-jovian-chain.sh [local|remote] [选项]
#
# 选项:
#   --reset          先执行 chain-reset（停链 + 删 data/ + 删 config/<ctx>/ + 清 CGT 地址），
#                    部署一条全新链。对"已存在链"再次部署必须加 --reset，否则脚本拒绝执行。
#   --pace=SEC       相邻分叉的激活间隔秒数（默认 2）。
#   --lead=SEC       从"当前 L2 时间"到首个待激活分叉的提前量（默认 30，需 > 重启耗时）。
#   --target=FORK    推进到哪个分叉为止：granite | holocene | isthmus | jovian（默认 jovian）。
#   -y, --yes        传给 chain-reset，跳过其不可逆二次确认。
#
# 不传 env 时按 L1_RPC_URL 自动判断（含 localhost/127.0.0.1 视为 local）。
#
# 完成后：链已激活到 <target>；脚本会等待并校验（jovian/isthmus 额外查 GasPriceOracle）。
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

CHAIN_OPS_DIR="$BASE_PATH/scripts/chain-ops"
GAS_PRICE_ORACLE="0x420000000000000000000000000000000000000F"
ALL_FORKS=(granite holocene isthmus jovian)

usage() {
  echo "Usage: bash scripts/deploy-chain/deploy-jovian-chain.sh [local|remote] [--reset] [--pace=SEC] [--lead=SEC] [--target=granite|holocene|isthmus|jovian] [-y|--yes]" >&2
}

# ---------- 解析参数 ----------
CHAIN_ENV=""
DO_RESET=0
ASSUME_YES=0
PACE=2
LEAD=30
TARGET=jovian
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --reset)      DO_RESET=1 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --pace=*)     PACE="${arg#*=}" ;;
    --lead=*)     LEAD="${arg#*=}" ;;
    --target=*)   TARGET="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2; usage; exit 1 ;;
  esac
done

# 数值校验（bash 3.2 兼容，不用 ${v,,}）
case "$PACE" in ''|*[!0-9]*) echo "Error: --pace 必须是非负整数，收到 '$PACE'" >&2; exit 1 ;; esac
case "$LEAD" in ''|*[!0-9]*) echo "Error: --lead 必须是非负整数，收到 '$LEAD'" >&2; exit 1 ;; esac

# target 合法性
TARGET_IDX=-1
for i in "${!ALL_FORKS[@]}"; do
  [ "${ALL_FORKS[$i]}" = "$TARGET" ] && TARGET_IDX=$i
done
if [ "$TARGET_IDX" -lt 0 ]; then
  echo "Error: --target 非法：$TARGET（可选 ${ALL_FORKS[*]}）" >&2
  exit 1
fi

# ---------- 解析运行环境 ----------
if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi
if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  usage; exit 1
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

# L2 RPC（op-geth http 端口，local/remote 均为 8645）
L2_RPC="${L2_RPC_URL:-http://localhost:8645}"

echo "============================================"
echo "  Deploy chain → activate up to '$TARGET'"
echo "============================================"
echo "  CHAIN_ENV = $CHAIN_ENV"
echo "  reset     = $([ "$DO_RESET" = 1 ] && echo yes || echo no)"
echo "  pace      = ${PACE}s (相邻分叉间隔)"
echo "  lead      = ${LEAD}s (首个分叉提前量)"
echo "  target    = $TARGET"
echo "  L2 RPC    = $L2_RPC"
echo ""

# ---------- 分叉时间写入 .envrc 的辅助函数 ----------
# 用法: set_fork_times "0" "" "" "" ""  # 依次 fjord granite holocene isthmus jovian（空串=清空）
set_fork_times() {
  _FJORD="$1" _GRANITE="$2" _HOLOCENE="$3" _ISTHMUS="$4" _JOVIAN="$5" \
  python3 - <<'PY'
import os, re
from pathlib import Path

vals = {
    "FJORD":    os.environ["_FJORD"],
    "GRANITE":  os.environ["_GRANITE"],
    "HOLOCENE": os.environ["_HOLOCENE"],
    "ISTHMUS":  os.environ["_ISTHMUS"],
    "JOVIAN":   os.environ["_JOVIAN"],
}
path = Path(".envrc")
text = path.read_text()
for name, v in vals.items():
    pat = re.compile(rf'^export FORK_{name}_TIME=.*$', re.M)
    repl = f'export FORK_{name}_TIME={v}'
    if pat.search(text):
        text = pat.sub(repl, text)
    else:
        text = text.rstrip("\n") + "\n" + repl + "\n"
path.write_text(text)
PY
}

# ---------- [1/7] 可选 reset ----------
DATA_DIR="$BASE_PATH/data"
CONFIG_DIR="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
if [ "$DO_RESET" = "1" ]; then
  echo "[1/7] Reset 旧链状态..."
  reset_args=("$CHAIN_ENV")
  [ "$ASSUME_YES" = "1" ] && reset_args+=(--yes)
  bash "$SCRIPT_DIR/chain-reset.sh" "${reset_args[@]}"
else
  echo "[1/7] 跳过 reset（未加 --reset）"
  if [ -d "$DATA_DIR" ] || [ -d "$CONFIG_DIR" ]; then
    echo "Error: 检测到已存在的链状态：" >&2
    [ -d "$DATA_DIR" ]   && echo "         $DATA_DIR" >&2
    [ -d "$CONFIG_DIR" ] && echo "         $CONFIG_DIR" >&2
    echo "       重新部署一条全新链请加 --reset（会清空以上目录）。" >&2
    exit 1
  fi
fi
echo ""

# ---------- [2/7] 归零分叉时间，保证从纯 fjord 基线部署 ----------
# fjord=0（创世激活）；granite..jovian 先清空，避免部署阶段就把后续分叉写进 rollup.json。
echo "[2/7] 配置 .envrc：fjord=0，granite..jovian 清空（纯 fjord 基线）"
set_fork_times "0" "" "" "" ""
echo ""

# ---------- [3/7] 部署合约 + 生成配置 ----------
echo "[3/7] 部署合约、生成 genesis/rollup（chain-setup）..."
bash "$SCRIPT_DIR/chain-setup.sh" "$CHAIN_ENV"
echo ""

# ---------- [4/7] 起链（纯 fjord）----------
echo "[4/7] 启动 L2（纯 fjord，chain-start）..."
bash "$CHAIN_OPS_DIR/chain-start.sh" "$CHAIN_ENV"
echo ""

# ---------- [5/7] 等 L2 出块并读取当前 L2 时间 ----------
echo "[5/7] 等待 L2 出块..."
L2_TS=""
for i in $(seq 1 60); do
  raw=$(cast block latest --rpc-url "$L2_RPC" --json 2>/dev/null | jq -r '.timestamp' 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    L2_TS=$(( raw ))   # 兼容十六进制(0x..)与十进制
    if [ "$L2_TS" -gt 0 ]; then break; fi
  fi
  sleep 1
done
if [ -z "$L2_TS" ] || [ "$L2_TS" -le 0 ]; then
  echo "Error: 60s 内未能从 $L2_RPC 读到有效 L2 区块时间，L2 可能未正常启动。" >&2
  echo "       排查：data/logs/op-geth.log、data/logs/op-node.log" >&2
  exit 1
fi
echo "  当前 L2 时间戳: $L2_TS"

# 计算各分叉激活时间：base = L2_now + lead；从 granite 起每档 +pace，直到 target；target 之后留空。
# bash 3.2 无关联数组，用 FT_<fork> 平铺变量 + eval 赋值。
BASE=$(( L2_TS + LEAD ))
FT_granite=""; FT_holocene=""; FT_isthmus=""; FT_jovian=""
t=$BASE
idx=0
for fork in "${ALL_FORKS[@]}"; do
  if [ "$idx" -le "$TARGET_IDX" ]; then
    eval "FT_${fork}=$t"
    t=$(( t + PACE ))
  fi
  idx=$(( idx + 1 ))
done
echo "  计划分叉时间（fjord=0 创世已激活）:"
printf '    %-9s %s\n' granite  "${FT_granite:-<不激活>}"
printf '    %-9s %s\n' holocene "${FT_holocene:-<不激活>}"
printf '    %-9s %s\n' isthmus  "${FT_isthmus:-<不激活>}"
printf '    %-9s %s\n' jovian   "${FT_jovian:-<不激活>}"
echo ""

# ---------- [6/7] 写回 .envrc 并激活分叉（停链→同步 rollup→重启）----------
echo "[6/7] 写回 .envrc 并 activate-fork..."
set_fork_times "0" "$FT_granite" "$FT_holocene" "$FT_isthmus" "$FT_jovian"
bash "$SCRIPT_DIR/activate-fork.sh" "$CHAIN_ENV"
echo ""

# ---------- [7/7] 等待并校验目标分叉激活 ----------
eval "TARGET_TIME=\$FT_${TARGET}"
# 超时预算：提前量 + 所有档位间隔 + 重启/派生缓冲。
TIMEOUT=$(( LEAD + PACE * ${#ALL_FORKS[@]} + 150 ))
echo "[7/7] 等待墙钟到达 $TARGET 激活时间($TARGET_TIME)并出块，最多 ${TIMEOUT}s..."
reached=0
for i in $(seq 1 "$TIMEOUT"); do
  raw=$(cast block latest --rpc-url "$L2_RPC" --json 2>/dev/null | jq -r '.timestamp' 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "null" ]; then
    cur=$(( raw ))
    if [ "$cur" -ge "$TARGET_TIME" ]; then reached=1; break; fi
  fi
  sleep 1
done

if [ "$reached" != "1" ]; then
  echo "WARN: 超时仍未观察到 L2 时间越过 $TARGET 激活点。请检查 data/logs/op-node.log。" >&2
else
  echo "  L2 时间已越过 $TARGET 激活点。"
fi

# 对可查询的分叉做 GasPriceOracle 断言（granite/holocene 该预编译无对应 is* 方法，跳过）。
verify_oracle() {  # $1=方法名 如 isJovian
  local method="$1" out
  out=$(cast call "$GAS_PRICE_ORACLE" "${method}()(bool)" --rpc-url "$L2_RPC" 2>/dev/null || echo "")
  echo "$out"
}
case "$TARGET" in
  jovian)  m=isJovian  ;;
  isthmus) m=isIsthmus ;;
  *)       m="" ;;
esac
if [ -n "$m" ]; then
  val=$(verify_oracle "$m")
  echo "  GasPriceOracle.${m}() = ${val:-<查询失败>}"
  if [ "$val" != "true" ]; then
    echo "  WARN: ${m}() 尚未为 true，可能还需再等一两个区块，或分叉未正确激活。" >&2
  fi
fi

echo ""
echo "=== 完成 ==="
echo "  已按计划把链推进到分叉: $TARGET"
echo "  分叉时间真源: .envrc 的 FORK_*_TIME（本脚本已写入）"
echo "  L2 RPC:     $L2_RPC"
echo "  Rollup RPC: ${OP_NODE_RPC_URL:-http://localhost:9545}"
echo "  日志:       data/logs/*.log"
echo ""
echo "验证分叉标志:"
echo "  cast call $GAS_PRICE_ORACLE \"isJovian()(bool)\" --rpc-url $L2_RPC"
