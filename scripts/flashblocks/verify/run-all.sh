#!/bin/bash
#
# 按当前链的实际状态，依次跑该跑的验证门，最后汇总。
#
# 会根据 rollup-boost 的执行模式自动选择：
#   未运行 / off  → 只跑 P0（编译产物与配置对齐，不需要 flashblocks 在跑）
#   dry_run       → P0 + P1 + P2（拓扑对账 + 交易覆盖）
#   enabled       → P0 + P1 + P3（P2 的 dry_run 断言在 enabled 下本就不该成立）
#
# 用法: bash scripts/flashblocks/verify/run-all.sh [--skip-txs] [--watch=SEC] [--quick]
#   --skip-txs   跳过 p2-txs.sh（会真的发交易、花 gas）
#   --watch=SEC  传给各阶段的观测窗口，默认 30
#   --quick      等价于 --watch=10 --skip-txs

set -uo pipefail
VERIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$VERIFY_DIR/lib.sh"

SKIP_TXS=0; WATCH=30
for arg in "$@"; do
  case "$arg" in
    --skip-txs) SKIP_TXS=1 ;;
    --watch=*)  WATCH="${arg#*=}" ;;
    --quick)    WATCH=10; SKIP_TXS=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/run-all.sh [--skip-txs] [--watch=SEC] [--quick]" >&2
       exit 1 ;;
  esac
done

banner "Flashblocks 验证总览"
mode=$(boost_mode)
info "rollup-boost 执行模式 = ${mode}"
info ".envrc FLASHBLOCKS_MODE = ${FLASHBLOCKS_MODE:-off}"

STAGES=""
case "$mode" in
  dry_run) STAGES="p0-genesis p1-shadow p2-dryrun"
           [ "$SKIP_TXS" = "0" ] && STAGES="$STAGES p2-txs" ;;
  enabled) STAGES="p0-genesis p1-shadow p3-enabled" ;;
  *)       STAGES="p0-genesis"
           info "flashblocks 未运行，只能验证 P0。启动后重跑本脚本可覆盖 P1/P2/P3。" ;;
esac
info "本次将执行: ${STAGES}"

RESULTS=""; FAILED=0
for s in $STAGES; do
  case "$s" in
    p2-txs)     args="" ;;
    p0-genesis) args="" ;;
    *)          args="--watch=${WATCH}" ;;
  esac
  # shellcheck disable=SC2086
  if bash "$VERIFY_DIR/${s}.sh" $args; then
    RESULTS="${RESULTS}  ${C_GRN}PASS${C_OFF}  ${s}
"
  else
    RESULTS="${RESULTS}  ${C_RED}FAIL${C_OFF}  ${s}
"
    FAILED=$((FAILED + 1))
  fi
done

banner "总览"
printf '%s' "$RESULTS"
if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo "  ${C_RED}${FAILED} 个阶段未通过${C_OFF}，向上翻看对应阶段的 FAIL 明细。"
  exit 1
fi
echo ""
echo "  ${C_GRN}全部阶段通过${C_OFF}"
