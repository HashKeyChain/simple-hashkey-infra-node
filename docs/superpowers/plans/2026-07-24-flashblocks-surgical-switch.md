# Flashblocks 外科式切换（surgical switch）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 hsk-superpowers:executing-plans 逐任务执行。步骤用 `- [ ]` 勾选跟踪。

**Goal:** 把正在运行的 `off`（node+geth）Jovian 链，外科式切换到 flashblocks `dry_run`：op-rbuilder 只启动一次、全程不杀，切换动作只做“引擎驱动权交接（builder op-node → rollup-boost）+ 主 op-node 重路由”。

**Architecture:** 三相生命周期 —— OFF（op-geth + op-node 直连）→ SYNC（+op-rbuilder+builder op-node，builder op-node 驱动 op-rbuilder 追同步）→ FLASHBLOCKS（op-geth + op-rbuilder + rollup-boost + op-node 经 rollup-boost，op-rbuilder 改由 rollup-boost 驱动、builder op-node 停）。切换靠 `admin_stopSequencer` 冻结高度做干净交接，全程不动 op-geth/op-rbuilder，只重启主 op-node 改 `--l2` 指向。

**Tech Stack:** bash 编排脚本、OP Stack（op-geth / op-node cgt-jovian v1.16.5）、flashblocks（rollup-boost v0.7.11 / op-rbuilder v0.2.13 / op-reth v1.9.3）、foundry `cast`、direnv `.envrc`。

---

## 关键不变量（Design Invariants）

1. **op-rbuilder 的 Engine（auth RPC = `RBUILDER_AUTHRPC_PORT=8661`）同一时刻只能有一个共识驱动者。**
   - SYNC 相：builder op-node（`--l2=http://localhost:8661`）。
   - FLASHBLOCKS 相：rollup-boost（`--builder-url 127.0.0.1:8661`）。
   - 二者**不可并存** → 切换时必须先停 builder op-node，再由 rollup-boost 接管。
2. **op-rbuilder 全程只起一次、不杀**（surgical 的核心；与 fullrestart 区别）。
3. **op-geth 全程不动**（切换后只是被 rollup-boost 而非 op-node 直接调 Engine）。
4. **`.envrc` FLASHBLOCKS_MODE 必须在起 rollup-boost / 重启 op-node 之前写成 `dry_run`**，因为 `run-rollup-boost.sh` / `run-op-node.sh` 都会 `source .envrc` 后据此决定执行模式 / `--l2` 目标。
5. **失败可回滚**：任一步失败，尽量把已停的 sequencer 恢复、把新起的同步进程停掉，让链退回 off，不留半吊子状态。

## 相位—组件—驱动权对照

| 相位 | 组件 | op-rbuilder 驱动者 | op-node --l2 |
|---|---|---|---|
| OFF | op-geth, op-node | —（无 op-rbuilder） | op-geth :8651 |
| SYNC | +op-rbuilder, +builder op-node | builder op-node | op-geth :8651 |
| FLASHBLOCKS(dry_run) | op-geth, op-rbuilder, rollup-boost, op-node | rollup-boost | rollup-boost :8551 |

## 端口速查（来自 `.envrc`）

- op-geth：L2 RPC 8645，Engine 8651
- op-node：RPC 9545（`--rpc.enable-admin`），CL p2p TCP 9222
- op-rbuilder：authrpc 8661，http 8663，flashblocks-out ws 1111，RLPx 30313
- builder op-node：RPC 9565，CL p2p TCP 9223
- rollup-boost：Engine 8551，flashblocks 广播 1112，debug 5555

## 文件结构

- **Modify**: `scripts/flashblocks/switch-to-flashblocks-dryrun.sh` —— 由 fullrestart 改写为 surgical（核心）。
- **Verify（已在前序改动完成，仅校验）**:
  - `scripts/flashblocks/start-sequencer-side.sh` —— flashblocks 拓扑只起 op-rbuilder + rollup-boost（无 builder op-node）。
  - `scripts/chain-ops/chain-start.sh` —— `mode!=off` 时 source 上者。
  - `scripts/chain-ops/chain-stop.sh` —— 停列表含 op-rbuilder-opnode / op-rbuilder / rollup-boost。
