#!/bin/bash
#
# P0 验证 —— 编译产物 / 版本世代 / 创世对齐 / JWT 一致
#
# 对应 doc/flashblocks_local_impl.md §7 P0 门：
#   「reth 系成功加载 genesis；op-rbuilder 创世 hash == op-geth 创世 hash」
# 另加两项该文档列为高风险、但原门里没写成检查项的：
#   - 版本世代锁 Jovian（§10 风险 1：混入 Karst 世代会引入 Engine API V5，与 op-node v1.16.x 不兼容）
#   - JWT 一致（§10 风险 4：所有组件必须共用同一份 jwt.txt）
#
# 用法: bash scripts/flashblocks/verify/p0-genesis.sh
# 前提: 无。二进制在 bin/ 即可；创世对比一项需要 op-geth 与 op-rbuilder 在跑，否则自动 SKIP。

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

banner "P0 · 编译产物 / 版本世代 / 创世对齐 / JWT"

# ---------- 依赖 ----------
section "工具依赖"
if require_cmd cast rg curl; then
  pass "cast / rg / curl 齐备"
else
  fail "缺少必要命令，后续检查不可靠"
  summary; exit 1
fi

# ---------- Rust 二进制 ----------
section "Rust 组件二进制"
for b in rollup-boost op-rbuilder op-reth flashblocks-websocket-proxy; do
  if [ -x "$BASE_PATH/bin/$b" ]; then
    pass "bin/${b} 存在且可执行"
  else
    fail "bin/${b} 缺失 —— 先跑 bash scripts/flashblocks/build-flashblocks.sh"
  fi
done

# ---------- 版本世代 ----------
# 只有 op-rbuilder / op-reth 的 --version 反映真实 tag；rollup-boost 与 ws-proxy 的
# 内部版本号恒为 0.1.0，只能回源码目录用 git describe 校验。
section "版本世代锁定（必须是 Jovian 世代，不能混入 Karst）"

check_git_ref() {
  local dir="$1" want="$2" name="$3"
  if [ ! -e "$BASE_PATH/$dir/.git" ]; then
    skip "${name} 源码目录不是 git 仓库，无法校验 tag"
    return
  fi
  local got; got=$(git -C "$BASE_PATH/$dir" describe --tags --always 2>/dev/null)
  case "$got" in
    *"$want") pass "${name} = ${got}  (期望含 ${want})" ;;
    *)        fail "${name} = ${got}  期望含 ${want}" ;;
  esac
}

check_bin_version() {
  local bin="$1" want="$2" name="$3"
  [ -x "$BASE_PATH/bin/$bin" ] || { skip "${name} 二进制缺失，跳过版本校验"; return; }
  local got; got=$("$BASE_PATH/bin/$bin" --version 2>&1 | head -1)
  case "$got" in
    *"$want"*) pass "${name} → ${got}" ;;
    *)         fail "${name} → ${got}  期望含 ${want}" ;;
  esac
}

check_git_ref rollup-boost "${ROLLUP_BOOST_REF:-v0.7.11}" "rollup-boost 源码 tag"
check_git_ref op-rbuilder "${OP_RBUILDER_REF:-op-rbuilder/v0.2.13}" "op-rbuilder 源码 tag"
check_bin_version op-rbuilder "$(echo "${OP_RBUILDER_REF:-v0.2.13}" | sed 's#.*/v##')" "op-rbuilder 二进制版本"
check_bin_version op-reth "$(echo "${OP_RETH_REF:-v1.9.3}" | sed 's#^v##')" "op-reth 二进制版本"

# ---------- 配置文件 ----------
section "链配置文件"
for f in genesis.json rollup.json; do
  if [ -s "$CFG_DIR/$f" ]; then
    pass "${CFG_DIR}/${f} 存在"
  else
    fail "${CFG_DIR}/${f} 缺失或为空"
  fi
done

