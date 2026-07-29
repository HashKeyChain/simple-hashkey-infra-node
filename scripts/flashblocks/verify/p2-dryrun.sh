#!/bin/bash
#
# P2 验证 —— dry_run 下 builder 块是否有效
#
# 对应 doc/flashblocks_local_impl.md §7 P2 门。只查六件事，每件都能独立抓到真问题：
#
#   1. rollup-boost 处于 dry_run              前提，不成立则后面全部无意义
#   2. op-node 的 Engine 指向 rollup-boost     否则压根没有 builder 参与，第 5 项的 0 是假的
#   3. builder op-node 已停                    它会和 rollup-boost 抢 op-rbuilder 的 auth RPC
#   4. 出块速度没受影响                        P2 门原文要求「出块不受影响」
#   5. builder 块没有被判 INVALID              ★ 硬门槛，P2 真正要证明的事
#   6. builder 确实在交付候选块                 防第 5 项的 0 是「零样本」而非「零缺陷」
#
# 第 5 项怎么验：op-geth 收到候选块后独立重放其中全部交易、自己复算 stateRoot /
#   receiptsRoot / gasUsed，与块头声称的值对不上就返回 INVALID；rollup-boost 的
#   client/rpc.rs 见到 INVALID 转成 Err，冒到 server.rs 打出
#     error getting payload from builder error=InvalidPayload(...)
#   所以数日志里的 InvalidPayload 即可，一条没有 = builder 造的块全部有效。
#   这比「builder 块和 op-geth 块相同」更强：op-geth 是独立重算的，且不要求两边输入相同。
#
# 刻意不查的东西（不是漏了）：
#   · builder 块与 op-geth 块是否相同 —— builder 有自己的排序和分片策略，enabled 后本就该
#     造出不同的块。要看差异分布读 rollup-boost 的 Prometheus 指标
#     （block_building_gas_delta / block_building_tx_count_delta，端口见 RB_METRICS_PORT）。
#   · 分片配置是否正确 —— 一次性静态检查，在 p0-genesis.sh。
#   · flashblocks 片数与预确认流质量 —— dry_run 阶段这个流没有消费者，在 p3-enabled.sh。
#   · safe head / batcher / proposer 是否健康 —— 与 Flashblocks 无关，属基础链健康，
#     在 p1-shadow.sh 和日常监控。
#
# 日志怎么数：验证针对新起的链，所以「有没有出过错」直接看全量条数 —— 这条链从
#   创世到现在一次 InvalidPayload 都不该有。只有交付率要和窗口内的出块数相比，
#   那两项才在观测前后各数一次相减。
#
# 用法: bash scripts/flashblocks/verify/p2-dryrun.sh [--watch=SEC]
#   --watch=SEC  观测窗口秒数，默认 30（约 15 个 L2 块）

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WATCH=30
for arg in "$@"; do
  case "$arg" in
    --watch=*) WATCH="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p2-dryrun.sh [--watch=SEC]" >&2
       exit 1 ;;
  esac
done

banner "P2 · dry_run 下 builder 块有效性"

# ---------- [1] 前提：执行模式 ----------
section "[1] rollup-boost 执行模式"
mode=$(boost_mode)
if [ "$mode" = "none" ]; then
  fail "rollup-boost debug 端口 (${RB_DEBUG}) 无响应 —— 没在跑，P2 无从谈起"
  summary; exit 1
fi
assert_eq "dry_run" "$mode" "执行模式为 dry_run"
[ "$mode" = "enabled" ] && detail "当前是 enabled，请改跑 p3-enabled.sh"

# ---------- [2][3] 拓扑 ----------
section "[2][3] Engine 驱动权归属"
# 枚举所有 op-node，按各自 --l2 指向分类。
# 必须用 pgrep -x 按进程名精确匹配：`ps | rg op-node` 会匹配到 rg 自己的命令行。
main_l2=""; builder_pids=""
for pid in $(pgrep -x op-node 2>/dev/null); do
  l2=$(ps -o args= -p "$pid" 2>/dev/null | rg -o '\-\-l2=([^ ]+)' -r '$1' | head -1)
  case "$l2" in
    *":${RBUILDER_AUTHRPC_PORT:-8661}"*) builder_pids="$builder_pids $pid" ;;
    *":${FB_RPC_AUTHRPC_PORT:-8751}"*)   ;;   # verifier op-node，enabled 才有，与 P2 无关
    *) main_l2="$l2" ;;
  esac
done

if [ -z "$main_l2" ]; then
  fail "找不到主 op-node（sequencer）进程"
elif echo "$main_l2" | rg -q ":${RB_ENGINE_PORT:-8551}"; then
  pass "op-node 已路由到 rollup-boost (:${RB_ENGINE_PORT:-8551})"
else
  fail "op-node 仍直连 op-geth (${main_l2}) —— 切换没生效，builder 压根没参与出块"
fi

# builder op-node 必须已停：它和 rollup-boost 会抢 op-rbuilder 的同一个 auth RPC。
# 注意 data/logs/op-rbuilder-opnode.log 里有内容不代表它还活着 —— 那是切换过程中
# 临时同步节点留下的历史日志，判断在不在跑要看进程，不是看日志。
if [ -n "$builder_pids" ]; then
  fail "builder op-node 仍在运行 (PID${builder_pids}) —— 会与 rollup-boost 争抢引擎驱动权"
else
  pass "builder op-node 已停止（引擎驱动权独归 rollup-boost）"
fi

