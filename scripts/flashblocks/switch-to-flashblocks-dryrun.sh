#!/bin/bash
#
# 一键：把正在跑的 node+geth(off) 链，外科式切换到 flashblocks dry_run。
# 核心：op-rbuilder 只起一次、全程不杀；切换只做“引擎驱动权交接 + op-node 重路由”。
#
# 相位与 op-rbuilder 引擎驱动权：
#   OFF        : op-geth + op-node(直连 geth :8651)
#   SYNC       : + op-rbuilder + builder op-node（builder op-node 驱动 op-rbuilder 追同步）
#   FLASHBLOCKS: op-geth + op-rbuilder + rollup-boost + op-node(经 rollup-boost :8551)
#                op-rbuilder 改由 rollup-boost 驱动；builder op-node 停（否则抢同一 auth RPC）
#
# 流程：
#   [1] 预检（含 op-node 重启安全性：链需跑过 Holocene 边界 + 一个 channel_timeout）
#   [2] 起同步节点(op-rbuilder+builder op-node)  [3] 粗追平
#   [4] admin_stopSequencer 冻结高度H  [5] 精追平到H  [6] 停 builder op-node
#   [7] 写 .envrc dry_run  [8] 起 rollup-boost  [9] 只重启 op-node(改路由)  [10] 验证
#
# 用法:
#   bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC] [--no-wait]
# 选项:
#   --lag=N        追平判定阈值（默认 2）
#   --timeout=SEC  等追平 / 等 op-node 重启安全窗口的最长秒数（默认 1800）
#   --no-wait      重启安全窗口未到时直接失败退出，不等待（默认会轮询等待）
#
# 前提：Rust 组件已编译到 bin/（bash scripts/flashblocks/build-flashblocks.sh），链当前 off 在跑。
#
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"
source .envrc

FB_DIR="$BASE_PATH/scripts/flashblocks"
CHAIN_OPS_DIR="$BASE_PATH/scripts/chain-ops"
DATA_DIR="$BASE_PATH/data"
LOG_DIR="$DATA_DIR/logs"
PID_DIR="$DATA_DIR/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# ---------- 参数 ----------
CHAIN_ENV=""; LAG=2; TIMEOUT=1800; NO_WAIT=0
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --lag=*)      LAG="${arg#*=}" ;;
    --timeout=*)  TIMEOUT="${arg#*=}" ;;
    --no-wait)    NO_WAIT=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC] [--no-wait]" >&2
       exit 1 ;;
  esac
done
case "$LAG" in ''|*[!0-9]*) echo "Error: --lag 必须是非负整数" >&2; exit 1 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) echo "Error: --timeout 必须是非负整数" >&2; exit 1 ;; esac
if [ -z "$CHAIN_ENV" ]; then
  if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then CHAIN_ENV=local; else CHAIN_ENV=remote; fi
  echo "Auto-detected CHAIN_ENV=$CHAIN_ENV"
fi
[ "$CHAIN_ENV" = "local" ] && export L1_RPC_URL="http://localhost:8545"

L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
RB_RPC="http://localhost:${RBUILDER_HTTP_PORT:-8663}"
OPNODE_RPC="${OP_NODE_RPC_URL:-http://localhost:9545}"
SEQ_P2P_KEY="$DATA_DIR/op-node/p2p_priv.txt"

get_bn() { local n; n=$(cast bn --rpc-url "$1" 2>/dev/null || echo ""); case "$n" in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac; }

# 二分查出第一个 timestamp >= $1 的 L1 块号（搜索区间 [$2, $3]）；区间内不存在则返回 1。
l1_first_block_at_or_after() {
  local target="$1" lo="$2" hi="$3" mid ts ans=""
  ts=$(cast block "$hi" -f timestamp --rpc-url "$L1_RPC_URL" 2>/dev/null)
  case "$ts" in ''|*[!0-9]*) return 1 ;; esac
  [ "$ts" -ge "$target" ] || return 1
  while [ "$lo" -le "$hi" ]; do
    mid=$(( (lo + hi) / 2 ))
    ts=$(cast block "$mid" -f timestamp --rpc-url "$L1_RPC_URL" 2>/dev/null)
    case "$ts" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$ts" -ge "$target" ]; then ans="$mid"; hi=$(( mid - 1 )); else lo=$(( mid + 1 )); fi
  done
  [ -n "$ans" ] || return 1
  echo "$ans"
}

