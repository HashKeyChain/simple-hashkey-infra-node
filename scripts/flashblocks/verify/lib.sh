#!/bin/bash
#
# Flashblocks 验证脚本公共库。被 verify/ 下各 p*.sh `source` 使用，本身不单独执行。
#
# 这里只有四类东西：环境变量装载、结果输出与断言、cast / rg 的薄封装、wscheck 的构建。
# 唯一的 Go 代码是 wscheck/（WebSocket 握手，shell 做不了），其余一律用现成命令：
# 查链用 cast，数日志用 rg。
#
# 日志计数一律看全量，不做「基线 - 窗口」的增量：验证总是针对新起的链，
# 日志从零开始，全量条数就是这条链的真实情况。若在跑了很久、重启过多次的链上复用
# 这些脚本，历史错误会一直算进来 —— 那种场景下先清 data/logs 再验。
#
# 约定：
#   - 断言失败不中断脚本，继续跑完所有检查，最后由 summary 决定退出码；
#     这样一次运行能看到全部问题，而不是修一个跑一次。
#   - 所有 $VAR 紧跟中文/全角字符处必须写 ${VAR}：bash 3.2 在 UTF-8 locale 下
#     会把全角字符首字节吃进变量名，配合 set -u 直接以 "unbound variable" 退出。

# ---------- 路径与环境 ----------
VERIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$VERIFY_DIR/../../.." && pwd)
cd "$REPO_ROOT"
# .envrc 里有未定义即引用的变量，装载时先关掉 set -u
set +u
# shellcheck disable=SC1091
source .envrc >/dev/null 2>&1
set -u

# .envrc 里是 `export BASE_PATH=$PWD`，会把上面算好的值覆盖成「当前目录」。
# 正常调用时两者相同，但若在别的目录里 source 过 .envrc，错值会经 export 传进来。
# 这里一律用自己按脚本位置算出的仓库根，不信任环境里的 BASE_PATH。
BASE_PATH="$REPO_ROOT"

DATA_DIR="$BASE_PATH/data"
LOG_DIR="$DATA_DIR/logs"
CFG_DIR="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/${DEPLOYMENT_CONTEXT:-local-mainnet}}"

# 各组件对外地址（端口一律取 .envrc，避免脚本内硬编码漂移）
L1_RPC="${L1_RPC_URL:-http://localhost:8545}"
L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
RB_RPC="http://localhost:${RBUILDER_HTTP_PORT:-8663}"
OPNODE_RPC="${OP_NODE_RPC_URL:-http://localhost:9545}"
RB_DEBUG="http://localhost:${RB_DEBUG_PORT:-5555}"
FB_RPC="http://localhost:${FB_RPC_HTTP_PORT:-8745}"
JWT_FILE="${OP_GETH_DATA_PATH:-$DATA_DIR/op-geth}/jwt.txt"

# 日志目录找不到时必须立刻停。否则 log_count 对每个不存在的文件都返回 0，
# 「路径错了」和「一条都没有」就变成同样的结果，所有计数类检查会集体假 PASS。
if [ ! -d "$LOG_DIR" ]; then
  echo "FATAL: 日志目录不存在: $LOG_DIR" >&2
  echo "       仓库根被解析为: $BASE_PATH" >&2
  echo "       链没启动过，或脚本被移出了 scripts/flashblocks/verify/。" >&2
  exit 1
fi

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

PASS_N=0; FAIL_N=0; WARN_N=0; SKIP_N=0
FAILED_ITEMS=""

banner() {
  echo ""
  echo "${C_BLU}============================================================${C_OFF}"
  echo "${C_BLU}  $*${C_OFF}"
  echo "${C_BLU}============================================================${C_OFF}"
}

section() { echo ""; echo "${C_BLU}── $* ──${C_OFF}"; }
info()    { echo "   $*"; }
detail()  { echo "${C_DIM}     $*${C_OFF}"; }

pass() { PASS_N=$((PASS_N+1)); echo "  ${C_GRN}PASS${C_OFF}  $*"; }
warn() { WARN_N=$((WARN_N+1)); echo "  ${C_YEL}WARN${C_OFF}  $*"; }
skip() { SKIP_N=$((SKIP_N+1)); echo "  ${C_DIM}SKIP${C_OFF}  $*"; }
fail() {
  FAIL_N=$((FAIL_N+1))
  echo "  ${C_RED}FAIL${C_OFF}  $*"
  FAILED_ITEMS="${FAILED_ITEMS}
    - $*"
}

# assert_eq <期望> <实际> <描述>
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3  ($2)"; else fail "$3  期望=[$1] 实际=[$2]"; fi
}

