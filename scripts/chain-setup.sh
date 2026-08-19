#!/bin/bash
#
# 一键生成 rollup.json 和 genesis.json（部署 L1 合约并生成 L2 配置）。
# 不启动 L2 节点，仅完成配置生成。
#
# 用法:
#   bash scripts/chain-setup.sh [local|remote]
#
# 参数:
#   local  - 本地环境：若 L1 未运行则自动启动 anvil，再部署合约并生成配置
#   remote - 远端环境：使用 .envrc 中的 L1_RPC_URL，直接部署并生成配置
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
  echo "Usage: bash scripts/chain-setup.sh [local|remote]"
  exit 1
fi

# local 时：用本机 anvil；生成文件目录仍按 .envrc 的 DEPLOYMENT_CONTEXT。
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
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
    echo "L1 not running. Starting anvil in background with block time ${L1_BLOCK_TIME}s..."
    # 端口发布限制在宿主回环；容器内 --host=0.0.0.0 必须保留（理由见 chain-start.sh）。
    docker run --rm -d -p 127.0.0.1:8545:8545 --name anvil-chain \
      --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 \
      --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 \
      --slots-in-an-epoch=1 --block-time $L1_BLOCK_TIME
    ANVIL_PID="docker"
    wait_l1
  else
    echo "L1 already running at $L1_RPC_URL"
  fi
else
  # remote: 直接检查 L1 可用
  echo "Checking L1 RPC..."
  wait_l1
fi

# local 模式：给部署/运行账户充值。
# anvil 只给它自己派生的 20 个账户预置余额，而 .envrc 里的 DEPLOY/GS_* 是自定义账户，
# 在全新 anvil 上余额为 0，会导致后续 CGT/合约部署因 gas 不足失败。
# 本地 Anvil 直接改余额，不走交易确认，避免受 L1_BLOCK_TIME 影响变慢。
if [ "$CHAIN_ENV" = "local" ]; then
  echo "Funding deploy/operator accounts..."
  for addr in "$DEPLOY_ADDRESS" "$GS_ADMIN_ADDRESS" "$GS_BATCHER_ADDRESS" "$GS_PROPOSER_ADDRESS" "$GS_SEQUENCER_ADDRESS"; do
    [ -z "$addr" ] && continue
    cast rpc anvil_setBalance "$addr" 0x3635c9adc5dea00000 --rpc-url "$L1_RPC_URL" >/dev/null 2>&1 \
      && echo "  funded $addr" || echo "  WARN: fund $addr failed"
  done

  # 本地 anvil 默认不预置 Multicall3，而 op-challenger 依赖它做批量读，缺失会报
  # "failed to fetch batch: Resource not found"。在部署合约前用官方 keyless 预签名交易
  # 部署到 canonical 地址，使后续所有块都可用。（幂等）
  echo "Deploying Multicall3..."
  bash "$SCRIPT_DIR/deploy-multicall3.sh"
fi

echo ""
echo "Running contract deployment and generating genesis/rollup config..."
bash "$SCRIPT_DIR/deploy-contracts.sh"

# 把部署生成的 rollup.json 修正为运行时 op-node(cgt-jovian/v1.16.5) 可用的形态：
# 删除 da_challenge_contract_address、补齐 chain_op_config；local 额外刷新 genesis.l1.hash。
# 这样 setup 完可直接 chain-start，无需手动 patch。（幂等，可重复执行）
echo ""
echo "Patching rollup.json compatibility..."
bash "$SCRIPT_DIR/patch-rollup-config.sh" "$CHAIN_ENV"

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