# 第 [9] 步要重启主 op-node。op-node 启动时派生流水线会把 L1 读取起点回退一个
# channel_timeout（Granite 后 50 个 L1 块，之前 300），回退撞到 L1 创世就停在创世。
# 若落点早于 Holocene 激活块，BatchMux 会装上 pre-Holocene 的 BatchQueue，而重放旧
# batch 时校验函数按“batch 所在 L1 块已过 Holocene”返回 BatchPast——BatchQueue 不认识
# 这个值，直接 crit 退出，且每次重启都会复现。链太年轻时必然踩中，这里提前拦下。
#
# 探测一次，往 stdout 打一行结果，用返回码区分：
#   0  ok    <safe_origin> <bound> <ct>          已满足，可以切换
#   1  wait  <safe_origin> <bound> <ct> <need>   条件未到，safe head 再往前走就会满足
#   1  retry <原因>                               这一轮读不到数据，重试即可
#   2  skip  <原因>                               无需/无法判定，直接放行
probe_opnode_restart_safe() {
  local rollup_json="$DEPLOYMENT_CONFIG_PATH/rollup.json"
  [ -f "$rollup_json" ] || { echo "skip 找不到 $rollup_json"; return 2; }

  local holocene_t granite_t
  holocene_t=$(jq -r '.holocene_time // empty' "$rollup_json" 2>/dev/null)
  granite_t=$(jq -r '.granite_time // empty' "$rollup_json" 2>/dev/null)
  # 未激活 / 创世激活：L1 创世块本身就在 Holocene 之后，回退到底也安全
  case "$holocene_t" in ''|null|0) echo "skip holocene 未激活或创世激活"; return 2 ;; esac

  local genesis_l1
  genesis_l1=$(jq -r '.genesis.l1.number' "$rollup_json" 2>/dev/null)
  case "$genesis_l1" in ''|null|*[!0-9]*) echo "skip 读不到 genesis.l1.number"; return 2 ;; esac

  local safe_origin l1_head
  safe_origin=$(cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" 2>/dev/null | jq -r '.safe_l2.l1origin.number // empty')
  case "$safe_origin" in ''|null|*[!0-9]*) echo "retry 读不到 safe_l2 的 L1 origin"; return 1 ;; esac
  l1_head=$(get_bn "$L1_RPC_URL")
  [ "$l1_head" -ge 0 ] || { echo "retry 读不到 L1 高度"; return 1; }

  # 回退落点必须晚于 Holocene 边界；Granite 也已激活时 channel_timeout 才是 50，
  # 因此落点同时要晚于 Granite 边界，否则回退途中超时值会变回 300、退得更远。
  local bound ct=300 hol_blk gra_blk
  hol_blk=$(l1_first_block_at_or_after "$holocene_t" "$genesis_l1" "$l1_head") \
    || { echo "retry L1 上还没有时间戳 >= holocene_time($holocene_t) 的区块"; return 1; }
  bound="$hol_blk"
  if [ -n "$granite_t" ] && [ "$granite_t" != null ] && [ "$granite_t" != 0 ]; then
    if gra_blk=$(l1_first_block_at_or_after "$granite_t" "$genesis_l1" "$l1_head"); then
      [ "$gra_blk" -gt "$bound" ] && bound="$gra_blk"
      ct=50
    fi
  fi

  if [ $(( safe_origin - ct )) -lt "$bound" ]; then
    echo "wait $safe_origin $bound $ct $(( bound + ct ))"; return 1
  fi
  echo "ok $safe_origin $bound $ct"; return 0
}

