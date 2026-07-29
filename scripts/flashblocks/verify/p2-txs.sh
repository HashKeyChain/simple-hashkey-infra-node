#!/bin/bash
#
# P2 验证 —— 交易覆盖：有真实负载时 op-geth 与 op-rbuilder 是否仍逐字节一致
#
# 覆盖五类交易：
#   T1 CGT 存款 (L1→L2 deposit)   —— 系统交易路径，CGT 链特有，风险最高
#   T2 普通转账                    —— 最基础的 value transfer
#   T3 合约部署                    —— create 路径
#   T4 合约调用（成功）            —— 写存储 + 发事件
#   T5 合约调用（revert）          —— 失败交易也必须被两侧一致地打包
#
# 为什么要把交易同时投给两个节点：
#   dry_run 下用户交易走 op-geth 的 HTTP RPC (:8645)，不经过 rollup-boost
#   —— rollup-boost 只代理 Engine API。op-rbuilder 的交易池因此收不到这些交易，
#   它造出来的会是空块，和 op-geth 的非空块必然不同，对账就假失败了。
#   真实 enabled 拓扑里这一步由 op-reth → rollup-boost 的 fan-out 完成；
#   dry_run 下没起 op-reth，所以本脚本手动把同一笔已签名 raw tx 投给两边，
#   复现 fan-out 后再比对结果。
#
# 用法: bash scripts/flashblocks/verify/p2-txs.sh [--skip-deposit] [--amount=N]
#   --skip-deposit  跳过 T1（L1 存款较慢，且需要 L1 上有 CGT 余额）
#   --amount=N      T1 存款数量，默认 100（单位 ether）

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SKIP_DEPOSIT=0; DEP_AMOUNT=100
for arg in "$@"; do
  case "$arg" in
    --skip-deposit) SKIP_DEPOSIT=1 ;;
    --amount=*)     DEP_AMOUNT="${arg#*=}" ;;
    *) echo "Unknown arg: $arg" >&2
       echo "Usage: bash scripts/flashblocks/verify/p2-txs.sh [--skip-deposit] [--amount=N]" >&2
       exit 1 ;;
  esac
done

banner "P2 · 交易覆盖与两侧状态对照"

# ---------- 前置 ----------
section "前置条件"
if ! rpc_alive "$L2_RPC"; then fail "op-geth 不可达"; summary; exit 1; fi
if ! rpc_alive "$RB_RPC";  then fail "op-rbuilder 不可达"; summary; exit 1; fi
pass "op-geth / op-rbuilder 均可达"

KEY="${DEPLOY_PRIVATE_KEY:-}"
if [ -z "$KEY" ]; then fail "DEPLOY_PRIVATE_KEY 未配置"; summary; exit 1; fi
ME=$(cast wallet address --private-key "$KEY" 2>/dev/null)
if [ -z "$ME" ]; then fail "DEPLOY_PRIVATE_KEY 无效"; summary; exit 1; fi
info "测试账户 = ${ME}"

CHAIN_ID=$(cast chain-id --rpc-url "$L2_RPC" 2>/dev/null)
info "L2 chainId = ${CHAIN_ID}"

TOUCHED_BLOCKS=""   # 记录所有测试交易落在的块，最后统一做两侧指纹对照

# 把一笔已签名的 raw tx 同时投给 op-geth 与 op-rbuilder，
# 然后等 op-geth 的收据。输出交易哈希。
publish_both() {
  local raw="$1" h
  h=$(cast publish --async --rpc-url "$L2_RPC" "$raw" 2>/dev/null | tr -d '\r\n ')
  # 投给 builder 只为喂它的交易池；它可能因已从区块同步而报 "already known"，忽略即可
  cast publish --async --rpc-url "$RB_RPC" "$raw" >/dev/null 2>&1
  echo "$h"
}

