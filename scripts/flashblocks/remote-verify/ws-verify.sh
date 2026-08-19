#!/bin/bash
# 验证对外暴露的 flashblocks WebSocket 入口能不能给外部 op-reth 用。
#
# 在仓库根目录执行：
#
#   bash scripts/flashblocks/remote-verify/ws-verify.sh env.qa [观测窗口秒数] [-v]
#
# verify.sh 验的是「用户发交易能不能拿到预确认」，走的是 op-reth 的 RPC，而那个 op-reth
# 订阅的是集群内网地址（hsk-fullnode-reth-0 连 ws://hsk-flashblocks-ws-proxy-0:1113/ws）。
# 对外暴露的 wss 入口是另一条路径，多走一层 ingress，verify.sh 覆盖不到，所以单独验。
#
# 不需要私钥，不发交易，纯订阅观察。
set -u

ENV_FILE=${1:?用法: bash scripts/flashblocks/remote-verify/ws-verify.sh <env 文件> [观测窗口秒数] [-v]}
WINDOW=${2:-10}
VERBOSE=${3:-}
HERE=$(cd "$(dirname "$0")" && pwd)

[ -f "$ENV_FILE" ] || ENV_FILE="$HERE/$ENV_FILE"
[ -f "$ENV_FILE" ] || { echo "找不到 env 文件：$1" >&2; exit 1; }
source "$ENV_FILE"

FBWATCH=$HERE/bin/fbwatch
BLOCK_TIME_MS=${BLOCK_TIME_MS:-2000}

die() { echo "$*" >&2; exit 1; }

[ -n "${WS_URL:-}" ] || die "env 里缺 WS_URL"

if [ ! -x "$FBWATCH" ]; then
  command -v go >/dev/null || die "$FBWATCH 不存在且没装 go"
  # 依赖已 vendor 进仓库，这一步不联网。
  ( cd "$HERE/fbwatch" && go build -mod=vendor -o "$FBWATCH" . ) || die "fbwatch 编译失败"
fi

echo "ws=$WS_URL  观测 ${WINDOW}s  出块周期 ${BLOCK_TIME_MS}ms"

ok=0; status=0; bytes=0; slices=0; decode_fail=0; blocks=0
block_low=0; block_high=0; checked_blocks=0; incomplete_blocks=0
max_gap_ms=0; p50_gap_ms=0; max_block_span_ms=0; error=""
eval "$("$FBWATCH" -url "$WS_URL" -timeout "$WINDOW" ${VERBOSE:+-v})"

[ "$ok" = 1 ] || case "$error" in
  connect)   die "连不上。TLS/DNS/ingress 没通，或者服务没起" ;;
  # 404 基本是 URL 路径写错（ws-proxy 挂在 /ws 上）；其他码更像 ingress 把 Upgrade 和
  # Connection 头吃掉了，请求被当成普通 HTTP 处理，所以回了个正常响应而不是 101。
  handshake) die "TCP 通了但握手被拒（HTTP ${status}）。404 查 URL 路径，其他码查 ingress 有没有转发 Upgrade/Connection 头" ;;
  *)         die "订阅失败：$error" ;;
esac

# 期望的块推进数。观测窗口横跨的块数 = 窗口 / 出块周期，两端各允许残缺一个，所以减 1 兜底。
EXPECT=$(( WINDOW * 1000 / BLOCK_TIME_MS - 1 ))
ADVANCE=$(( block_high - block_low ))

# 每项都把量到的数和它对应的门槛并排打出来，通过的项也打。
# 只在失败时打数字的话，PASS 就成了一句没有证据的断言，看不出是贴着门槛过的还是富余很多。
#
# 标签统一用 4 个汉字，不靠 printf 补齐：%-Ns 按字节数补，而中文一字 3 字节，
# 字数不同的标签会被补成参差不齐。字数一致就不需要补。
printf '  %s  %s\n' \
  握手结果 "HTTP ${status}" \
  数据总量 "$slices 片 / $bytes 字节，解析失败 $decode_fail 片" \
  块号推进 "$ADVANCE 个（${block_low}..${block_high}），期望 ≥ $EXPECT" \
  切片完整 "$incomplete_blocks 个块序号不连续（完整观测 $checked_blocks 个块）" \
  切片间隔 "p50 ${p50_gap_ms}ms，最大 ${max_gap_ms}ms，须 < ${BLOCK_TIME_MS}ms" \
  单块跨度 "最大 ${max_block_span_ms}ms，须 < ${BLOCK_TIME_MS}ms"
echo

FAIL=0
note() { echo "  FAIL  $*"; FAIL=1; }

[ "$slices" -gt 0 ] || note "窗口内一片都没收到，端口开着但流是空的"
[ "$decode_fail" = 0 ] || note "$decode_fail 片解不开，外部 reth 也会解不开（ws-proxy 压缩开关变了？）"

# 块必须在推进。停滞说明 builder 掉队了：连接和端口都正常，流却在原地打转。
[ "$ADVANCE" -ge "$EXPECT" ] || note "${WINDOW}s 内只推进 $ADVANCE 个块，至少该有 $EXPECT 个"

# 切片序号不连续，外部 reth 拼不出 pending 块，会整块丢弃，预确认就没了。
[ "$incomplete_blocks" = 0 ] || note "$incomplete_blocks 个块的切片序号不是从 0 起连续（-v 看是哪几个）"

# 间隔超过一个出块周期，等于整块的切片都没来，中间断流了。
[ "$max_gap_ms" -lt "$BLOCK_TIME_MS" ] || note "最大切片间隔 ${max_gap_ms}ms 超过出块周期 ${BLOCK_TIME_MS}ms，中间断过流"

# 末片要明显早于封口，否则用户拿到完整块内容的时刻和上链没差别，预确认没有实际提前量。
[ "$max_block_span_ms" -lt "$BLOCK_TIME_MS" ] || note "单块切片跨度 ${max_block_span_ms}ms 不短于出块周期 ${BLOCK_TIME_MS}ms，没有提前量"

[ "$FAIL" = 0 ] && echo "PASS  外部 wss 入口可订阅，流连续完整，外部 op-reth 可以直接接这个地址"
exit "$FAIL"