# ---------- 观测 ----------
section "观测 ${WATCH}s"
# log_count <日志名> <正则> 就是 `rg -c`（先剥掉 ANSI 颜色码），定义在 lib.sh。
# 交付次数要和窗口内的出块次数相比才有意义，所以这两项前后各数一次相减。
before_delivered=$(log_count rollup-boost 'get_payload_v[0-9]\{.*:new_payload_v[0-9]\{.*target="l2"')
before_nodeliver=$(log_count rollup-boost 'error getting payload from builder')
g0=$(rpc_bn "$L2_RPC")
t0=$(date +%s)

sleep "$WATCH"

delivered=$(( $(log_count rollup-boost 'get_payload_v[0-9]\{.*:new_payload_v[0-9]\{.*target="l2"') - before_delivered ))
nodeliver=$(( $(log_count rollup-boost 'error getting payload from builder') - before_nodeliver ))
g1=$(rpc_bn "$L2_RPC"); r1=$(rpc_bn "$RB_RPC")
elapsed=$(( $(date +%s) - t0 ))
blocks=$((g1 - g0))

# 这两项看全链累计：dry_run 下一次都不该发生，出现过就是问题，不必只盯着窗口。
invalid=$(log_count rollup-boost 'InvalidPayload')
adopted=$(log_count rollup-boost 'returning block.*context=builder')

# ---------- [4] 出块 ----------
section "[4] 出块速度未受影响"
info "op-geth ${g0} → ${g1}   (${blocks} 块 / ${elapsed}s)"
expected=$(( elapsed / ${L2_BLOCK_TIME:-2} ))
assert_num_ge "$blocks" "$(( expected - expected / 4 - 1 ))" \
  "出块数达到预期（约 ${expected} 块，L2_BLOCK_TIME=${L2_BLOCK_TIME:-2}s）"

# dry_run 的安全语义：builder payload 只做比对、绝不上链。
# rollup-boost 每次 getPayload 都会打一行 "returning block ... context=<l2|builder>"，
# context 就是最终交给 op-node 上链的 payload 来源；dry_run 下必须一次 builder 都没有。
assert_eq 0 "$adopted" "没有任何 builder payload 被采纳上链（dry_run 语义）"
if [ "$adopted" -gt 0 ]; then
  detail "这是全链累计数。若这条链曾切到过 enabled，数到的是那段历史，"
  detail "不代表现在的 dry_run 有问题 —— 清掉 data/logs 重新起链再验最省事。"
fi

# ---------- [5] 有效性：硬门槛 ----------
section "[5] builder 块有效性 ★ 硬门槛"
#
# 边界（别误读这个 0）：Engine API 的状态有 VALID / INVALID / SYNCING / ACCEPTED 四种，
# 而 rollup-boost 只在 INVALID 时转 Err 留痕（client/rpc.rs 的 is_invalid()，
# alloy 里定义为 matches!(self, Invalid{..})），SYNCING 和 ACCEPTED 都当成功放过。
# 所以这条 grep 为 0 的准确含义是「没有被判定为无效」，不是「已被验证通过」——
# 中间还有一种「op-geth 压根没验成」（候选块父块未知时会返回 SYNCING）。
# 那种情况几乎都源于 builder 脱链，会先被第 6 项的交付率和块高差抓到，属间接覆盖。
#
detail "op-geth 独立重放 builder 块并复算状态根；判 INVALID 会在日志留下 InvalidPayload。"
assert_eq 0 "$invalid" "没有任何 builder 块被 op-geth 判为 INVALID"
if [ "$invalid" -gt 0 ]; then
  detail "按漏斗定位：blockHash → stateRoot/receiptsRoot/gasUsed → 具体交易。"
  detail "见 doc/flashblocks_local_impl.md §8.4。"
fi

# ---------- [6] 交付率：防零样本 ----------
section "[6] builder 交付率（防「零样本」假 PASS）"
# 上面的 INVALID=0 也可能只是因为 builder 压根没交付过块 —— 零样本不等于零缺陷。
# dry_run 下缺失无害（反正用 op-geth 的块），enabled 后每次缺失都是一次降级回退：
# 链是安全的，只是那个块没有 flashblocks。
info "交付候选块 ${delivered} 次 / 出块 ${blocks} 次；未交付 ${nodeliver} 次"
if [ "$blocks" -le 0 ]; then
  fail "窗口内没有出块，无法评估"
elif [ "$delivered" -lt $((blocks / 2)) ]; then
  fail "交付率仅 ${delivered}/${blocks} —— 上面的 INVALID=0 是零样本，不能说明任何问题"
  # builder 脱链是最常见的原因，而 rollup-boost 日志里看不出来，只能比块高。
  lag=$((g1 - r1)); [ "$lag" -lt 0 ] && lag=$((-lag))
  if [ "$lag" -gt 2 ]; then
    detail "根因：op-rbuilder 落后 ${lag} 块（op-geth ${g1} / op-rbuilder ${r1}）。"
    detail "op-rbuilder 没有 P2P，rollup-boost 也不补历史块，只能走完整重建："
    detail "chain-stop → FLASHBLOCKS_MODE=off → chain-start → switch-to-flashblocks-dryrun.sh"
  else
    detail "op-rbuilder 块高正常（落后 ${lag} 块），查 data/logs/op-rbuilder.log 的报错。"
  fi
else
  rate=$((delivered * 100 / blocks))
  if [ "$rate" -ge 95 ]; then
    pass "交付率 ${rate}%（${delivered}/${blocks}）—— 第 5 项的结论有足够样本支撑"
  else
    warn "交付率 ${rate}%（${delivered}/${blocks}）—— enabled 后这部分会回退 op-geth，块内无 flashblocks"
  fi
fi

summary
