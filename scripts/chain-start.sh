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

# local 时：用本机 anvil，且从 config/local 读配置（与 chain-setup local 一致）
if [ "$CHAIN_ENV" = "local" ]; then
  export L1_RPC_URL="http://localhost:8545"
  export L2_RPC_URL="http://localhost:8645"
  export OP_NODE_RPC_URL="http://localhost:9545"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/local"
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
_anvil_ok() {
  curl -sf -X POST -H "Content-Type: application/json" \
    --connect-timeout 1 --max-time 2 \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$L1_RPC_URL" >/dev/null 2>&1
}

if [ "$CHAIN_ENV" = "local" ]; then
  if _anvil_ok; then
    echo "L1 already running at $L1_RPC_URL"
  else
    echo "Starting anvil (native)..."
    ANVIL_LOG="$LOG_DIR/anvil.log"
    nohup anvil --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 --port=8545 \
      --slots-in-an-epoch=1 --block-time ${L1_BLOCK_TIME:-12} >> "$ANVIL_LOG" 2>&1 &
    echo $! > "$PID_DIR/anvil.pid"
    for i in $(seq 1 10); do
      _anvil_ok && break
      sleep 0.5
    done
    if _anvil_ok; then
      echo "Anvil ready."
    else
      echo "Error: anvil not reachable at $L1_RPC_URL after 5s"
      echo "  Check: $ANVIL_LOG"
      exit 1
    fi
  fi

  # 验证 L1 上 SystemConfig 合约是否存在（anvil 重建后合约会丢失）
  L1_SYSTEM_CONFIG=$(jq -r '.l1_system_config_address // empty' "$OP_NODE_ROLLUP_FILE" 2>/dev/null)
  if [ -n "$L1_SYSTEM_CONFIG" ]; then
    SC_CODE=$(curl -sf -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getCode\",\"params\":[\"$L1_SYSTEM_CONFIG\",\"latest\"],\"id\":1}" \
      "$L1_RPC_URL" 2>/dev/null | jq -r '.result // "0x"')
    if [ "$SC_CODE" = "0x" ] || [ -z "$SC_CODE" ]; then
      echo ""
      echo "Error: L1 SystemConfig contract ($L1_SYSTEM_CONFIG) has no code."
      echo "  anvil was likely recreated (container data lost). L1 contracts no longer exist."
      echo "  Must re-deploy: bash scripts/chain-up.sh local"
      echo "  (chain-up will run chain-setup + chain-start automatically)"
      exit 1
    fi
  fi
fi