# 等收据。拿到后把结果放进 RC_STATUS（1=成功 0=revert）和 RC_BLOCK，超时则返回 1。
# 用返回值 + 两个变量而不是打印一个字符串，省掉调用方再切一次。
# --async 是必须的：不加它 cast 会自己阻塞等待交易，外层的超时循环就形同虚设。
RC_STATUS=""; RC_BLOCK=""
wait_receipt() {
  local h="$1" i=0
  RC_STATUS=""; RC_BLOCK=""
  while [ "$i" -lt 30 ]; do
    # cast 输出的是 "1 (success)" / "0 (failed)"，只取开头那个数字
    RC_STATUS=$(cast receipt "$h" status --async --rpc-url "$L2_RPC" 2>/dev/null | rg -o '^[01]')
    if [ -n "$RC_STATUS" ]; then
      RC_BLOCK=$(cast receipt "$h" blockNumber --async --rpc-url "$L2_RPC" 2>/dev/null)
      return 0
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

# ---------- T1 CGT 存款 ----------
section "T1 · CGT 存款 (L1 → L2)"
if [ "$SKIP_DEPOSIT" = "1" ]; then
  skip "按 --skip-deposit 跳过存款测试"
else
  PORTAL=$(rg -o '"OptimismPortalProxy": *"(0x[0-9a-fA-F]{40})' -r '$1' "$CFG_DIR/artifact.json" 2>/dev/null)
  if [ -z "$PORTAL" ]; then
    fail "从 ${CFG_DIR}/artifact.json 读不到 OptimismPortalProxy"
  else
    info "OptimismPortal = ${PORTAL}"
    bal0=$(cast balance "$ME" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
    info "存款前 L2 余额 = ${bal0}"
    detail "复用 scripts/bridge-to-l2-custom.sh 执行 approve + depositERC20Transaction"
    if bash "$BASE_PATH/scripts/bridge-to-l2-custom.sh" "$PORTAL" "${DEP_AMOUNT}ether" "$ME" >/tmp/fb_deposit.log 2>&1; then
      # 存款经 L1 → derivation → L2，到账有延迟，轮询等待
      i=0; bal1="$bal0"
      while [ "$i" -lt 60 ]; do
        bal1=$(cast balance "$ME" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
        [ "$bal1" != "$bal0" ] && break
        sleep 2; i=$((i + 1))
      done
      info "存款后 L2 余额 = ${bal1}"
      if [ "$bal1" != "$bal0" ]; then
        pass "CGT 存款到账（等待 $((i * 2))s）"
        rbal=$(cast balance "$ME" --rpc-url "$RB_RPC" 2>/dev/null || echo 0)
        assert_eq "$bal1" "$rbal" "存款后两侧余额一致"
      else
        fail "存款 120s 内未到账 —— 详见 /tmp/fb_deposit.log"
      fi
    else
      fail "bridge-to-l2-custom.sh 执行失败 —— 详见 /tmp/fb_deposit.log"
    fi
  fi
fi

# ---------- 余额检查 ----------
bal=$(cast balance "$ME" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
if [ "$bal" = "0" ]; then
  fail "测试账户 L2 余额为 0，无法继续发交易（先跑一次不带 --skip-deposit 的存款）"
  summary; exit 1
fi

# ---------- T2 普通转账 ----------
section "T2 · 普通转账"
DEST=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
d0=$(cast balance "$DEST" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
raw=$(cast mktx --private-key "$KEY" --rpc-url "$L2_RPC" --value 1ether "$DEST" 2>/dev/null)
if [ -z "$raw" ]; then
  fail "转账交易签名失败"
else
  h=$(publish_both "$raw")
  info "tx = ${h}"
  if ! wait_receipt "$h"; then
    fail "转账交易 30s 内未上链"
  else
    TOUCHED_BLOCKS="$TOUCHED_BLOCKS $RC_BLOCK"
    assert_eq 1 "$RC_STATUS" "转账交易成功（block ${RC_BLOCK}）"
    d1=$(cast balance "$DEST" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
    assert_ne "$d0" "$d1" "收款方余额变化"
  fi
fi

# ---------- 编译测试合约 ----------
section "T3 · 合约部署"
FIX="$VERIFY_DIR/fixtures"
BYTECODE=""
if ! command -v forge >/dev/null 2>&1; then
  skip "forge 不可用，跳过 T3/T4/T5 合约相关测试"
else
  if (cd "$FIX" && forge build >/tmp/fb_forge.log 2>&1); then
    # forge inspect 直接给字节码，不用去 out/ 里翻编译产物 JSON
    BYTECODE=$(cd "$FIX" && forge inspect VerifyTarget bytecode 2>/dev/null)
    [ -n "$BYTECODE" ] && pass "测试合约编译成功（${#BYTECODE} 字符字节码）" \
                       || fail "读不到编译产物 —— 详见 /tmp/fb_forge.log"
  else
    fail "forge build 失败 —— 详见 /tmp/fb_forge.log"
  fi
fi

CONTRACT=""
if [ -n "$BYTECODE" ]; then
  nonce=$(cast nonce "$ME" --rpc-url "$L2_RPC" 2>/dev/null)
  CONTRACT=$(cast compute-address "$ME" --nonce "$nonce" 2>/dev/null | rg -o '0x[0-9a-fA-F]{40}' | head -1)
  info "预计合约地址 = ${CONTRACT}  (nonce=${nonce})"
  # cast mktx 的 --create 必须放在最后一个参数位置
  raw=$(cast mktx --private-key "$KEY" --rpc-url "$L2_RPC" --gas-limit 1000000 --create "$BYTECODE" 2>/dev/null)
  if [ -z "$raw" ]; then
    fail "部署交易签名失败"; CONTRACT=""
  else
    h=$(publish_both "$raw")
    info "tx = ${h}"
    if ! wait_receipt "$h"; then
      fail "部署交易 30s 内未上链"; CONTRACT=""
    else
      TOUCHED_BLOCKS="$TOUCHED_BLOCKS $RC_BLOCK"
      assert_eq 1 "$RC_STATUS" "合约部署成功（block ${RC_BLOCK}）"
      code=$(cast code "$CONTRACT" --rpc-url "$L2_RPC" 2>/dev/null)
      if [ -n "$code" ] && [ "$code" != "0x" ]; then
        pass "合约地址上有代码（${#code} 字符）"
      else
        fail "合约地址上没有代码"
      fi
    fi
  fi
fi

# ---------- T4 合约调用（成功）----------
section "T4 · 合约调用（成功路径）"
if [ -z "$CONTRACT" ]; then
  skip "合约未部署，跳过"
else
  raw=$(cast mktx --private-key "$KEY" --rpc-url "$L2_RPC" "$CONTRACT" 'set(uint256)' 42 2>/dev/null)
  if [ -z "$raw" ]; then
    fail "调用交易签名失败"
  else
    h=$(publish_both "$raw")
    info "tx = ${h}"
    if ! wait_receipt "$h"; then
      fail "set(42) 30s 内未上链"
    else
      TOUCHED_BLOCKS="$TOUCHED_BLOCKS $RC_BLOCK"
      assert_eq 1 "$RC_STATUS" "set(42) 执行成功（block ${RC_BLOCK}）"
      v=$(cast call "$CONTRACT" 'value()(uint256)' --rpc-url "$L2_RPC" 2>/dev/null | awk '{print $1}')
      assert_eq "42" "$v" "op-geth 上存储值已更新"
    fi
  fi
fi

# ---------- T5 合约调用（revert）----------
section "T5 · 合约调用（revert 路径）"
if [ -z "$CONTRACT" ]; then
  skip "合约未部署，跳过"
else
  # 必须显式给 --gas-limit：不给的话 cast 会先 estimateGas，
  # 而 estimate 对必然 revert 的调用直接报错，交易根本发不出去。
  raw=$(cast mktx --private-key "$KEY" --rpc-url "$L2_RPC" --gas-limit 200000 "$CONTRACT" 'boom()' 2>/dev/null)
  if [ -z "$raw" ]; then
    fail "revert 交易签名失败"
  else
    h=$(publish_both "$raw")
    info "tx = ${h}"
    if ! wait_receipt "$h"; then
      fail "boom() 30s 内未上链"
    else
      TOUCHED_BLOCKS="$TOUCHED_BLOCKS $RC_BLOCK"
      assert_eq 0 "$RC_STATUS" "boom() 如期 revert 且已上链（block ${RC_BLOCK}）"
      detail "失败交易同样要占块、扣 gas，两侧必须得出一致结果。"
    fi
  fi
fi

# ---------- 两侧对账 ----------
section "两侧状态对照"
info "等待 op-rbuilder 同步到最新..."
gbn=$(rpc_bn "$L2_RPC"); i=0
while [ "$i" -lt 20 ]; do
  [ "$(rpc_bn "$RB_RPC")" -ge "$gbn" ] && break
  sleep 1; i=$((i + 1))
done

mis=0; n=0
for bn in $(echo "$TOUCHED_BLOCKS" | tr ' ' '\n' | sort -n -u); do
  [ -z "$bn" ] && continue
  n=$((n + 1))
  a=$(block_hash "$L2_RPC" "$bn")
  b=$(block_hash "$RB_RPC" "$bn")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    detail "block ${bn}  ✓  ${a}"
  else
    mis=$((mis + 1))
    fail "block ${bn} 两侧 blockHash 不一致"
    detail "geth     hash=${a}  stateRoot=$(block_state_root "$L2_RPC" "$bn")"
    detail "rbuilder hash=${b}  stateRoot=$(block_state_root "$RB_RPC" "$bn")"
  fi
done
info "本轮交易共落在 ${n} 个区块"
assert_eq 0 "$mis" "所有含测试交易的区块两侧 blockHash 一致"

if [ -n "$CONTRACT" ]; then
  gc=$(cast code "$CONTRACT" --rpc-url "$L2_RPC" 2>/dev/null)
  rc=$(cast code "$CONTRACT" --rpc-url "$RB_RPC" 2>/dev/null)
  assert_eq "${#gc}" "${#rc}" "两侧合约代码长度一致"
  gv=$(cast call "$CONTRACT" 'value()(uint256)' --rpc-url "$L2_RPC" 2>/dev/null | awk '{print $1}')
  rv=$(cast call "$CONTRACT" 'value()(uint256)' --rpc-url "$RB_RPC" 2>/dev/null | awk '{print $1}')
  assert_eq "$gv" "$rv" "两侧合约存储值一致"
fi

for a in "$ME" "$DEST"; do
  gb=$(cast balance "$a" --rpc-url "$L2_RPC" 2>/dev/null || echo x)
  rb=$(cast balance "$a" --rpc-url "$RB_RPC" 2>/dev/null || echo y)
  assert_eq "$gb" "$rb" "两侧余额一致 ${a}"
done

summary