# 默认轮询等到条件满足（上限 ${TIMEOUT}）；--no-wait 时只判定一次，不满足即退出。
# 注意：本文件里凡是 $VAR 紧跟中文/全角字符的地方都必须写成 ${VAR} —— bash 3.2 在 UTF-8
# locale 下会把全角字符的首字节吃进变量名，配合 set -u 就是一句 "unbound variable" 后直接退出。
check_opnode_restart_safe() {
  local deadline=$(( $(date +%s) + TIMEOUT )) announced=0 out st
  while :; do
    out=$(probe_opnode_restart_safe); st=$?
    # 函数内的 set -- 只影响本函数的位置参数，不会污染脚本
    set -- $out
    case "$st" in
      2) echo "  op-node 重启安全性：跳过检查（${*:2}）"; return 0 ;;
      0) echo "  op-node 重启安全性：safe_origin=$2  channel_timeout=$4  回退落点=$(( $2 - $4 ))  需 >= $3"; return 0 ;;
    esac

    local detail secs=""
    if [ "$1" = "wait" ]; then
      secs=$(( ($5 - $2) * ${L1_BLOCK_TIME:-12} ))
      detail="safe_origin=$2 需追到 $5（回退落点 $(( $2 - $4 )) < 边界 $3），约还需 ${secs}s"
    else
      detail="${*:2}"
    fi

    if [ "$NO_WAIT" = 1 ]; then
      echo "Error: 现在切换会让第 [9] 步重启的 op-node 崩溃（derivation crit: unknown batch validity type: 4）。" >&2
      echo "       $detail" >&2
      echo "       去掉 --no-wait 可让脚本自动等到条件满足；若 safe head 长期不前进，先查 op-batcher 是否在提交。" >&2
      return 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Error: 等待 op-node 重启安全窗口超过 ${TIMEOUT}s 仍未满足：$detail" >&2
      echo "       safe head 可能没在前进，检查 op-batcher 是否在提交（data/logs/op-batcher.log）。" >&2
      return 1
    fi
    if [ "$announced" = 0 ]; then
      echo "  op-node 重启安全性：条件未到，等待中（上限 ${TIMEOUT}s，--no-wait 可改为直接失败）"
      announced=1
    fi
    echo "    $detail"
    sleep 10
  done
}

# 按 pid 文件停单个组件（存在才停）
stop_pidfile() {
  local name="$1" f="$PID_DIR/$1.pid" pid
  [ -f "$f" ] || return 0
  pid=$(cat "$f" 2>/dev/null)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  rm -f "$f"
}
# 按命令行特征停残留（不误杀 Cursor 辅助进程）
stop_match() {
  local needle1="$1" needle2="$2" pid command
  while read -r pid command; do
    [ -z "$pid" ] && continue
    case "$command" in *"$needle1"*) : ;; *) continue ;; esac
    case "$command" in *"$needle2"*) : ;; *) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done < <(ps axww -o pid= -o command=)
}
stop_builder_opnode() { stop_pidfile op-rbuilder-opnode; stop_match "op-node " "--rpc.port=${RBUILDER_OPNODE_PORT:-9565}"; }
stop_main_opnode()    { stop_pidfile op-node;            stop_match "op-node " "--safedb.path=$DATA_DIR/op-node/safedb"; }

# 起同步进程失败时的清理（把本脚本起的 op-rbuilder + builder op-node 停掉，链退回 off）
cleanup_sync_nodes() {
  stop_builder_opnode
  stop_pidfile op-rbuilder; stop_match "op-rbuilder " "$DATA_DIR/op-rbuilder"
}
stop_rollup_boost() { stop_pidfile rollup-boost; stop_match "rollup-boost " "--rpc-port ${RB_ENGINE_PORT:-8551}"; }

# ---------- 中断保护 ----------
# 本脚本从 [2] 起就在动链上拓扑：起同步进程、冻结出块、改 .envrc。中途被打断（Ctrl-C、
# 信号、意外退出）而不清理的话，会留下"同步进程还在跑 + sequencer 冻结 + rollup-boost 缺席"
# 的半吊子状态，且外部看不出任何异常。用 EXIT trap 兜底：按已推进到的阶段逐层回滚。
# PHASE: 0=尚未动任何东西 1=已起同步进程 2=已冻结出块 3=已交接引擎+起 rollup-boost
PHASE=0
STOP_HASH=""
SWITCH_DONE=0

set_envrc_mode() {
  _FB_MODE="$1" python3 - <<'PY'
import os, re
from pathlib import Path
mode = os.environ["_FB_MODE"]
p = Path(".envrc"); t = p.read_text()
pat = re.compile(r'^export FLASHBLOCKS_MODE=.*$', re.M)
repl = f'export FLASHBLOCKS_MODE={mode}'
p.write_text(pat.sub(repl, t) if pat.search(t) else t.rstrip("\n") + "\n" + repl + "\n")
PY
}

