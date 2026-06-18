#!/bin/bash
#
# 一键启动所有服务（L1 可选、op-geth、op-node、op-batcher、op-proposer）。
# 需先执行 chain-setup.sh 生成 rollup.json 和 genesis.json。
#
# 用法:
#   bash scripts/chain-start.sh [local|server]
#
# 参数:
#   local  - 本地：若 L1 未运行则启动 anvil，再启动 op-geth / op-node / batcher / proposer
#   server - 服务器：不启动 L1，仅启动 op-geth / op-node / batcher / proposer
#
# 若不传参，根据 L1_RPC_URL 自动判断。
#
# 环境变量（可选）:
#   SKIP_BATCHER=1   - 不启动 op-batcher
#   SKIP_PROPOSER=1  - 不启动 op-proposer
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
    CHAIN_ENV=server
  fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi

if [ "$CHAIN_ENV" != "local" ] && [ "$CHAIN_ENV" != "server" ]; then
  echo "Usage: bash scripts/chain-start.sh [local|server]"
  exit 1
fi

# local 时：用本机 anvil；生成文件目录仍按 .envrc 的 DEPLOYMENT_CONTEXT。
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
  export OP_GETH_GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
  export OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
  export DEPLOYMENT_OUTFILE="$DEPLOYMENT_CONFIG_PATH/artifact.json"
fi

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

# ---------- op-geth init（仅首次）----------
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "Initializing op-geth datadir..."
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$OP_GETH_GENESIS_FILE"
fi

# ---------- 启动 op-geth ----------
echo "Starting op-geth..."
OP_GETH_FLAGS="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash"
# OP_GETH_FLAGS="$OP_GETH_FLAGS --override.fjord=1780653281"
# OP_GETH_FLAGS="$OP_GETH_FLAGS --override.granite=1780653291 --override.holocene=1780653301 --override.isthmus=1780653311 --override.jovian=1780653321"
nohup op-geth $OP_GETH_FLAGS >> "$LOG_DIR/op-geth.log" 2>&1 &
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

# ---------- 启动 op-node ----------
echo "Starting op-node..."
SAFEDB_PATH="${DATA_DIR}/op-node/safedb"
mkdir -p "$(dirname "$SAFEDB_PATH")"
OP_NODE_FLAGS="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=http://localhost:8651 --l2.jwt-secret=$JWT_FILE --sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s --p2p.disable --rpc.enable-admin --p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY --sequencer.l1-confs=5 --verifier.l1-confs=4 --rollup.config=$OP_NODE_ROLLUP_FILE --l1.beacon.ignore --safedb.path=$SAFEDB_PATH"
nohup op-node $OP_NODE_FLAGS >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat $PID_DIR/op-node.pid)), log: $LOG_DIR/op-node.log"

sleep 3

# ---------- 启动 op-batcher（可选）----------
if [ "${SKIP_BATCHER:-0}" != "1" ]; then
  echo "Starting op-batcher..."
  BATCHER_FLAGS="--log.level=debug --l1-eth-rpc=$L1_RPC_URL --l2-eth-rpc=$L2_RPC_URL --rpc.port=$OP_BATCHER_PORT --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_BATCHER_PRIVATE_KEY --max-channel-duration=${MAX_CHANNEL_DURATION:-300} --poll-interval=${POLL_INTERVAL:-6s} --sub-safety-margin=${SUB_SAFETY_MARGIN:-10} --resubmission-timeout=${RESUBMISSION_TIMEOUT:-48s} --max-l1-tx-size-bytes=${MAX_L1_TX_SIZE_BYTES:-1000} --data-availability-type=${OP_BATCHER_DATA_AVAILABILITY_TYPE:-calldata} --txmgr.max-retries=${OP_PROPOSER_TXMGR_MAX_RETRIES:-2} --rpc.enable-admin --network-timeout=600s --num-confirmations=1 --safe-abort-nonce-too-low-count=${SAFE_ABORT_NONCE_TOO_LOW_COUNT:-3}"
  nohup op-batcher $BATCHER_FLAGS >> "$LOG_DIR/op-batcher.log" 2>&1 &
  echo $! > "$PID_DIR/op-batcher.pid"
  echo "  op-batcher started (pid $(cat $PID_DIR/op-batcher.pid)), log: $LOG_DIR/op-batcher.log"
fi

# ---------- 启动 op-proposer（可选；若启用 fault proofs 需先 init anchor state）----------
if [ "${SKIP_PROPOSER:-0}" != "1" ]; then
  if [ "$USE_FAULT_PROOFS" = "true" ]; then
    bash "$SCRIPT_DIR/initialize-anchorState.sh" || true
  fi
  echo "Starting op-proposer..."
  PROPOSER_L2OO="--l2oo-address=$(jq -r .L2OutputOracleProxy $DEPLOYMENT_OUTFILE)"
  [ "$USE_FAULT_PROOFS" = "true" ] && PROPOSER_L2OO="--game-factory-address=$(jq -r .DisputeGameFactoryProxy $DEPLOYMENT_OUTFILE) --proposal-interval=${PROPOSAL_INTERVAL:-30s} --game-type=${GAME_TYPE:-0}"
  PROPOSER_FLAGS="--log.level=debug --rpc.port=8560 --rollup-rpc=$OP_NODE_RPC_URL --private-key=$GS_PROPOSER_PRIVATE_KEY --l1-eth-rpc=$L1_RPC_URL $PROPOSER_L2OO --poll-interval=30s --network-timeout=600s --num-confirmations=1 --wait-node-sync=${WAIT_NODE_SYNC:-true}"
  nohup op-proposer $PROPOSER_FLAGS >> "$LOG_DIR/op-proposer.log" 2>&1 &
  echo $! > "$PID_DIR/op-proposer.pid"
  echo "  op-proposer started (pid $(cat $PID_DIR/op-proposer.pid)), log: $LOG_DIR/op-proposer.log"
fi

echo ""
echo "=== All services started ==="
echo "  L2 RPC:      $L2_RPC_URL"
echo "  Rollup RPC:  $OP_NODE_RPC_URL"
echo "  PIDs:        $PID_DIR/*.pid"
echo "  Logs:        $LOG_DIR/*.log"
echo ""
echo "Stop all: bash scripts/chain-stop.sh"