- **Modify**: `doc/flashblocks_local_impl.md` —— 补相位表 + 驱动权交接 + surgical 切换流程。

---

## Task 1: 校验现有 flashblocks 拓扑脚本一致（无 builder op-node 混入）

**Files:**
- Verify: `scripts/flashblocks/start-sequencer-side.sh`
- Verify: `scripts/chain-ops/chain-start.sh:148-150`
- Verify: `scripts/chain-ops/chain-stop.sh`

- [ ] **Step 1: 确认 start-sequencer-side.sh 只起 op-rbuilder + rollup-boost**

Run: `grep -nE 'run-op-rbuilder-opnode|run-op-rbuilder\.sh|run-rollup-boost' scripts/flashblocks/start-sequencer-side.sh`
Expected: 只出现 `run-op-rbuilder.sh` 与 `run-rollup-boost.sh`，**不出现** `run-op-rbuilder-opnode.sh`。

- [ ] **Step 2: 确认 chain-stop 仍能清理 builder op-node 残留**

Run: `grep -n 'op-rbuilder-opnode' scripts/flashblocks/stop-flashblocks.sh`
Expected: 命中（pid 列表 + `--rpc.port=${RBUILDER_OPNODE_PORT}` 匹配）。

## Task 2: 改写 switch-to-flashblocks-dryrun.sh 为 surgical

**Files:**
- Modify: `scripts/flashblocks/switch-to-flashblocks-dryrun.sh`（整文件替换）

- [ ] **Step 1: 写入下述完整脚本内容**（见下方“脚本全文”）

- [ ] **Step 2: 语法检查**

Run: `bash -n scripts/flashblocks/switch-to-flashblocks-dryrun.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: 冒烟——参数解析与预检早退（不实际起链）**

Run: `bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh --lag=abc 2>&1 | head -1`
Expected: 打印 `Error: --lag 必须是非负整数` 并退出（非 0）。

### 脚本全文

```bash
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
#   [1] 预检   [2] 起同步节点(op-rbuilder+builder op-node)  [3] 粗追平
#   [4] admin_stopSequencer 冻结高度H  [5] 精追平到H  [6] 停 builder op-node
#   [7] 写 .envrc dry_run  [8] 起 rollup-boost  [9] 只重启 op-node(改路由)  [10] 验证
#
# 用法:
#   bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC]
# 选项:
#   --lag=N        追平判定阈值（默认 2）  --timeout=SEC 等追平最长秒数（默认 1800）
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
CHAIN_ENV=""; LAG=2; TIMEOUT=1800
for arg in "$@"; do
  case "$arg" in
    local|remote) CHAIN_ENV="$arg" ;;
    --lag=*)      LAG="${arg#*=}" ;;
    --timeout=*)  TIMEOUT="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh [local|remote] [--lag=N] [--timeout=SEC]" >&2
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

echo "============================================"
echo "  Surgical switch off → flashblocks dry_run ($CHAIN_ENV)"
echo "============================================"
echo "  op-geth      = $L2_RPC   (Engine :8651)"
echo "  op-node      = $OPNODE_RPC (admin)"
echo "  op-rbuilder  = $RB_RPC"
echo "  rollup-boost = :${RB_ENGINE_PORT:-8551}"
echo "  lag/timeout  = ${LAG} / ${TIMEOUT}s"
echo ""

# ---------- [1] 预检 ----------
echo "[1] 预检..."
[ "${FLASHBLOCKS_MODE:-off}" = "off" ] || echo "  WARN: 当前 .envrc FLASHBLOCKS_MODE=$FLASHBLOCKS_MODE（预期 off）。"
[ "$(get_bn "$L2_RPC")" -ge 0 ] || { echo "Error: op-geth 不可达（$L2_RPC）。先确认 off 链在跑。" >&2; exit 1; }
if ! cast rpc optimism_syncStatus --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 && ! cast bn --rpc-url "$OPNODE_RPC" >/dev/null 2>&1; then
  echo "Error: op-node 不可达（$OPNODE_RPC）。" >&2; exit 1
