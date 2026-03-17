#!/bin/bash
#
# 停止由 chain-start.sh 启动的所有服务（op-geth、op-node、op-batcher、op-proposer）。
# 若为本地环境且 anvil 由本仓库脚本启动，可手动停止: docker stop anvil-chain
#
# 用法: bash scripts/chain-stop.sh
#

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
PID_DIR="${BASE_PATH}/data/pids"

for name in op-proposer op-batcher op-node op-geth; do
  pid_file="$PID_DIR/${name}.pid"
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "Stopped $name (pid $pid)"
    fi
    rm -f "$pid_file"
  fi
done

echo "Done. To stop anvil (if started by chain-setup or chain-start): docker stop anvil-chain"
