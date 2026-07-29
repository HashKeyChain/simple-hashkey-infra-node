#!/bin/bash
#
# P3 验证 —— enabled 模式：builder 块真正落链，且 builder 故障时能优雅降级
#
# 对应 doc/flashblocks_local_impl.md §7 P3 门：
#   「builder 块用于 canonical 链；flashblock 持续产出；op-rbuilder 故障时回退 op-geth」
#
# 判定依据：
#   rollup-boost 每次 getPayload 都会打一行
#     returning block hash=… number=… context=<l2|builder> payload_id=0x…
#   context 就是最终上链的 payload 来源（上游集成测试也用这行判定）。
#   enabled 下应绝大多数为 builder；降级时自动变回 l2 且不断块。
#
# 用法: bash scripts/flashblocks/verify/p3-enabled.sh [--switch] [--watch=SEC] [--fallback-drill]
#   --switch          当前不是 enabled 时自动切过去，验证完切回原模式（带 trap 保证异常也会切回）
#   --watch=SEC       观测秒数，默认 30
#   --fallback-drill  【破坏性，默认关闭】主动把 rollup-boost 切到 disabled 制造故障
#
# 降级能力默认怎么验证（无破坏）：
#   builder 偶发取 payload 失败是常态（日志里的 "error getting payload from builder"）。
#   rollup-boost 遇到这种情况会自动改用 l2 payload。所以只要翻既有日志，
#   核对每一次 builder 失败是否都对应一个 context=l2 的 returning block，
#   就能证明回退链路有效 —— 不需要人为制造故障。
#
# 为什么 --fallback-drill 是破坏性的（实测结论，勿轻用）：
#   disabled 模式下 rollup-boost 停止向 builder 发送**所有**请求，包括 FCU 和 newPayload，
#   op-rbuilder 因此完全脱离链。而它在本拓扑里没有 P2P 回填，
#   恢复 enabled 后拿不到中间缺失的区块，链头会永久卡在演练开始的高度，
#   表现为 rollup-boost 持续报 "Unknown payload"、builder 块再也无法落链。
#   实测：12 秒的 disabled 演练就让 op-rbuilder 落后 30+ 块且无法自愈。
#   唯一的恢复办法是走一遍完整的 off → switch-to-flashblocks-dryrun.sh，
#   靠临时的 builder op-node 通过 CL P2P 把缺口补齐。

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

DO_SWITCH=0; WATCH=30; DRILL=0
for arg in "$@"; do
  case "$arg" in
    --switch)         DO_SWITCH=1 ;;
    --watch=*)        WATCH="${arg#*=}" ;;
    --fallback-drill) DRILL=1 ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p3-enabled.sh [--switch] [--watch=SEC] [--fallback-drill]" >&2
       exit 1 ;;
  esac
done

banner "P3 · enabled 模式与降级能力"

# 脚本可能中途退出（断言失败以外的原因，比如 Ctrl-C）。若是我们自己切过模式，
# 必须切回去，否则会把链留在跟进来时不一样的状态。
ORIG_MODE=""; RESTORE=0
on_exit() {
  [ "$RESTORE" = "1" ] || return 0
  [ -n "$ORIG_MODE" ] || return 0
  local now; now=$(boost_mode)
  [ "$now" = "$ORIG_MODE" ] && return 0
  echo ""
  echo "  ${C_YEL}恢复原执行模式: ${now} → ${ORIG_MODE}${C_OFF}"
  set_boost_mode "$ORIG_MODE" >/dev/null
  echo "  当前模式: $(boost_mode)"
}
trap on_exit EXIT INT TERM

# ---------- 模式准备 ----------
section "执行模式"
mode=$(boost_mode)
if [ "$mode" = "none" ]; then
  fail "rollup-boost debug 端口 (${RB_DEBUG}) 无响应 —— rollup-boost 没在跑"
  summary; exit 1
fi
info "当前模式 = ${mode}"
ORIG_MODE="$mode"

if [ "$mode" = "enabled" ]; then
  pass "已处于 enabled 模式"
elif [ "$DO_SWITCH" = "1" ]; then
  info "按 --switch 热切到 enabled（结束后会自动切回 ${ORIG_MODE}）"
  RESTORE=1
  mode=$(set_boost_mode enabled)
  assert_eq "enabled" "$mode" "已热切到 enabled"
  [ "$mode" != "enabled" ] && { summary; exit 1; }
  sleep 5   # 给 op-node 几个块的时间走完一轮 FCU → getPayload
else
  fail "当前是 ${mode}，不是 enabled。加 --switch 可自动切换并在结束后切回"
  summary; exit 1
fi