on_exit() {
  local rc=$?
  { [ "$SWITCH_DONE" = 1 ] || [ "$PHASE" = 0 ]; } && return 0
  echo "" >&2
  echo "!! 切换未完成就退出（exit=${rc}，已推进到 PHASE=${PHASE}），开始回滚..." >&2
  if [ "$PHASE" -ge 3 ]; then
    echo "   停 rollup-boost、把 .envrc 写回 FLASHBLOCKS_MODE=off" >&2
    stop_rollup_boost
    set_envrc_mode off
  fi
  if [ "$PHASE" -ge 2 ]; then
    echo "   admin_startSequencer 恢复出块" >&2
    [ -n "$STOP_HASH" ] && cast rpc admin_startSequencer "$STOP_HASH" --rpc-url "$OPNODE_RPC" >/dev/null 2>&1
  fi
  echo "   停同步进程（op-rbuilder + builder op-node）" >&2
  cleanup_sync_nodes
  echo "!! 已回滚，链退回 off。确认出块恢复后可重跑本脚本。" >&2
}
trap on_exit EXIT
trap 'echo "" >&2; echo "!! 收到中断信号（Ctrl-C / SIGTERM）" >&2; exit 130' INT TERM

echo "============================================"
echo "  Surgical switch off → flashblocks dry_run ($CHAIN_ENV)"
echo "============================================"
echo "  op-geth      = $L2_RPC   (Engine :${OP_GETH_AUTHRPC_PORT:-8651})"
echo "  op-node      = $OPNODE_RPC (admin)"
echo "  op-rbuilder  = $RB_RPC"
echo "  rollup-boost = :${RB_ENGINE_PORT:-8551}"
echo "  lag/timeout  = ${LAG} / ${TIMEOUT}s"
echo ""

# ---------- [1] 预检 ----------
echo "[1] 预检..."

# 幂等保护：链可能已经在 dry_run/enabled 拓扑下跑（上次切换成功，或 chain-start.sh 直接以
# FLASHBLOCKS_MODE=dry_run 起的全套）。此时再切一次只会起重复的 op-rbuilder 并让 builder
# op-node 与 rollup-boost 抢 Engine 控制权，必须提前挡住。
if mode=$(curl -s --max-time 3 -X POST -H 'Content-Type: application/json' \
      --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
      "http://localhost:${RB_DEBUG_PORT:-5555}" 2>/dev/null) && [ -n "$mode" ]; then
  cur=$(printf '%s' "$mode" | sed -n 's/.*"execution_mode":"\([a-z_]*\)".*/\1/p')
  echo "  检测到 rollup-boost 已在运行，execution_mode=${cur:-未知}"
  echo "  这条链已经处于 flashblocks 拓扑，无需再次切换。"
  echo ""
  echo "  确认出块：    cast bn --rpc-url $L2_RPC ; cast bn --rpc-url $RB_RPC"
  echo "  回到 off：    bash $CHAIN_OPS_DIR/chain-stop.sh，把 .envrc 的 FLASHBLOCKS_MODE 改回 off，再 chain-start.sh"
  if [ "${cur:-}" = "dry_run" ]; then
    echo "  想升到 enabled：curl -s -X POST -H 'Content-Type: application/json' \\"
    echo "                   --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_setExecutionMode\",\"params\":[{\"execution_mode\":\"enabled\"}]}' \\"
    echo "                   http://localhost:${RB_DEBUG_PORT:-5555}"
  fi
  SWITCH_DONE=1   # 抑制 EXIT trap 的回滚逻辑：什么都没动，无需回滚
  exit 0
fi

[ "${FLASHBLOCKS_MODE:-off}" = "off" ] || echo "  WARN: 当前 .envrc FLASHBLOCKS_MODE=${FLASHBLOCKS_MODE}（预期 off）。"
[ "$(get_bn "$L2_RPC")" -ge 0 ] || { echo "Error: op-geth 不可达（${L2_RPC}）。先确认 off 链在跑。" >&2; exit 1; }
if ! cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 && ! cast bn --rpc-url "$OPNODE_RPC" >/dev/null 2>&1; then
  echo "Error: op-node 不可达（${OPNODE_RPC}）。" >&2; exit 1
