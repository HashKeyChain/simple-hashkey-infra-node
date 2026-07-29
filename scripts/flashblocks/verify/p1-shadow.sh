#!/bin/bash
#
# P1 验证 —— op-rbuilder 影子同步一致性
#
# 对应 doc/flashblocks_local_impl.md §7 P1 门：
#   「op-rbuilder 追平链头；关键块 blockHash / stateRoot 与 op-geth 一致；无 invalid block」
#
# 检查项：
#   1. op-geth / op-rbuilder 双方可达
#   2. 两侧链头高度差 <= --lag
#   3. 采样区块的 blockHash 完全一致（创世 + 均匀采样 + 链头附近；hash 已覆盖 stateRoot）
#   4. op-rbuilder 日志无 invalid block / bad block
#   5. 两侧同步推进（观测窗口内高度都在涨，且始终不脱节）
#
# 用法: bash scripts/flashblocks/verify/p1-shadow.sh [--lag=N] [--samples=N] [--watch=SEC]
#   --lag=N      允许的链头高度差，默认 2（出块中两边采样有先后，不要求严格相等）
#   --samples=N  均匀采样的区块数，默认 6（另外固定加测创世和链头附近 4 块）
#   --watch=SEC  观测同步推进的秒数，默认 8；设 0 跳过

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

LAG=2; SAMPLES=6; WATCH=8
for arg in "$@"; do
  case "$arg" in
    --lag=*)     LAG="${arg#*=}" ;;
    --samples=*) SAMPLES="${arg#*=}" ;;
    --watch=*)   WATCH="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p1-shadow.sh [--lag=N] [--samples=N] [--watch=SEC]" >&2
       exit 1 ;;
  esac
done

banner "P1 · op-rbuilder 影子同步一致性"
info "op-geth     = ${L2_RPC}"
info "op-rbuilder = ${RB_RPC}"
info "参数: lag<=${LAG}  采样${SAMPLES}个  观测${WATCH}s"

# ---------- 可达性 ----------
section "节点可达性"
gbn=$(rpc_bn "$L2_RPC"); rbn=$(rpc_bn "$RB_RPC")
if [ "$gbn" -lt 0 ]; then
  fail "op-geth 不可达 (${L2_RPC})"
  summary; exit 1
fi
pass "op-geth 可达，head=${gbn}"
if [ "$rbn" -lt 0 ]; then
  fail "op-rbuilder 不可达 (${RB_RPC}) —— P1 无法验证"
  summary; exit 1
fi
pass "op-rbuilder 可达，head=${rbn}"

# ---------- 追平 ----------
section "链头追平"
diff=$((gbn - rbn)); [ "$diff" -lt 0 ] && diff=$((-diff))
info "op-geth head=${gbn}   op-rbuilder head=${rbn}   |Δ|=${diff}"
assert_num_le "$diff" "$LAG" "两侧链头高度差在容忍范围内"

# op-rbuilder 卡死是这个拓扑的典型故障：rollup-boost 只喂当前头部、不回填历史，
# 而 op-rbuilder 通常没有 P2P peer，一旦停机产生缺口就永久停滞。
if [ "$diff" -gt "$LAG" ]; then
  detail "若差值持续不收敛，多半是 op-rbuilder 曾被单独重启过、缺口无人回填；"
  detail "处理办法见 doc/chain-lifecycle.md 常见故障表（需走一遍 off → switch 让 builder op-node 补齐）。"
fi

# ---------- 区块指纹对照 ----------
section "区块 blockHash 对照"
top=$rbn; [ "$gbn" -lt "$top" ] && top=$gbn   # 只比双方都有的高度

nums="0"
if [ "$SAMPLES" -gt 0 ] && [ "$top" -gt 1 ]; then
  step=$((top / (SAMPLES + 1)))
  [ "$step" -lt 1 ] && step=1
  i=1
  while [ "$i" -le "$SAMPLES" ]; do
    n=$((step * i))
    [ "$n" -ge 1 ] && [ "$n" -lt "$top" ] && nums="$nums $n"
    i=$((i + 1))
  done
fi
for off in 10 3 1 0; do
  n=$((top - off))
  [ "$n" -ge 1 ] && nums="$nums $n"
done
nums=$(echo "$nums" | tr ' ' '\n' | sort -n -u | tr '\n' ' ')

# 只比 blockHash：它是整个块头的哈希，stateRoot 是块头字段之一，已经被覆盖。
# 只有对不上时才多取一次 stateRoot，用来区分「执行结果不同」和「只是块头字段不同」。
mismatch=0; checked=0
for n in $nums; do
  a=$(block_hash "$L2_RPC" "$n")
  b=$(block_hash "$RB_RPC" "$n")
  checked=$((checked + 1))
  if [ -z "$a" ] || [ -z "$b" ]; then
    warn "block ${n} 取不到 blockHash  geth=[${a}] rbuilder=[${b}]"
  elif [ "$a" = "$b" ]; then
    detail "block ${n}  ✓  ${a}"
  else
    mismatch=$((mismatch + 1))
    fail "block ${n} blockHash 不一致"
    detail "geth     hash=${a}  stateRoot=$(block_state_root "$L2_RPC" "$n")"
    detail "rbuilder hash=${b}  stateRoot=$(block_state_root "$RB_RPC" "$n")"
  fi
done
info "对照 ${checked} 个区块（含创世），不一致 ${mismatch} 个"
assert_eq 0 "$mismatch" "所有采样区块的 blockHash 一致"

# ---------- invalid block ----------
section "op-rbuilder 无效块"
inv=$(log_count op-rbuilder 'invalid block|bad block|INVALID|failed to insert')
assert_eq 0 "$inv" "op-rbuilder 日志无 invalid / bad block"

# ---------- 同步推进 ----------
if [ "$WATCH" -gt 0 ]; then
  section "同步推进观测（${WATCH}s）"
  g0=$(rpc_bn "$L2_RPC"); r0=$(rpc_bn "$RB_RPC")
  sleep "$WATCH"
  g1=$(rpc_bn "$L2_RPC"); r1=$(rpc_bn "$RB_RPC")
  info "op-geth     ${g0} → ${g1}  (+$((g1 - g0)))"
  info "op-rbuilder ${r0} → ${r1}  (+$((r1 - r0)))"
  if [ "$g1" -gt "$g0" ]; then pass "op-geth 持续出块"; else fail "op-geth ${WATCH}s 内未出块"; fi
  if [ "$r1" -gt "$r0" ]; then
    pass "op-rbuilder 跟随推进"
  else
    fail "op-rbuilder ${WATCH}s 内高度未变 —— 疑似卡死（缺口无人回填）"
  fi
  d1=$((g1 - r1)); [ "$d1" -lt 0 ] && d1=$((-d1))
  assert_num_le "$d1" "$LAG" "观测结束时仍未脱节"
fi

summary