# ---------- 观测 ----------
# 出块和 payload 来源要看「这段窗口内」的情况：日志是整条链累计的，
# 里面还躺着切到 enabled 之前 dry_run 阶段的几万条 context=l2。
# 所以这三项在观测前后各数一次，相减。其余检查看全量即可。
section "观测 ${WATCH}s"
before_builder=$(log_count rollup-boost 'returning block.*context=builder')
before_l2=$(     log_count rollup-boost 'returning block.*context=l2')
before_fb=$(     log_count op-rbuilder  'Flashblock built')
g0=$(rpc_bn "$L2_RPC")

sleep "$WATCH"

builder=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))
l2=$((      $(log_count rollup-boost 'returning block.*context=l2')      - before_l2 ))
fb=$((      $(log_count op-rbuilder  'Flashblock built')                 - before_fb ))
g1=$(rpc_bn "$L2_RPC")
blocks=$((g1 - g0))

# ---------- builder 块落链 ----------
section "builder 块是否用于 canonical 链"
total=$((builder + l2))
info "窗口内 returning block: context=builder ${builder} 次，context=l2 ${l2} 次"
info "op-geth ${g0} → ${g1}（${blocks} 块 / ${WATCH}s）"
if [ "$total" -le 0 ]; then
  fail "窗口内没有任何 payload 产出"
else
  ratio=$((builder * 100 / total))
  if [ "$ratio" -ge 90 ]; then
    pass "builder 块占比 ${ratio}%（${builder}/${total}）—— flashblocks 已真正生效"
  elif [ "$ratio" -gt 0 ]; then
    warn "builder 块占比仅 ${ratio}%（${builder}/${total}）—— 有相当比例回退到了 op-geth"
    detail "回退通常来自 builder 超时或 getPayload 失败，检查 op-rbuilder 负载与日志。"
  else
    fail "没有任何 builder 块落链 —— enabled 没有实际生效"
  fi
fi
assert_num_ge "$blocks" 1 "链持续出块"

# ---------- flashblocks ----------
section "flashblocks 产出"
per=$(( ${L2_BLOCK_TIME:-2} * 1000 / ${FB_INTERVAL_MS:-250} ))
if [ "$blocks" -gt 0 ]; then
  avg=$((fb / blocks))
  info "建成 flashblock ${fb} 个 / ${blocks} 块，平均每块 ${avg} 个（预期 ${per}）"
  assert_num_ge "$avg" $((per - per / 4)) "flashblock 持续产出且片数达标"
else
  skip "窗口内没出块，无法评估 flashblocks"
fi

# ---------- flashblocks 对外广播 ----------
section "flashblocks 对外广播 (:${RB_FLASHBLOCKS_WS_PORT:-1112})"
# enabled 下这个流是用户侧预确认的数据源：rollup-boost 把 builder 的片转发到这里，
# 经 flashblocks-websocket-proxy 分发给 op-reth。所以要验的不是「端口开着」，
# 而是握手能升级成 WebSocket 且真有数据流出 —— 这是唯一 shell 做不了的检查，
# 交给 wscheck（verify/wscheck/main.go）。
if [ ! -x "$WSCHECK" ]; then
  skip "wscheck 未构建（需要 Go 工具链），跳过广播流检查"
else
  ok=0; status=0; frames=0; bytes=0; slices=0; covered_blocks=0; error=""
  eval "$("$WSCHECK" --port="${RB_FLASHBLOCKS_WS_PORT:-1112}" --timeout=6 2>/dev/null)"
  if [ "$ok" != "1" ]; then
    fail "flashblocks 广播端口不可用（${error:-未握手成功}，HTTP 状态 ${status}）"
  elif [ "$bytes" -gt 0 ]; then
    pass "WebSocket 握手成功，收到 ${slices} 个分片 / ${bytes} 字节，覆盖 ${covered_blocks} 个块"
  else
    fail "WebSocket 握手成功但 6s 内无数据 —— builder 没在产出分片"
  fi
fi

# ---------- 错误 ----------
# 这里看全量：验证针对新起的链，日志里任何一条这类错误都值得看一眼。
section "错误（全链累计）"
check_errors() {
  local n; n=$(log_count "$1" "$2")
  if [ "$n" -eq 0 ]; then pass "$3 0 条"; else warn "$3 ${n} 条 —— 查 data/logs/${1}.log"; fi
}
check_errors rollup-boost 'error getting payload from builder' "rollup-boost 取 builder payload 失败"
check_errors rollup-boost 'Invalid index for flashblock'       "Invalid index for flashblock"
check_errors rollup-boost 'Payload ID mismatch'                "Payload ID mismatch"
check_errors op-geth      'Invalid block|bad block|Failed to insert' "op-geth invalid / bad block"
check_errors op-node      '\bERROR\b|lvl=eror|lvl=crit'        "op-node ERROR"

