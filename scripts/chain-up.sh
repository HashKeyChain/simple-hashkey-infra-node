#!/bin/bash
#
# 一键启动链：若配置未生成则先执行 chain-setup，再执行 chain-start。
# 仅简化「先 setup 再 start」为一条命令，适用于 local 或 server。
#
# 用法:
#   bash scripts/chain-up.sh [local|server]
#
# 若 config/<env>/rollup.json 已存在则直接 start，否则先 setup 再 start。
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  source .envrc 2>/dev/null || true
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
fi

if [ "$CHAIN_ENV" = "local" ]; then
  CONFIG_DIR="$BASE_PATH/config/local"
else
  source .envrc 2>/dev/null || true
  CONFIG_DIR="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/getting-started}"
fi

NEED_SETUP=0
if [ ! -f "$CONFIG_DIR/rollup.json" ] || [ ! -f "$CONFIG_DIR/genesis.json" ]; then
  NEED_SETUP=1
fi
if [ "${FORCE_SETUP:-0}" = "1" ]; then
  NEED_SETUP=1
fi

if [ "$NEED_SETUP" = "1" ]; then
  echo "Running chain-setup..."
  # setup 会重新部署 L1 合约，需要清掉旧的 op-geth 数据（genesis 会变）
  export CLEAN_OP_GETH_DATADIR=1
  # 清掉 op-node safedb（旧链数据不兼容）
  rm -rf "$BASE_PATH/data/op-node/safedb" 2>/dev/null || true
  # local 时停掉旧 anvil（重新部署需要干净的 L1）
  if [ "$CHAIN_ENV" = "local" ]; then
    echo "Stopping old anvil..."
    # 停本机 anvil 进程
    if [ -f "$BASE_PATH/data/pids/anvil.pid" ]; then
      kill "$(cat "$BASE_PATH/data/pids/anvil.pid")" 2>/dev/null || true
      rm -f "$BASE_PATH/data/pids/anvil.pid"
    fi
    # 也清理可能残留的 Docker anvil
    docker rm -f anvil-chain 2>/dev/null || true
    # 确保 8545 端口释放
    for pid in $(lsof -i :8545 -t 2>/dev/null); do
      kill "$pid" 2>/dev/null || true
    done
    sleep 1
  fi
  bash "$SCRIPT_DIR/chain-setup.sh" "$CHAIN_ENV"
fi

echo ""
echo "Starting all services..."
bash "$SCRIPT_DIR/chain-start.sh" "$CHAIN_ENV"