if [ -s "$CFG_DIR/genesis.json" ]; then
  forks=$(rg -o '"(canyon|delta|ecotone|fjord|granite|holocene|isthmus|jovian)Time": *([0-9]+)' -r '$1=$2' \
    "$CFG_DIR/genesis.json" | tr '\n' ' ')
  if [ -z "$forks" ]; then
    fail "genesis.json 里没有任何分叉时间 —— op-geth 会退回 --override.* 方式，op-rbuilder 读不到"
  else
    pass "分叉时间已烘入 genesis.json"
    detail "$forks"
  fi
fi

# ---------- 创世 hash 对齐 ----------
section "创世 hash 对齐（P0 核心门）"
if rpc_alive "$L2_RPC" && rpc_alive "$RB_RPC"; then
  gh=$(block_hash "$L2_RPC" 0)
  rh=$(block_hash "$RB_RPC" 0)
  info "op-geth     genesis = ${gh}"
  info "op-rbuilder genesis = ${rh}"
  assert_eq "$gh" "$rh" "op-rbuilder 与 op-geth 创世 hash 一致"
else
  skip "op-geth 或 op-rbuilder 未运行，无法对比创世 hash"
  detail "op-geth(${L2_RPC}) alive=$(rpc_alive "$L2_RPC" && echo yes || echo no)  op-rbuilder(${RB_RPC}) alive=$(rpc_alive "$RB_RPC" && echo yes || echo no)"
fi

# ---------- 分片配置 ----------
section "op-rbuilder 分片配置"
# 每块该切几片 = chain_block_time / flashblocks_interval。若 run-op-rbuilder.sh 忘传
# --rollup.chain-block-time，op-rbuilder 会按默认 1000ms 算，片数减半，后半个块窗口
# 完全空转 —— 链照样跑、区块照样有效，所以只有对比这个数才能发现。
# 属一次性配置检查，放这里而不是每次观测都跑。
per=$(( ${L2_BLOCK_TIME:-2} * 1000 / ${FB_INTERVAL_MS:-250} ))
detail "应有片数 = L2_BLOCK_TIME(${L2_BLOCK_TIME:-2}s) / 分片间隔(${FB_INTERVAL_MS:-250}ms) = ${per}"
target=$(strip_ansi "$LOG_DIR/op-rbuilder.log" | rg -o 'target_flashblocks=([0-9]+)' -r '$1' | tail -1)
if [ -z "$target" ]; then
  skip "op-rbuilder 日志里还没有 target_flashblocks（未启动过或日志已清）"
else
  assert_eq "$per" "$target" "op-rbuilder 实际每块片数 target_flashblocks"
  [ "$target" != "$per" ] && detail "不符通常是 run-op-rbuilder.sh 未传 --rollup.chain-block-time。"
fi

# ---------- JWT 一致 ----------
section "JWT 一致性（所有组件必须同一份 jwt.txt）"
if [ -s "$JWT_FILE" ]; then
  pass "JWT 文件存在: ${JWT_FILE}"
else
  fail "JWT 文件缺失: ${JWT_FILE}"
fi

# 按进程名精确枚举，不要用 `ps | rg jwt`：rg 自己的命令行含有 pattern，会被算进结果。
jwts=""
for name in op-geth op-node op-rbuilder op-reth rollup-boost; do
  for pid in $(pgrep -x "$name" 2>/dev/null); do
    v=$(ps -o args= -p "$pid" 2>/dev/null \
      | rg -o '\-\-[a-z0-9.-]*jwt[a-z-]*[= ]([^ ]+)' -r '$1')
    [ -n "$v" ] && jwts="${jwts}${v}
"
  done
done
jwts=$(echo "$jwts" | rg -v '^$' | sort -u)

if [ -z "$jwts" ]; then
  skip "没有正在运行的组件，无法核对各进程的 JWT 路径"
else
  n=$(echo "$jwts" | wc -l | tr -d ' ')
  info "运行中组件引用的 JWT 路径共 ${n} 个:"
  echo "$jwts" | sed 's/^/       /'
  assert_eq 1 "$n" "所有运行中组件共用同一份 JWT"
fi

summary