# ---------- 降级能力（默认：翻既有日志，无破坏）----------
section "降级能力：builder 失败时是否自动回退 op-geth"
# 失败行和出块行带同一个 payload_id，取交集就知道那次失败最终用了谁的块。
# 注意失败行的 payload_id 在前缀 span 里（get_payload_v4{… payload_id=0x…}: … error …），
# 在关键词之后是取不到的，所以先按关键词筛行、再从整行提 id。
RB_LOG="$LOG_DIR/rollup-boost.log"
if [ ! -f "$RB_LOG" ]; then
  skip "读不到 rollup-boost 日志，无法核对降级历史"
else
  failed_ids=$(strip_ansi "$RB_LOG" | rg 'error getting payload from builder' \
    | rg -o 'payload_id=(0x[0-9a-f]+)' -r '$1' | sort -u)
  nf=$(echo "$failed_ids" | rg -c '.' || echo 0)
  info "builder 取 payload 失败 ${nf} 次（按 payload_id 去重）"
  if [ "$nf" -eq 0 ]; then
    skip "至今未发生过 builder 失败，无既有数据可核对降级链路"
    detail "如需主动演练，用 --fallback-drill（破坏性，见脚本头部说明）。"
  else
    fell_back=$(comm -12 <(echo "$failed_ids") \
      <(strip_ansi "$RB_LOG" | rg -o 'context=l2 payload_id=(0x[0-9a-f]+)'      -r '$1' | sort -u) | rg -c '.' || echo 0)
    still_builder=$(comm -12 <(echo "$failed_ids") \
      <(strip_ansi "$RB_LOG" | rg -o 'context=builder payload_id=(0x[0-9a-f]+)' -r '$1' | sort -u) | rg -c '.' || echo 0)
    detail "其中 ${fell_back} 次回退到了 op-geth，${still_builder} 次仍用了 builder"
    assert_eq 0 "$still_builder" "没有任何一次 builder 失败被错误地当作成功"
    assert_num_ge "$fell_back" 1 "builder 失败时自动回退 op-geth，链未中断"
  fi
fi

# ---------- 主动降级演练（破坏性，需显式开启）----------
if [ "$DRILL" = "1" ]; then
  section "主动降级演练（破坏性）"
  warn "disabled 会让 op-rbuilder 彻底脱链且无法自愈，演练后必须重建 builder 同步"
  detail "恢复办法：bash scripts/flashblocks/stop-flashblocks.sh 后重跑"
  detail "          bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh"
  RESTORE=1

  d0=$(rpc_bn "$L2_RPC")
  before_l2=$(     log_count rollup-boost 'returning block.*context=l2')
  before_builder=$(log_count rollup-boost 'returning block.*context=builder')
  m=$(set_boost_mode disabled)
  assert_eq "disabled" "$m" "已切到 disabled（模拟 builder 不可用）"
  sleep 12
  d1=$(rpc_bn "$L2_RPC")
  drill_l2=$((      $(log_count rollup-boost 'returning block.*context=l2')      - before_l2 ))
  drill_builder=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))

  info "降级期间出块 ${d0} → ${d1}（+$((d1 - d0))）"
  assert_num_ge "$((d1 - d0))" 1 "builder 不可用时链仍在出块（已回退 op-geth）"
  info "降级期间 context=l2 ${drill_l2} 次，context=builder ${drill_builder} 次"
  assert_eq 0 "$drill_builder" "降级期间不再采用 builder 块"

  m=$(set_boost_mode enabled)
  assert_eq "enabled" "$m" "已恢复 enabled"
  sleep 8
  before_builder=$(log_count rollup-boost 'returning block.*context=builder')
  sleep 10
  back=$(( $(log_count rollup-boost 'returning block.*context=builder') - before_builder ))

  gnow=$(rpc_bn "$L2_RPC"); rnow=$(rpc_bn "$RB_RPC")
  info "恢复后窗口内 context=builder ${back} 次；op-geth=${gnow}  op-rbuilder=${rnow}"
  if [ "$back" -ge 1 ]; then
    pass "builder 块重新落链，本次演练未造成掉队"
  else
    fail "builder 未恢复出块，op-rbuilder 落后 $((gnow - rnow)) 块 —— 已脱链，无法自愈"
    detail "这是 disabled 演练的预期代价：期间 op-rbuilder 收不到 FCU/newPayload，"
    detail "缺失的区块没有任何来源可以回填。必须重建 builder 同步："
    detail "  bash scripts/flashblocks/stop-flashblocks.sh"
    detail "  bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh"
  fi
fi

summary
