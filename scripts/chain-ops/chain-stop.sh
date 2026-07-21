#!/bin/bash
#
# 停止由 chain-start.sh 启动的所有服务（op-challenger、op-proposer、op-batcher、op-node、op-geth）。
# 若为本地环境且 anvil 由本仓库脚本启动，可手动停止: docker stop anvil-chain
#
# 用法: bash scripts/chain-stop.sh
#

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
PID_DIR="${BASE_PATH}/data/pids"
DATA_DIR="${BASE_PATH}/data"
OP_GETH_DATA_PATH="${DATA_DIR}/op-geth"
OP_NODE_SAFEDB_PATH="${DATA_DIR}/op-node/safedb"
OP_CHALLENGER_DATA_PATH="${DATA_DIR}/op-challenger"
OP_BATCHER_PORT="${OP_BATCHER_PORT:-9645}"
OP_NODE_RPC_URL="${OP_NODE_RPC_URL:-http://localhost:9545}"
OP_PROPOSER_PORT="${OP_PROPOSER_PORT:-8560}"

stop_pid() {
  local name="$1"
  local pid="$2"

  [ -z "$pid" ] && return
  if ! kill -0 "$pid" 2>/dev/null; then
    return
  fi

  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Stopped $name (pid $pid)"
      return
    fi
    sleep 0.2
  done

  echo "Force stopping $name (pid $pid)"
  kill -9 "$pid" 2>/dev/null || true
}

stop_matching_processes() {
  local name="$1"
  shift

  while read -r pid command; do
    [ -z "$pid" ] && continue
    [ "$pid" = "$$" ] && continue

    local matched=1
    for needle in "$@"; do
      case "$command" in
        *"$needle"*) ;;
        *) matched=0 ;;
      esac
    done

    if [ "$matched" = "1" ]; then
      stop_pid "$name" "$pid"
    fi
  done < <(ps axww -o pid= -o command=)
}

# First stop the processes recorded by the latest chain-start.sh run.
for name in op-challenger op-proposer op-batcher op-node op-geth; do
  pid_file="$PID_DIR/${name}.pid"
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    stop_pid "$name" "$pid"
    rm -f "$pid_file"
  fi
done

# Then stop stale processes from older runs whose PID files may have been overwritten.
# Match by this repository's datadir/safedb paths so Cursor helper processes are not killed.
stop_matching_processes "op-challenger" "op-challenger " "--datadir=$OP_CHALLENGER_DATA_PATH"
stop_matching_processes "op-proposer" "op-proposer " "--rollup-rpc=$OP_NODE_RPC_URL" "--rpc.port=8560"
stop_matching_processes "op-batcher" "op-batcher " "--rollup-rpc=$OP_NODE_RPC_URL" "--rpc.port=$OP_BATCHER_PORT"
stop_matching_processes "op-node" "op-node " "--safedb.path=$OP_NODE_SAFEDB_PATH"
stop_matching_processes "op-geth" "op-geth " "--datadir=$OP_GETH_DATA_PATH"

echo "Done. To stop anvil (if started by chain-setup or chain-start): docker stop anvil-chain"
