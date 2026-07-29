#!/bin/bash
#
# 一键启动所有服务（L1 可选、op-geth、op-node、op-batcher、op-proposer、op-challenger）。
# 需先执行 chain-setup.sh 生成 rollup.json 和 genesis.json。
#
# 用法:
#   bash scripts/chain-start.sh [local|remote]
#
# 参数:
#   local  - 本地：若 L1 未运行则启动 anvil，再启动 op-geth / op-node / batcher / proposer
#   remote - 远端：不启动 L1，仅启动 op-geth / op-node / batcher / proposer
#
# 若不传参，根据 L1_RPC_URL 自动判断。
#
# 环境变量（可选）:
#   SKIP_BATCHER=1    - 不启动 op-batcher
#   SKIP_PROPOSER=1   - 不启动 op-proposer
#   SKIP_CHALLENGER=1 - 不启动 op-challenger（仅 USE_FAULT_PROOFS=true 时才会启动）
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

# 数据与日志目录
DATA_DIR="${BASE_PATH}/data"
LOG_DIR="${DATA_DIR}/logs"
PID_DIR="${DATA_DIR}/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# 解析运行环境
CHAIN_ENV="${1:-}"
if [ -z "$CHAIN_ENV" ]; then
  if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
    CHAIN_ENV=local
  else
    CHAIN_ENV=remote
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "remote" ]; then
  echo "Usage: bash scripts/chain-start.sh [local|remote]"
  exit 1
fi

# local 时：用本机 anvil。
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
fi

# local 与 remote 统一从 config/<context>/ 加载已 patch 的规范配置
# （config 目录是 git 跟踪、经 runbook patch 后的配置；deployments 只是构建原始产物）。
export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
export OP_GETH_GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
export OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
export DEPLOYMENT_OUTFILE="$DEPLOYMENT_CONFIG_PATH/artifact.json"

# 检查必要配置是否已生成
if [ ! -f "$OP_NODE_ROLLUP_FILE" ] || [ ! -f "$OP_GETH_GENESIS_FILE" ]; then
  echo "Error: rollup.json or genesis.json not found. Run first: bash scripts/chain-setup.sh $CHAIN_ENV"
  echo "  OP_NODE_ROLLUP_FILE=$OP_NODE_ROLLUP_FILE"
  echo "  OP_GETH_GENESIS_FILE=$OP_GETH_GENESIS_FILE"
  exit 1
fi

echo "=== Chain Start (all services) ==="
echo "CHAIN_ENV=$CHAIN_ENV"
echo "L1_RPC_URL=$L1_RPC_URL"
echo ""

# ---------- L1 (仅 local) ----------
if [ "$CHAIN_ENV" = "local" ]; then
  if ! cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null; then
    echo "Starting anvil with block time ${L1_BLOCK_TIME}s..."
    # --rm 容器的删除是异步的：上一次 stop 一返回就走到这里，旧容器可能还没消失，
    # 直接 run 会因同名冲突失败。先强删并等它真正消失。
    docker rm -f anvil-chain >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      [ -z "$(docker ps -aq -f name='^anvil-chain$')" ] && break
      sleep 0.5
    done
    docker run --rm -d -p 8545:8545 --name anvil-chain \
      --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 \
      --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 \
      --slots-in-an-epoch=1 --block-time $L1_BLOCK_TIME
    echo "Waiting for anvil..."
    for i in $(seq 1 15); do
      cast block latest --rpc-url "$L1_RPC_URL" &>/dev/null && break
      sleep 1
    done
    echo "Anvil started."
  else
    echo "L1 already running at $L1_RPC_URL"
  fi
fi

# ---------- JWT（op-geth / op-node 共用）----------
export OP_GETH_DATA_PATH="${DATA_DIR}/op-geth"
mkdir -p "$OP_GETH_DATA_PATH"
JWT_FILE="${OP_GETH_DATA_PATH}/jwt.txt"
if [ ! -f "$JWT_FILE" ]; then
  openssl rand -hex 32 > "$JWT_FILE"
  echo "Generated JWT at $JWT_FILE"
fi

# 分叉表由 activate-fork.sh 在激活分叉时烘入 genesis.json（sync_fork 写 rollup + bake-genesis-forks.sh
# 烘 genesis，源自 .envrc FORK_*_TIME，geth/reth 共用）。chain-start 不 bake：普通重启不改分叉表。

# ---------- op-geth init（仅首次建库）----------
# 普通重启不 re-init。激活分叉（改分叉表）时的 re-init 由 activate-fork.sh 负责：
# geth init 对创世 hash 匹配的既有 datadir 是非破坏的，只更新分叉表、保留链数据。
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "Initializing op-geth datadir (fresh)..."
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$OP_GETH_GENESIS_FILE"
fi

# ---------- 下传编排层覆盖后的关键变量给 run-op-*（调用方值优先，脚本内 .envrc 兜底）----------
export SAFEDB_PATH="${DATA_DIR}/op-node/safedb"
mkdir -p "$(dirname "$SAFEDB_PATH")"
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export _CALLER_OP_GETH_DATA_PATH="$OP_GETH_DATA_PATH"
export _CALLER_JWT_FILE="$JWT_FILE"
export _CALLER_OP_NODE_ROLLUP_FILE="$OP_NODE_ROLLUP_FILE"
export _CALLER_DEPLOYMENT_OUTFILE="$DEPLOYMENT_OUTFILE"
export _CALLER_SAFEDB_PATH="$SAFEDB_PATH"

