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
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
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
    # 端口发布限制在宿主回环（-p 127.0.0.1:8545:8545），避免 L1 RPC 对整个局域网开放。
    # 容器内的 --host=0.0.0.0 必须保留：anvil 若绑容器内 127.0.0.1，
    # Docker 的端口转发（DNAT 到容器 eth0）就打不到该监听套接字，宿主将完全连不上。
    docker run --rm -d -p 127.0.0.1:8545:8545 --name anvil-chain \
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

# ---------- op-geth init（仅首次）----------
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "Initializing op-geth datadir..."
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

# 硬分叉时间覆盖：op-geth 的 --override.* 由 run-op-geth.sh 从 .envrc 的 FORK_*_TIME
# 现场组装；rollup.json 的 *_time 由 patch-rollup-config.sh 同源写入。启动新分叉用
# scripts/activate-fork.sh（改 .envrc 时间戳后自动停链/同步 rollup/重启）。

# ---------- 启动 op-geth（组件 flags 见 run-op-geth.sh）----------
echo "Starting op-geth..."
nohup bash "$SCRIPT_DIR/run-op-geth.sh" >> "$LOG_DIR/op-geth.log" 2>&1 &
echo $! > "$PID_DIR/op-geth.pid"
echo "  op-geth started (pid $(cat $PID_DIR/op-geth.pid)), log: $LOG_DIR/op-geth.log"

# ---------- [健康检查 1/2] op-geth 自身的公开 HTTP RPC ----------
# 只证明「刚拉起的这个执行层活了」。原先这里是唯一的检查，且循环跑完 30 次也不报错、
# 直接往下走，op-geth 起不来时会被静默吞掉，故补上失败即退出。
echo "Waiting for op-geth HTTP RPC at http://localhost:$OP_GETH_HTTP_PORT ..."
geth_ready=0
for i in $(seq 1 30); do
  if curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "http://localhost:$OP_GETH_HTTP_PORT" >/dev/null 2>&1; then
    geth_ready=1
    break
  fi
  sleep 1
done
if [ "$geth_ready" != "1" ]; then
  echo "Error: op-geth HTTP RPC 30s 内未就绪，日志: $LOG_DIR/op-geth.log"
  exit 1
fi
echo "  op-geth HTTP RPC 就绪"

# ---------- [健康检查 2/2] op-node 将要连接的 Engine 端点 ----------
# 探测目标必须是 L2_ENGINE_URL —— 即 run-op-node.sh 拼进 --l2= 的那个地址。
# 默认是 op-geth 的 authrpc；若指向中间件代理（engine-api-proxy），探的就是代理。
# 上面那条 8645 的检查替代不了这一条：代理没起来时 op-geth 的公开 RPC 照样通，
# 而 op-node 会连不上 Engine。这里显式 export，保证探测地址与 op-node 实际用的
# 地址是同一个值，不会各自默认导致漂移。
export L2_ENGINE_URL="${L2_ENGINE_URL:-http://localhost:$OP_GETH_AUTHRPC_PORT}"
echo "Waiting for L2 engine endpoint at $L2_ENGINE_URL ..."
# 判活标准是「有没有 HTTP 应答」，不是「是不是 200」：Engine 端点带 JWT 鉴权，
# 不带凭据时它的正确行为就是拒绝（geth 的 authrpc 回 401），这恰恰证明进程活着且
# 鉴权生效。只有完全连不上（连接被拒/超时，curl 写不出状态码即 000）才算没起来。
engine_ready=0
engine_code=""
for i in $(seq 1 30); do
  engine_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
    -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L2_ENGINE_URL" 2>/dev/null) || engine_code="000"
  case "$engine_code" in
    000|"") : ;;                  # 连不上，继续等
    *)      engine_ready=1; break ;;   # 收到任何 HTTP 应答即视为存活
  esac
  sleep 1
done
if [ "$engine_ready" != "1" ]; then
  echo "Error: Engine 端点 $L2_ENGINE_URL 30s 内无任何 HTTP 应答。"
  echo "  若 L2_ENGINE_URL 指向中间件代理，请确认代理已先于本脚本启动。"
  echo "  op-geth 日志: $LOG_DIR/op-geth.log"
  exit 1
fi
echo "  engine endpoint 就绪 (HTTP $engine_code；401 = JWT 鉴权生效且进程存活)"
sleep 2

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

echo ""
echo "=== All services started ==="
echo "  L2 RPC:      $L2_RPC_URL"
echo "  Rollup RPC:  $OP_NODE_RPC_URL"
echo "  L2 Engine:   $L2_ENGINE_URL  (op-node --l2)"
echo "  PIDs:        $PID_DIR/*.pid"
echo "  Logs:        $LOG_DIR/*.log"
echo ""
echo "Stop all: bash scripts/chain-stop.sh"
