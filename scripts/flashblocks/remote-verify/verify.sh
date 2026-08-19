#!/bin/bash
# 远程验证 enabled 模式下 flashblocks 对用户是否生效：发交易，量预确认延迟。
#
# 在仓库根目录执行：
#
#   export FB_TEST_KEY=0x…
#   bash scripts/flashblocks/remote-verify/verify.sh env.qa [样本数]
#
# 这个脚本量的是「毫秒数」，判据是绝对阈值，会把本机到 RPC 的网络往返算在内，
# 也受交易落在出块周期哪个相位的影响。要一个和延迟无关的是非判断，用 preconf-check.sh。
#
# 日志类检查看 doc/flashblocks_production_runbook.md 步骤 5/6，不在这里。
set -u

ENV_FILE=${1:?用法: bash scripts/flashblocks/remote-verify/verify.sh <env 文件> [样本数]}
SAMPLES=${2:-3}
HERE=$(cd "$(dirname "$0")" && pwd)

# env 文件也按脚本所在目录找一次，这样从仓库根目录跑也不用写全路径。
[ -f "$ENV_FILE" ] || ENV_FILE="$HERE/$ENV_FILE"
[ -f "$ENV_FILE" ] || { echo "找不到 env 文件：$1" >&2; exit 1; }
source "$ENV_FILE"

TXPROBE=$HERE/../verify/bin/txprobe
PRECONF_MAX_MS=${PRECONF_MAX_MS:-1000}

# tip 必须显式给。空链上 cast 靠 eth_feeHistory 估价，而空块里没有 reward 样本，
# 它会退到 1 wei——低于 sequencer 出块时的最低 tip，交易能进池子但永远不进块，
# 表现成「30 秒没上链」，很容易误判成 flashblocks 坏了。
TIP_WEI=${TIP_WEI:-1000000000}

die() { echo "$*" >&2; exit 1; }

[ -n "${FB_TEST_KEY:-}" ] || die "未设 FB_TEST_KEY。export FB_TEST_KEY=0x…（有少量余额即可，别写进 env 文件）"
[ -n "${RETH_RPC:-}" ]    || die "env 里缺 RETH_RPC"
command -v cast >/dev/null || die "需要 cast 来签名"
command -v jq   >/dev/null || die "需要 jq"

# canonical 基准。填了不认 flashblocks 的 op-geth 才能量出「比上链早多少」；
# 没填就退化成只判绝对阈值——这仍然有效，因为没有 flashblock 时 op-reth 的 pending
# 会退回 latest（pending_block.rs:66），交易封口前压根不会出现在 pending 里。
CANON=${GETH_RPC:-$RETH_RPC}
SEPARATE=1
[ "$CANON" = "$RETH_RPC" ] && SEPARATE=0

if [ ! -x "$TXPROBE" ]; then
  command -v go >/dev/null || die "$TXPROBE 不存在且没装 go"
  ( cd "$HERE/../verify/txprobe" && go build -o "$TXPROBE" . ) || die "txprobe 编译失败"
fi

FROM=$(cast wallet address --private-key "$FB_TEST_KEY" 2>/dev/null) \
  || die "FB_TEST_KEY 解析失败"

echo "op-reth=$RETH_RPC  canonical=$CANON  from=$FROM"
[ "$SEPARATE" = 1 ] || echo "注意：canonical 与 op-reth 是同一个端点，只判 <${PRECONF_MAX_MS}ms，量不出比上链早多少"

[ "$(cast balance "$FROM" --rpc-url "$RETH_RPC" 2>/dev/null || echo 0)" != "0" ] \
  || die "$FROM 余额为 0，先充一点"