fi
[ -x "$BASE_PATH/bin/op-rbuilder" ]  || { echo "Error: 缺 bin/op-rbuilder。先 bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
[ -x "$BASE_PATH/bin/rollup-boost" ] || { echo "Error: 缺 bin/rollup-boost。先 bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
if ! (exec 3<>"/dev/tcp/127.0.0.1/${SEQ_P2P_TCP_PORT:-9222}") 2>/dev/null; then
  echo "Error: 主 op-node CL p2p 端口 ${SEQ_P2P_TCP_PORT:-9222} 未监听；builder op-node 收不到 unsafe gossip。" >&2
  echo "       先重启一次 off 链让 op-node 带上 p2p：bash $CHAIN_OPS_DIR/chain-stop.sh && bash $CHAIN_OPS_DIR/chain-start.sh $CHAIN_ENV" >&2
  exit 1
fi
exec 3>&- 2>/dev/null || true
check_opnode_restart_safe || exit 1
echo "  OK。"
echo ""

# ---------- [2] 起同步节点 ----------
echo "[2] 起同步节点：op-rbuilder + builder op-node..."
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
export _CALLER_OP_GETH_GENESIS_FILE="$DEPLOYMENT_CONFIG_PATH/genesis.json"
if [ -f "$SEQ_P2P_KEY" ]; then
  SEQ_PEER_ID=$(op-node p2p priv2id < "$SEQ_P2P_KEY" | tail -1)
  export _CALLER_SEQ_P2P_MULTIADDR="/ip4/127.0.0.1/tcp/${SEQ_P2P_TCP_PORT:-9222}/p2p/${SEQ_PEER_ID}"
  echo "  sequencer 静态多址: $_CALLER_SEQ_P2P_MULTIADDR"
else
  echo "  WARN: 未找到 ${SEQ_P2P_KEY}，builder op-node 退化为纯 L1 派生（只到 safe head）。"
fi
PHASE=1   # 从这里起，异常退出必须清理同步进程（见 on_exit）
nohup bash "$FB_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder.pid"
echo "  op-rbuilder started (pid $(cat "$PID_DIR/op-rbuilder.pid"))"
sleep 3
nohup bash "$FB_DIR/run-op-rbuilder-opnode.sh" >> "$LOG_DIR/op-rbuilder-opnode.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder-opnode.pid"
echo "  builder op-node started (pid $(cat "$PID_DIR/op-rbuilder-opnode.pid"))"
echo ""

# ---------- [3] 粗追平 ----------
echo "[3] 等 op-rbuilder 粗追平 op-geth（|Δ| ≤ ${LAG}，≤ ${TIMEOUT}s）..."
caught=0
for i in $(seq 1 "$TIMEOUT"); do
  g=$(get_bn "$L2_RPC"); r=$(get_bn "$RB_RPC")
  if [ "$r" -ge 0 ] && [ "$g" -ge 0 ] && [ "$r" -gt 0 ]; then
    d=$(( g - r )); [ "$d" -lt 0 ] && d=$(( -d ))
    { [ $(( i % 5 )) -eq 0 ] || [ "$d" -le "$LAG" ]; } && echo "  op-geth=$g op-rbuilder=$r Δ=$d"
    [ "$d" -le "$LAG" ] && { caught=1; break; }
  else
    [ $(( i % 5 )) -eq 0 ] && echo "  等 op-rbuilder RPC 就绪... (op-rbuilder=$r)"
  fi
  sleep 1
done
if [ "$caught" != 1 ]; then
  echo "Error: ${TIMEOUT}s 内未粗追平（op-rbuilder 起不来或同步卡住，查 $LOG_DIR/op-rbuilder.log）。" >&2
  exit 1
fi
echo "  粗追平 OK。"
echo ""

# ---------- [4] 冻结高度 ----------
echo "[4] admin_stopSequencer 冻结主 op-node 出块..."
STOP_HASH=$(cast rpc admin_stopSequencer --rpc-url "$OPNODE_RPC" 2>/dev/null | tr -d '"')
if [ -z "$STOP_HASH" ]; then
  echo "Error: admin_stopSequencer 失败（op-node 未开 admin 或非 sequencer）。" >&2
  exit 1
fi
PHASE=2   # 出块已冻结，异常退出必须 admin_startSequencer 恢复
echo "  已暂停，冻结 head hash=$STOP_HASH"
echo ""

# ---------- [5] 精追平到 H ----------
H=$(get_bn "$L2_RPC")
echo "[5] 等 op-rbuilder 精确追到冻结高度 H=${H}（≤ 120s）..."
exact=0
for i in $(seq 1 120); do
  r=$(get_bn "$RB_RPC")
  [ "$r" -ge "$H" ] && { exact=1; echo "  op-rbuilder=$r ≥ H=${H}，已到位。"; break; }
  [ $(( i % 5 )) -eq 0 ] && echo "  op-rbuilder=$r / H=$H"
  sleep 1
done
if [ "$exact" != 1 ]; then
  echo "Error: 120s 内 op-rbuilder 未追到冻结高度 H=${H}。" >&2
  exit 1
fi
echo ""

# ---------- [6] 停 builder op-node（放开 op-rbuilder 引擎）----------
echo "[6] 停 builder op-node（交出 op-rbuilder 引擎驱动权）..."
stop_builder_opnode
sleep 2
echo ""

# ---------- [7] 写 .envrc dry_run ----------
echo "[7] 写 .envrc：FLASHBLOCKS_MODE=dry_run"
PHASE=3   # 从这里起，异常退出还要停 rollup-boost 并把 .envrc 写回 off
set_envrc_mode dry_run
export FLASHBLOCKS_MODE=dry_run
echo "  done"
echo ""

# ---------- [8] 起 rollup-boost（接管驱动 op-rbuilder）----------
echo "[8] 起 rollup-boost（dry-run）..."
export _CALLER_OP_GETH_DATA_PATH="$DATA_DIR/op-geth"
export _CALLER_JWT_FILE="$DATA_DIR/op-geth/jwt.txt"
nohup bash "$FB_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
echo $! > "$PID_DIR/rollup-boost.pid"
echo "  rollup-boost started (pid $(cat "$PID_DIR/rollup-boost.pid"))"
sleep 3
if ! curl -s -m 3 -X POST -H 'Content-Type: application/json' \
     --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
     "http://localhost:${RB_DEBUG_PORT:-5555}" >/dev/null 2>&1; then
  echo "Error: rollup-boost 起来后 debug 端口 ${RB_DEBUG_PORT:-5555} 无响应，可能已崩溃。查 $LOG_DIR/rollup-boost.log" >&2
  exit 1
fi
echo ""

# ---------- [9] 只重启 op-node（改路由到 rollup-boost）----------
echo "[9] 重启主 op-node（--l2 → rollup-boost :${RB_ENGINE_PORT:-8551}）..."
stop_main_opnode
sleep 2
export _CALLER_OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
nohup bash "$CHAIN_OPS_DIR/run-op-node.sh" >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat "$PID_DIR/op-node.pid"))"
# 拓扑已完成切换，后续只剩验证；此时回滚反而会把好不容易切好的链推回去
SWITCH_DONE=1
echo ""

