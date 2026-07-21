#!/bin/bash
#
# 重置本地/远端链，为"从零重建一条新链"做准备（对应 runbook 的 Reset Local Environment）。
#
# 做的事（破坏性，不可逆）：
#   1. 停止 L2 组件（chain-stop.sh）
#   2. [仅 local] 停止 anvil 容器（docker stop anvil-chain）
#   3. 删除 data/（op-geth datadir、op-node safedb、logs、pids、jwt 等）
#   4. 删除 config/<DEPLOYMENT_CONTEXT>/（本次部署生成的 artifact/genesis/rollup/state-dump）
#   5. [仅 local] 清空 .envrc 的 CUSTOM_GAS_TOKEN_ADDRESS —— 因为重建的 anvil 上没有旧 CGT，
#      留着旧地址会让 deploy-contracts 复用一个不存在的合约；清空后 setup 会重新部署并回填。
#
# 重置后重建：
#   bash scripts/chain-setup.sh <env>   # 部署合约、生成配置、纯-fjord
#   bash scripts/chain-start.sh <env>   # 启动全部服务
#
# 用法:
#   bash scripts/chain-reset.sh [local|remote] [-y|--yes]
#     -y / --yes  跳过确认（默认会要求二次确认，因为不可逆）
#   不传 env 时按 L1_RPC_URL 自动判断（含 localhost/127.0.0.1 视为 local）。
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

# ---------- 解析参数 ----------
CHAIN_ENV=""
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    -y|--yes)     ASSUME_YES=1 ;;
    *) echo "Usage: bash scripts/chain-reset.sh [local|remote] [-y|--yes]" >&2; exit 1 ;;
  esac
done

if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi

# ---------- 路径解析 + 安全校验（防止空变量导致误删）----------
if [ -z "${BASE_PATH:-}" ] || [ ! -d "$BASE_PATH/scripts" ]; then
  echo "Error: BASE_PATH 解析异常，拒绝执行删除。" >&2
  exit 1
fi
if [ -z "${DEPLOYMENT_CONTEXT:-}" ]; then
  echo "Error: DEPLOYMENT_CONTEXT 为空，无法定位 config 目录，拒绝执行。" >&2
  exit 1
fi

DATA_DIR="$BASE_PATH/data"
CONFIG_DIR="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"

# CONFIG_DIR 必须严格位于 $BASE_PATH/config/<非空> 之下，否则拒绝
case "$CONFIG_DIR" in
  "$BASE_PATH/config/"?*) : ;;
  *) echo "Error: CONFIG_DIR=$CONFIG_DIR 非法，拒绝执行。" >&2; exit 1 ;;
esac

# ---------- 打印将要执行的操作 ----------
echo "============================================"
echo "  Chain Reset ($CHAIN_ENV)  —— 破坏性、不可逆"
echo "============================================"
echo "将执行："
echo "  1) 停止 L2 组件 (chain-stop.sh)"
[ "$CHAIN_ENV" = "local" ] && echo "  2) 停止 anvil 容器 (docker stop anvil-chain)"
echo "  3) 删除数据目录:   $DATA_DIR"
echo "  4) 删除生成配置:   $CONFIG_DIR"
[ "$CHAIN_ENV" = "local" ] && echo "  5) 清空 .envrc 的 CUSTOM_GAS_TOKEN_ADDRESS"
if [ "$CHAIN_ENV" = "remote" ]; then
  echo ""
  echo "  注意：remote 模式不会停止/清除真实 L1（anvil）与 CUSTOM_GAS_TOKEN_ADDRESS；"
  echo "        仅删除本地的 data/ 与 config/$DEPLOYMENT_CONTEXT/。"
fi
echo ""

# ---------- 二次确认 ----------
if [ "$ASSUME_YES" != "1" ]; then
  printf "确认重置？输入 y 继续，其它任意键取消: "
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) : ;;
    *) echo "已取消。"; exit 0 ;;
  esac
fi

# ---------- [1] 停 L2 ----------
echo ""
echo "[1] 停止 L2 组件..."
bash "$BASE_PATH/scripts/chain-ops/chain-stop.sh" || true

# ---------- [2] 停 anvil（仅 local）----------
if [ "$CHAIN_ENV" = "local" ]; then
  echo "[2] 停止 anvil 容器..."
  docker stop anvil-chain >/dev/null 2>&1 && echo "  anvil-chain stopped" || echo "  anvil-chain 未运行/已停止"
fi

# ---------- [3] 删 data ----------
echo "[3] 删除数据目录 $DATA_DIR ..."
rm -rf "$DATA_DIR"
echo "  已删除"

# ---------- [4] 删生成配置 ----------
echo "[4] 删除生成配置 $CONFIG_DIR ..."
rm -rf "$CONFIG_DIR"
echo "  已删除"

# ---------- [5] 清空 CUSTOM_GAS_TOKEN_ADDRESS（仅 local）----------
if [ "$CHAIN_ENV" = "local" ]; then
  echo "[5] 清空 .envrc 的 CUSTOM_GAS_TOKEN_ADDRESS ..."
  python3 - <<'PY'
from pathlib import Path

path = Path(".envrc")
s = path.read_text()
lines = s.splitlines()
changed = False
for i, line in enumerate(lines):
    if line.startswith("export CUSTOM_GAS_TOKEN_ADDRESS="):
        if line != "export CUSTOM_GAS_TOKEN_ADDRESS=":
            lines[i] = "export CUSTOM_GAS_TOKEN_ADDRESS="
            changed = True
path.write_text("\n".join(lines) + "\n")
print("  已清空" if changed else "  已是空值，无需改动")
PY
fi

echo ""
echo "=== Reset 完成 ==="
echo "下一步重建新链："
echo "  source .envrc"
echo "  bash scripts/chain-setup.sh $CHAIN_ENV"
echo "  bash scripts/chain-start.sh $CHAIN_ENV"