# 前置：flashblocks 有没有流到这个 op-reth。收不到时它的 pending 会退化成 latest 的别名，
# 两者相等；收得到时 pending 才是那个正在构建、还没上链的块，块号 = latest + 1。
# 两个块号必须在同一个 batch 请求里取：分两次问的话中间可能跨过一个块，差值就没意义了。
read -r PENDING LATEST < <(
  curl -s --max-time 5 -X POST -H 'Content-Type: application/json' --data \
    '[{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["pending",false]},
      {"jsonrpc":"2.0","id":2,"method":"eth_blockNumber","params":[]}]' "$RETH_RPC" \
  | jq -r 'map(select(.id==1))[0].result.number, map(select(.id==2))[0].result' \
  | xargs printf '%d %d\n' 2>/dev/null
)
case "${PENDING:-}${LATEST:-}" in ''|*[!0-9]*) die "读不到 $RETH_RPC 的 pending/latest 块号" ;; esac
echo "pending=$PENDING latest=$LATEST"
[ "$PENDING" -gt "$LATEST" ] \
  || die "pending 和 latest 相等，flashblocks 没流到这个 op-reth，后面发交易也白发"

# nonce 自己数，不让 cast 每笔重新取：cast 读的是已确认 nonce 而不是池子，
# 一笔卡住之后后面每笔都会签在同一个 nonce 上，撞成一串 underpriced 报错。
NONCE=$(cast nonce "$FROM" --rpc-url "$RETH_RPC" --block pending 2>/dev/null)
case "$NONCE" in ''|*[!0-9]*) die "读不到 $FROM 的 nonce" ;; esac

FAIL=0
i=1
while [ "$i" -le "$SAMPLES" ]; do
  raw=$(cast mktx --private-key "$FB_TEST_KEY" --rpc-url "$RETH_RPC" \
          --nonce "$NONCE" --priority-gas-price "$TIP_WEI" --value 1 "$FROM" 2>&1 | tail -1)
  [[ "$raw" == 0x* ]] || { echo "  FAIL  第 $i 笔签名失败：$raw"; FAIL=1; break; }

  ok=0; txhash=""; pre_ms=-1; final_ms=-1; tx_status=-1; tx_block=-1; error=""
  eval "$("$TXPROBE" --send-url="$RETH_RPC" --pending-url="$RETH_RPC" \
            --canonical-url="$CANON" --raw="$raw" --timeout=30)"

  if [ "$ok" != "1" ]; then
    echo "  FAIL  第 $i 笔被拒：$error"; FAIL=1; break
  elif [ "$final_ms" -lt 0 ]; then
    # nonce 已被占用但交易没上链，后面每笔都会排在这个缺口后面白等满超时。
    echo "  FAIL  第 $i 笔 30 秒内没上链，停止（${txhash}）"; FAIL=1; break
  elif [ "$tx_status" != "1" ]; then
    echo "  FAIL  第 $i 笔在块 $tx_block 里执行失败（status=${tx_status}）"; FAIL=1
  elif [ "$pre_ms" -lt 0 ]; then
    echo "  FAIL  第 $i 笔从没出现在 pending，flashblocks 没到用户侧"; FAIL=1
  elif [ "$SEPARATE" = 1 ] && [ "$pre_ms" -ge "$final_ms" ]; then
    echo "  FAIL  第 $i 笔预确认($pre_ms ms)不早于上链($final_ms ms)，预确认没生效"; FAIL=1
  elif [ "$pre_ms" -ge "$PRECONF_MAX_MS" ]; then
    echo "  FAIL  第 $i 笔预确认 ${pre_ms}ms，超过 ${PRECONF_MAX_MS}ms"; FAIL=1
  elif [ "$SEPARATE" = 1 ]; then
    echo "  PASS  第 $i 笔预确认 ${pre_ms}ms，上链 ${final_ms}ms，提前 $((final_ms-pre_ms))ms（块 ${tx_block}）"
  else
    echo "  PASS  第 $i 笔预确认 ${pre_ms}ms（块 ${tx_block}）"
  fi

  NONCE=$((NONCE + 1))
  i=$((i + 1))
done



exit "$FAIL"