# ---------- [10] 验证 ----------
echo "[10] 验证出块推进..."
b0=$(get_bn "$L2_RPC"); ok=0
for i in $(seq 1 30); do
  sleep 2; b1=$(get_bn "$L2_RPC")
  [ "$b1" -gt "$b0" ] && { ok=1; echo "  出块推进 $b0 → ${b1}，切换成功。"; break; }
done
[ "$ok" = 1 ] || echo "  WARN: 30 轮未见出块推进；查 $LOG_DIR/op-node.log 与 rollup-boost.log。若 op-node 未自动恢复出块，可 cast rpc admin_startSequencer <hash> --rpc-url $OPNODE_RPC"
echo ""
echo "=== 完成：已切到 dry_run ==="
echo "  builder payload 校验：tail -f $LOG_DIR/rollup-boost.log （应全 VALID）"
echo "  切 enabled：改 .envrc FLASHBLOCKS_MODE=enabled 后 chain-stop && chain-start $CHAIN_ENV"
echo "            （或热切，不断链、但不会拉起用户面组件："
echo "             curl -s -X POST -H 'Content-Type: application/json' \\"
echo "               --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"debug_setExecutionMode\",\"params\":[{\"execution_mode\":\"enabled\"}]}' \\"
echo "               http://localhost:${RB_DEBUG_PORT:-5555} ）"