# 硬分叉时间：由 activate-fork.sh 烘入 genesis.json（源自 .envrc FORK_*_TIME），
# geth 从 genesis 读，不再用 --override.*；op-node 仍读 rollup.json。三者同源一致。

# ---------- 启动 op-geth（组件 flags 见 run-op-geth.sh）----------
echo "Starting op-geth..."
nohup bash "$SCRIPT_DIR/run-op-geth.sh" >> "$LOG_DIR/op-geth.log" 2>&1 &
echo $! > "$PID_DIR/op-geth.pid"
echo "  op-geth started (pid $(cat $PID_DIR/op-geth.pid)), log: $LOG_DIR/op-geth.log"

# 等待 engine RPC 就绪
echo "Waiting for op-geth engine..."
for i in $(seq 1 30); do
  if curl -s -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8645 &>/dev/null; then
    break
  fi
  sleep 1
done
sleep 2

# ---------- Flashblocks 序列器侧（FLASHBLOCKS_MODE != off；op-node 之前起）----------
# 具体编排见 scripts/flashblocks/start-sequencer-side.sh（source 进来共享本脚本作用域）：
# 只起 op-rbuilder + rollup-boost；op-rbuilder 由 rollup-boost 驱动，故此处不起 builder op-node
# （它只用于 off 阶段 pre-warm 冷同步，见 scripts/flashblocks/switch-to-flashblocks-dryrun.sh）。
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  source "$BASE_PATH/scripts/flashblocks/start-sequencer-side.sh"
fi

# ---------- 启动 op-node（组件 flags 见 run-op-node.sh）----------
echo "Starting op-node..."
nohup bash "$SCRIPT_DIR/run-op-node.sh" >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat $PID_DIR/op-node.pid)), log: $LOG_DIR/op-node.log"

sleep 3

# ---------- 启动 op-batcher（可选；组件 flags 见 run-op-batcher.sh）----------
if [ "${SKIP_BATCHER:-0}" != "1" ]; then
  echo "Starting op-batcher..."
  nohup bash "$SCRIPT_DIR/run-op-batcher.sh" >> "$LOG_DIR/op-batcher.log" 2>&1 &
  echo $! > "$PID_DIR/op-batcher.pid"
  echo "  op-batcher started (pid $(cat $PID_DIR/op-batcher.pid)), log: $LOG_DIR/op-batcher.log"
fi

# ---------- 启动 op-proposer（可选；组件 flags 见 run-op-proposer.sh）----------
# 注：anchor 已在部署时用非零 faultGameGenesisOutputRoot(0xdead…) 种入 AnchorStateRegistry，
#     proposer 首次即可建 game，无需再单独初始化 anchor。
if [ "${SKIP_PROPOSER:-0}" != "1" ]; then
  echo "Starting op-proposer..."
  nohup bash "$SCRIPT_DIR/run-op-proposer.sh" >> "$LOG_DIR/op-proposer.log" 2>&1 &
  echo $! > "$PID_DIR/op-proposer.pid"
  echo "  op-proposer started (pid $(cat $PID_DIR/op-proposer.pid)), log: $LOG_DIR/op-proposer.log"
fi

# ---------- 启动 op-challenger（仅 FP 模式；组件 flags 见 run-op-challenger.sh）----------
# challenger 需要链就绪 + 已构建 fault-proof 二进制（bin/cannon、bin/op-program、bin/prestate.json）。
# 它在前台跑（run-op-challenger.sh 末尾 exec），预检失败会退出并写 log，不影响其它组件。
if [ "${USE_FAULT_PROOFS:-false}" = "true" ] && [ "${SKIP_CHALLENGER:-0}" != "1" ]; then
  sleep 3
  echo "Starting op-challenger..."
  nohup bash "$SCRIPT_DIR/run-op-challenger.sh" >> "$LOG_DIR/op-challenger.log" 2>&1 &
  echo $! > "$PID_DIR/op-challenger.pid"
  echo "  op-challenger started (pid $(cat $PID_DIR/op-challenger.pid)), log: $LOG_DIR/op-challenger.log"
fi

# ---------- Flashblocks 用户面（enabled；本地=生产同构，proxy 不省略）----------
# 具体编排见 scripts/flashblocks/start-user-side.sh（source 进来共享本脚本作用域）。
if [ "${FLASHBLOCKS_MODE:-off}" = "enabled" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  source "$BASE_PATH/scripts/flashblocks/start-user-side.sh"
fi

echo ""
echo "=== All services started ==="
echo "  L2 RPC:      $L2_RPC_URL"
echo "  Rollup RPC:  $OP_NODE_RPC_URL"
echo "  PIDs:        $PID_DIR/*.pid"
echo "  Logs:        $LOG_DIR/*.log"
echo ""
echo "Stop all: bash scripts/chain-stop.sh"