# ---------- 停掉可能残留的旧进程 ----------
_kill_and_wait() {
  local pid="$1" name="$2"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.25
  done
  echo "  $name (pid $pid) did not exit, sending SIGKILL..."
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.5
}
for name in op-proposer op-batcher op-node op-geth; do
  pid_file="$PID_DIR/${name}.pid"
  if [ -f "$pid_file" ]; then
    old_pid=$(cat "$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "Killing old $name (pid $old_pid) [from pid file]..."
      _kill_and_wait "$old_pid" "$name"
    fi
    rm -f "$pid_file"
  fi
  for orphan in $(pgrep -x "$name" 2>/dev/null); do
    echo "Killing orphan $name (pid $orphan) [by process name]..."
    _kill_and_wait "$orphan" "$name"
  done
done
for port in 8645 8651 30303 9545 8548 8560; do
  for pid in $(lsof -i :$port -t 2>/dev/null); do
    echo "Killing process on port $port (pid $pid)..."
    _kill_and_wait "$pid" "port:$port"
  done
done

# ---------- 清理 rollup.json 中当前 op-node 不支持的字段 ----------
if jq -e '.da_challenge_contract_address' "$OP_NODE_ROLLUP_FILE" >/dev/null 2>&1; then
  echo "Removing unsupported field 'da_challenge_contract_address' from rollup.json..."
  jq 'del(.da_challenge_contract_address)' "$OP_NODE_ROLLUP_FILE" > "${OP_NODE_ROLLUP_FILE}.tmp" \
    && mv "${OP_NODE_ROLLUP_FILE}.tmp" "$OP_NODE_ROLLUP_FILE"
fi

# ---------- 校验 rollup.json 的 L1 genesis hash 是否和实际 L1 一致 ----------
_ROLLUP_L1_NUM=$(jq -r '.genesis.l1.number' "$OP_NODE_ROLLUP_FILE" 2>/dev/null)
_ROLLUP_L1_HASH=$(jq -r '.genesis.l1.hash' "$OP_NODE_ROLLUP_FILE" 2>/dev/null)
if [ -n "$_ROLLUP_L1_NUM" ] && [ "$_ROLLUP_L1_NUM" != "null" ]; then
  _ROLLUP_L1_HEX=$(printf '0x%x' "$_ROLLUP_L1_NUM" 2>/dev/null)
  _ACTUAL_L1_HASH=$(curl -sf -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$_ROLLUP_L1_HEX\",false],\"id\":1}" \
    "$L1_RPC_URL" 2>/dev/null | jq -r '.result.hash // empty')
  if [ -n "$_ACTUAL_L1_HASH" ] && [ "$_ACTUAL_L1_HASH" != "$_ROLLUP_L1_HASH" ]; then
    echo "WARNING: rollup.json L1 genesis hash mismatch!"
    echo "  rollup.json: $_ROLLUP_L1_HASH"
    echo "  actual L1:   $_ACTUAL_L1_HASH"
    echo "  Updating rollup.json to match current L1..."
    jq --arg h "$_ACTUAL_L1_HASH" '.genesis.l1.hash = $h' "$OP_NODE_ROLLUP_FILE" > "${OP_NODE_ROLLUP_FILE}.tmp" \
      && mv "${OP_NODE_ROLLUP_FILE}.tmp" "$OP_NODE_ROLLUP_FILE"
  fi
fi

# ---------- 注入 chain_op_config（op-node v1.11+ 必须）----------
if ! jq -e '.chain_op_config' "$OP_NODE_ROLLUP_FILE" >/dev/null 2>&1; then
  echo "Injecting chain_op_config into rollup.json (required by op-node v1.11+)..."
  jq '. + {
    "chain_op_config": {
      "eip1559Elasticity": 6,
      "eip1559Denominator": 50,
      "eip1559DenominatorCanyon": 250
    }
  }' "$OP_NODE_ROLLUP_FILE" > "${OP_NODE_ROLLUP_FILE}.tmp" \
    && mv "${OP_NODE_ROLLUP_FILE}.tmp" "$OP_NODE_ROLLUP_FILE"
fi

# ---------- JWT（op-geth / op-node 共用）----------
export OP_GETH_DATA_PATH="${DATA_DIR}/op-geth"
mkdir -p "$OP_GETH_DATA_PATH"
JWT_FILE="${OP_GETH_DATA_PATH}/jwt.txt"
if [ ! -f "$JWT_FILE" ]; then
  openssl rand -hex 32 > "$JWT_FILE"
  echo "Generated JWT at $JWT_FILE"
fi

# ---------- op-geth init ----------
if [ "${CLEAN_OP_GETH_DATADIR:-0}" = "1" ] && [ -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "CLEAN_OP_GETH_DATADIR=1, removing old op-geth datadir..."
  rm -rf "$OP_GETH_DATA_PATH/geth" "$OP_GETH_DATA_PATH/history"
fi
if [ ! -d "$OP_GETH_DATA_PATH/geth" ]; then
  echo "Initializing op-geth datadir..."
  op-geth init --state.scheme=hash --datadir="$OP_GETH_DATA_PATH" "$OP_GETH_GENESIS_FILE"
fi

# ---------- 启动 op-geth ----------
echo "Starting op-geth..."
OP_GETH_FLAGS="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash"
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

# ---------- 启动 op-proposer ----------
if [ "${SKIP_PROPOSER:-0}" != "1" ]; then
  echo "Starting op-proposer..."
  if [ "$USE_FAULT_PROOFS" = "true" ]; then
    PROPOSER_L2OO="--game-factory-address=$(jq -r .DisputeGameFactoryProxy "$DEPLOYMENT_OUTFILE") --proposal-interval=${PROPOSAL_INTERVAL:-30s} --game-type=${GAME_TYPE:-0}"
  else
    PROPOSER_L2OO="--l2oo-address=$(jq -r .L2OutputOracleProxy "$DEPLOYMENT_OUTFILE")"
  fi
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