# assert_ne <不应等于> <实际> <描述>
assert_ne() {
  if [ "$1" != "$2" ]; then pass "$3  ($2)"; else fail "$3  不应等于 [$1]"; fi
}

# assert_num_le <实际> <上限> <描述>
assert_num_le() {
  if [ "$1" -le "$2" ] 2>/dev/null; then pass "$3  ($1 <= $2)"; else fail "$3  ($1 > $2)"; fi
}

# assert_num_ge <实际> <下限> <描述>
assert_num_ge() {
  if [ "$1" -ge "$2" ] 2>/dev/null; then pass "$3  ($1 >= $2)"; else fail "$3  ($1 < $2)"; fi
}

summary() {
  echo ""
  echo "${C_BLU}------------------------------------------------------------${C_OFF}"
  printf "  结果: ${C_GRN}PASS=%d${C_OFF}  ${C_RED}FAIL=%d${C_OFF}  ${C_YEL}WARN=%d${C_OFF}  ${C_DIM}SKIP=%d${C_OFF}\n" \
    "$PASS_N" "$FAIL_N" "$WARN_N" "$SKIP_N"
  if [ "$FAIL_N" -gt 0 ]; then
    echo "  ${C_RED}未通过项:${C_OFF}${FAILED_ITEMS}"
    echo "${C_BLU}------------------------------------------------------------${C_OFF}"
    return 1
  fi
  echo "${C_BLU}------------------------------------------------------------${C_OFF}"
  return 0
}

require_cmd() {
  local missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -n "$missing" ]; then
    echo "${C_RED}Error${C_OFF}: 缺少命令:${missing}" >&2
    return 1
  fi
}

# ---------- 链查询（全部走 cast）----------
# 块高；不可达或返回非数字时输出 -1，便于调用方用整数比较
rpc_bn() {
  local n; n=$(cast bn --rpc-url "$1" 2>/dev/null || echo "")
  case "$n" in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac
}

rpc_alive() { [ "$(rpc_bn "$1")" -ge 0 ]; }

# 某块的 blockHash；取不到输出空串。
# 只比 hash 就够断定两条链在该高度完全一致 —— stateRoot 是块头字段，已被 hash 覆盖。
# 不一致时再调 block_state_root 拿 stateRoot 来区分「执行结果不同」和「只是块头不同」。
block_hash()       { cast block "$2" -f hash      --rpc-url "$1" 2>/dev/null; }
block_state_root() { cast block "$2" -f stateRoot --rpc-url "$1" 2>/dev/null; }

# jsonrpc <url> <method> [params-json]
jsonrpc() {
  local url="$1" method="$2" params="${3:-[]}"
  curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" "$url" 2>/dev/null
}

# rollup-boost 当前执行模式；未运行时输出 none
boost_mode() {
  local r; r=$(jsonrpc "$RB_DEBUG" debug_getExecutionMode)
  [ -z "$r" ] && { echo none; return; }
  echo "$r" | rg -o '"execution_mode":"([a-z_]+)"' -r '$1'
}

# 热切执行模式，无需重启任何组件。<enabled|dry_run|disabled>
# 输出切换后的实际模式，便于调用方确认。
set_boost_mode() {
  jsonrpc "$RB_DEBUG" debug_setExecutionMode "[{\"execution_mode\":\"$1\"}]" >/dev/null
  sleep 1
  boost_mode
}

# ---------- 日志 ----------
# reth / rollup-boost 的日志带 ANSI 颜色码，统计前必须剥掉
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null; }

# log_count <日志名(不含.log)> <正则>  —— 全量匹配条数，日志不存在输出 0
log_count() {
  local f="$LOG_DIR/$1.log"
  [ -f "$f" ] || { echo 0; return; }
  strip_ansi "$f" | rg -c "$2" 2>/dev/null || echo 0
}

# ---------- wscheck（唯一的 Go 代码：WebSocket 握手 shell 做不到）----------
WSCHECK="$VERIFY_DIR/bin/wscheck"

# 源码比二进制新就重建。零外部依赖，build 一两秒，
# 不值得让使用者多记一个「先编译」的步骤。
if [ ! -x "$WSCHECK" ] || [ -n "$(find "$VERIFY_DIR/wscheck" -name '*.go' -newer "$WSCHECK" 2>/dev/null)" ]; then
  if command -v go >/dev/null 2>&1; then
    echo "构建 wscheck ..." >&2
    (cd "$VERIFY_DIR/wscheck" && go build -o "$WSCHECK" .) || echo "WARN: wscheck 构建失败，广播流检查会被跳过" >&2
  else
    echo "WARN: 没有 Go 工具链，无法构建 wscheck，广播流检查会被跳过" >&2
  fi
fi