fi
[ -x "$BASE_PATH/bin/op-rbuilder" ]  || { echo "Error: 缺 bin/op-rbuilder。先 bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
[ -x "$BASE_PATH/bin/rollup-boost" ] || { echo "Error: 缺 bin/rollup-boost。先 bash scripts/flashblocks/build-flashblocks.sh" >&2; exit 1; }
if ! (exec 3<>"/dev/tcp/127.0.0.1/${SEQ_P2P_TCP_PORT:-9222}") 2>/dev/null; then
  echo "Error: 主 op-node CL p2p 端口 ${SEQ_P2P_TCP_PORT:-9222} 未监听；builder op-node 收不到 unsafe gossip。" >&2
  echo "       先重启一次 off 链让 op-node 带上 p2p：bash $CHAIN_OPS_DIR/chain-stop.sh && bash $CHAIN_OPS_DIR/chain-start.sh $CHAIN_ENV" >&2
  exit 1
fi
exec 3>&- 2>/dev/null || true
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
  echo "  WARN: 未找到 $SEQ_P2P_KEY，builder op-node 退化为纯 L1 派生（只到 safe head）。"
fi
nohup bash "$FB_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder.pid"
echo "  op-rbuilder started (pid $(cat "$PID_DIR/op-rbuilder.pid"))"
sleep 3
nohup bash "$FB_DIR/run-op-rbuilder-opnode.sh" >> "$LOG_DIR/op-rbuilder-opnode.log" 2>&1 &
echo $! > "$PID_DIR/op-rbuilder-opnode.pid"
echo "  builder op-node started (pid $(cat "$PID_DIR/op-rbuilder-opnode.pid"))"
echo ""

# ---------- [3] 粗追平 ----------
echo "[3] 等 op-rbuilder 粗追平 op-geth（|Δ| ≤ $LAG，≤ ${TIMEOUT}s）..."
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
  echo "Error: ${TIMEOUT}s 内未粗追平。回滚：停同步进程，链仍 off。" >&2
  cleanup_sync_nodes
  exit 1
fi
echo "  粗追平 OK。"
echo ""

# ---------- [4] 冻结高度 ----------
echo "[4] admin_stopSequencer 冻结主 op-node 出块..."
STOP_HASH=$(cast rpc admin_stopSequencer --rpc-url "$OPNODE_RPC" 2>/dev/null | tr -d '"')
if [ -z "$STOP_HASH" ]; then
  echo "Error: admin_stopSequencer 失败（op-node 未开 admin 或非 sequencer）。回滚：停同步进程。" >&2
  cleanup_sync_nodes
  exit 1
fi
echo "  已暂停，冻结 head hash=$STOP_HASH"
echo ""

# 回滚：恢复 sequencer + 停同步进程（用于 [5] 失败）
rollback_resume() {
  echo "  回滚：admin_startSequencer 恢复出块..." >&2
  cast rpc admin_startSequencer "$STOP_HASH" --rpc-url "$OPNODE_RPC" >/dev/null 2>&1 || true
  cleanup_sync_nodes
}

# ---------- [5] 精追平到 H ----------
H=$(get_bn "$L2_RPC")
echo "[5] 等 op-rbuilder 精确追到冻结高度 H=$H（≤ 120s）..."
exact=0
for i in $(seq 1 120); do
  r=$(get_bn "$RB_RPC")
  [ "$r" -ge "$H" ] && { exact=1; echo "  op-rbuilder=$r ≥ H=$H，已到位。"; break; }
  [ $(( i % 5 )) -eq 0 ] && echo "  op-rbuilder=$r / H=$H"
  sleep 1
done
if [ "$exact" != 1 ]; then
  echo "Error: 120s 内 op-rbuilder 未追到 H=$H。回滚。" >&2
  rollback_resume
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
python3 - <<'PY'
import re; from pathlib import Path
p=Path(".envrc"); t=p.read_text()
pat=re.compile(r'^export FLASHBLOCKS_MODE=.*$', re.M)
t=pat.sub('export FLASHBLOCKS_MODE=dry_run', t) if pat.search(t) else t.rstrip("\n")+"\nexport FLASHBLOCKS_MODE=dry_run\n"
p.write_text(t); print("  done")
PY
export FLASHBLOCKS_MODE=dry_run
echo ""

# ---------- [8] 起 rollup-boost（接管驱动 op-rbuilder）----------
echo "[8] 起 rollup-boost（dry-run）..."
export _CALLER_OP_GETH_DATA_PATH="$DATA_DIR/op-geth"
export _CALLER_JWT_FILE="$DATA_DIR/op-geth/jwt.txt"
nohup bash "$FB_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
echo $! > "$PID_DIR/rollup-boost.pid"
echo "  rollup-boost started (pid $(cat "$PID_DIR/rollup-boost.pid"))"
sleep 3
echo ""

# ---------- [9] 只重启 op-node（改路由到 rollup-boost）----------
echo "[9] 重启主 op-node（--l2 → rollup-boost :${RB_ENGINE_PORT:-8551}）..."
stop_main_opnode
sleep 2
export _CALLER_OP_NODE_ROLLUP_FILE="$DEPLOYMENT_CONFIG_PATH/rollup.json"
nohup bash "$CHAIN_OPS_DIR/run-op-node.sh" >> "$LOG_DIR/op-node.log" 2>&1 &
echo $! > "$PID_DIR/op-node.pid"
echo "  op-node started (pid $(cat "$PID_DIR/op-node.pid"))"
echo ""

# ---------- [10] 验证 ----------
echo "[10] 验证出块推进..."
b0=$(get_bn "$L2_RPC"); ok=0
for i in $(seq 1 30); do
  sleep 2; b1=$(get_bn "$L2_RPC")
  [ "$b1" -gt "$b0" ] && { ok=1; echo "  出块推进 $b0 → $b1，切换成功。"; break; }
done
[ "$ok" = 1 ] || echo "  WARN: 30 轮未见出块推进；查 $LOG_DIR/op-node.log 与 rollup-boost.log。若 op-node 未自动恢复出块，可 cast rpc admin_startSequencer <hash> --rpc-url $OPNODE_RPC"
echo ""
echo "=== 完成：已切到 dry_run ==="
echo "  builder payload 校验：tail -f $LOG_DIR/rollup-boost.log （应全 VALID）"
echo "  切 enabled：改 .envrc FLASHBLOCKS_MODE=enabled 后 chain-stop && chain-start $CHAIN_ENV"
echo "            （或热切：rollup-boost debug set-execution-mode enabled，连 RB_DEBUG_PORT=${RB_DEBUG_PORT:-5555}）"
```

## Task 3: 文档同步（相位表 + 驱动权交接 + surgical 流程）

**Files:**
- Modify: `doc/flashblocks_local_impl.md`（P1/切换相关段落）

- [ ] **Step 1: 在切换章节补入“相位—驱动权”表与 surgical 十步流程**（内容同本计划“相位—组件—驱动权对照”与脚本 header）。

- [ ] **Step 2: 校验无残留旧描述**

Run: `grep -nE 'fullrestart|全量 chain-stop' doc/flashblocks_local_impl.md`
Expected: 若仍描述 fullrestart 为推荐路径，改为 surgical。

## Task 4: 全量语法与一致性检查

- [ ] **Step 1:** `bash -n` 全过

Run: `for f in scripts/flashblocks/*.sh scripts/chain-ops/chain-start.sh scripts/chain-ops/chain-stop.sh; do bash -n "$f" && echo "OK $f"; done`
Expected: 全 OK。

- [ ] **Step 2:** 确认 op-rbuilder 在 flashblocks 拓扑里不被 builder op-node 与 rollup-boost 同时连

Run: `grep -n '8661\|RBUILDER_AUTHRPC_PORT' scripts/flashblocks/run-op-rbuilder-opnode.sh scripts/flashblocks/run-rollup-boost.sh`
Expected: 两者都连 8661，印证“同一 auth RPC，必须相位互斥”。

---

## 回滚与安全

- 切换任一步失败均有回滚：`[3]` 失败停同步进程；`[5]` 失败 `admin_startSequencer` 恢复出块 + 停同步进程。链退回 off，不留半吊子。
- 纯本地编排，无外部输入、无新网络暴露；`cast rpc admin_*` 仅打本地 op-node。
- 切 enabled 前先在 dry_run 观察 rollup-boost 日志 builder payload 全 VALID。
