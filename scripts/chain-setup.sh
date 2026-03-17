#!/bin/bash
#
# 一键生成 rollup.json 和 genesis.json（部署 L1 合约并生成 L2 配置）。
# 不启动 L2 节点，仅完成配置生成。
#
# 用法:
#   bash scripts/chain-setup.sh [local|server]
#
# 参数:
#   local  - 本地环境：若 L1 未运行则自动启动 anvil，再部署合约并生成配置
#   server - 服务器环境：使用 .envrc 中的 L1_RPC_URL，直接部署并生成配置
#
# 若不传参，则根据 L1_RPC_URL 自动判断（含 localhost/127.0.0.1 视为 local）。
#
# 生成文件位置:
#   - $DEPLOYMENT_CONFIG_PATH/rollup.json
#   - $DEPLOYMENT_CONFIG_PATH/genesis.json
#   - $DEPLOYMENT_CONFIG_PATH/artifact.json
#   - $DEPLOYMENT_CONFIG_PATH/state-dump-latest.json
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

# 解析运行环境：local | server
CHAIN_ENV="${1:-}"

if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=server
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV (from L1_RPC_URL)"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "server" ]; then
  echo "Usage: bash scripts/chain-setup.sh [local|server]"
  exit 1
fi

# local 时：用本机 anvil，且生成文件放到 config/local（不放到 getting-started）
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONTEXT=local
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/local"
fi

echo "=== Chain Setup (genesis.json + rollup.json) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo "DEPLOYMENT_CONFIG_PATH=$DEPLOYMENT_CONFIG_PATH"
echo ""

# 等待 L1 RPC 就绪
wait_l1() {
  local max=30
  local n=0
  while ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; do
    n=$((n + 1))
    if [ $n -ge $max ]; then
      echo "Error: L1 RPC not ready at $L1_RPC_URL after ${max}s"
      exit 1
    fi
    echo "  Waiting for L1... ($n/$max)"
    sleep 1
  done
  echo "  L1 RPC ready."
}

ANVIL_PID=""

if [ "$CHAIN_ENV" = "local" ]; then
  if ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; then
    echo "L1 not running. Starting anvil in background..."
    docker run --rm -d -p 8545:8545 --name anvil-chain \
      --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 \
      --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 \
      --slots-in-an-epoch=1 --block-time 1
    ANVIL_PID="docker"
    wait_l1
  else
    echo "L1 already running at $L1_RPC_URL"
  fi
else
  # server: 直接检查 L1 可用
  echo "Checking L1 RPC..."
  wait_l1
fi

echo ""
echo "Running contract deployment and generating genesis/rollup config..."
bash "$SCRIPT_DIR/deploy-contracts.sh"

# 若本次脚本启动了 anvil，可选保留或关闭（保留便于后续 chain-start 使用）
if [ -n "$ANVIL_PID" ]; then
  echo ""
  echo "Anvil is still running in container 'anvil-chain'. Stop with: docker stop anvil-chain"
fi

echo ""
echo "=== Setup complete ==="
echo "Generated files:"
echo "  rollup.json  -> $DEPLOYMENT_CONFIG_PATH/rollup.json"
echo "  genesis.json -> $DEPLOYMENT_CONFIG_PATH/genesis.json"
echo "  artifact.json -> $DEPLOYMENT_CONFIG_PATH/artifact.json"
echo ""
echo "Next: run 'bash scripts/chain-start.sh $CHAIN_ENV' to start all services."
