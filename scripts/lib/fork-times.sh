#!/bin/bash
#
# FORK_*_TIME 的解析器（分叉激活时间的取值规则唯一真源）。
#
# 用法（在已 source 过 .envrc 的脚本里）：
#   source "$SCRIPT_DIR/lib/fork-times.sh"
#   resolve_fork_times "$ROLLUP_FILE" || exit 1
# 之后 FORK_FJORD_TIME / GRANITE / HOLOCENE / ISTHMUS / JOVIAN 都已是绝对 unix 秒。
#
# ---------------------------------------------------------------------------
# 为什么需要它：绝对时间戳每次重建链都得手工重算，忘了就是 op-geth 直接崩
# ---------------------------------------------------------------------------
# 分叉时间必须晚于 L2 创世时间，而创世时间每次 chain-reset + chain-setup 都会变。
# 以前 .envrc 里写的是绝对秒，于是每次重建链都要人工把 4 个数字按新创世时间重算一遍；
# 漏算一次，分叉时间就早于创世，后果是 op-geth 一个块都出不来：
#   1. Holocene 起，EIP-1559 的 denominator/elasticity 编码在区块头 extraData 里
#      （op-geth consensus/misc/eip1559 的 DecodeOptimismExtraData）。
#   2. genesis.json 由 beta.3 op-node 生成，config 里没有 holocene/isthmus/jovian，
#      op-geth init 写出的创世头 extraData = "BEDROCK"（7 字节）。
#   3. 分叉时间早于（或等于）创世时间时，op-geth 认为创世块已是 Jovian，
#      于是拿 "BEDROCK" 去按 Jovian 格式（17 字节）解析 1559 参数，长度不符返回 0,0。
#   4. 构建第 1 个块时 calcBaseFeeInner 执行 parent.GasLimit / elasticity(=0)：
#      panic: runtime error: integer divide by zero。
# 另外分叉早于创世还会让 op-node 的 IsIsthmusActivationBlock/IsJovianActivationBlock
# 恒为 false，Isthmus/Jovian 的网络升级交易永不注入，L1Block/GasPriceOracle 会停留在
# beta.3 L2Genesis 种下的 pre-Isthmus 字节码。
#
# ---------------------------------------------------------------------------
# 取值形式
# ---------------------------------------------------------------------------
#   +N        相对创世的偏移：创世 l2_time + N 秒。**推荐写法**，重建链无需人工介入。
#   <整数>    绝对 unix 秒。仍然支持（真实网络的既定分叉时间只能这么写）。
#   0         创世即激活。
#   留空      该分叉不调度（rollup.json 置 null、op-geth 不下发 override）。
#
# 创世时间取自 rollup.json 的 .genesis.l2_time —— 它是链的实际创世时间，
# 由部署产出、不随本文件变化，因此 "+N" 的解析结果对同一条链是幂等的。
#
# 无论写的是相对还是绝对值，解析后都会检查「非 0 且不晚于创世」这个致命组合并直接报错，
# 所以即使有人坚持写绝对秒，也不会再出现上面那个 panic。

# resolve_fork_times <rollup.json 路径>
#   把 FORK_*_TIME 解析成绝对 unix 秒并重新 export；失败返回 1。
resolve_fork_times() {
  local rollup_file="$1"
  local genesis_time="" name var raw val

  if [ -f "$rollup_file" ]; then
    genesis_time=$(jq -r '.genesis.l2_time // empty' "$rollup_file" 2>/dev/null || true)
    case "$genesis_time" in
      ''|*[!0-9]*) genesis_time="" ;;
    esac
  fi

  for name in FJORD GRANITE HOLOCENE ISTHMUS JOVIAN; do
    var="FORK_${name}_TIME"
    raw="${!var:-}"
    [ -z "$raw" ] && continue

    case "$raw" in
      +*)
        if [ -z "$genesis_time" ]; then
          echo "Error: $var=$raw 是相对创世的偏移，但取不到创世时间。" >&2
          echo "       需要 $rollup_file 里的 .genesis.l2_time（先跑 chain-setup.sh 生成配置）。" >&2
          return 1
        fi
        val="${raw#+}"
        case "$val" in
          ''|*[!0-9]*)
            echo "Error: $var=$raw 的偏移量不是非负整数。" >&2
            return 1
            ;;
        esac
        val=$((genesis_time + val))
        ;;
      *[!0-9]*)
        echo "Error: $var=$raw 不是合法取值。允许：+N（相对创世偏移）、绝对 unix 秒、0、留空。" >&2
        return 1
        ;;
      *)
        val="$raw"
        ;;
    esac

    # 致命组合：非 0 却不晚于创世 —— 就是上面那个 op-geth panic 的成因。
    if [ -n "$genesis_time" ] && [ "$val" != "0" ] && [ "$val" -le "$genesis_time" ]; then
      echo "Error: $var 解析为 $val，不晚于 L2 创世时间 $genesis_time。" >&2
      echo "       这会让 op-geth 认为创世块已过该分叉，用 7 字节的 \"BEDROCK\" extraData 去按" >&2
      echo "       分叉后格式解析 1559 参数，elasticity=0，建第一个块时 panic: integer divide by" >&2
      echo "       zero，一个块都出不来。" >&2
      echo "       改用相对写法即可自动跟随创世时间：export $var=+60" >&2
      return 1
    fi

    export "$var=$val"
  done

  FORK_TIMES_GENESIS_L2_TIME="$genesis_time"
  export FORK_TIMES_GENESIS_L2_TIME
  return 0
}
