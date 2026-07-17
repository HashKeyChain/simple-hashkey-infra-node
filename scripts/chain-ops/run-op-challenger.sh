#!/bin/bash
#
# 启动 op-challenger（Fault Proof 挑战者，trace-type=cannon/permissioned）。
#
# 前置条件：
#   1. USE_FAULT_PROOFS=true
#   2. 已 chain-setup + chain-start，链在运行（op-geth / op-node）
#   3. 已构建 fault-proof 二进制（bash scripts/build-binaries.sh，USE_FAULT_PROOFS=true 时自动构建）：
#      bin/cannon、bin/op-program、bin/prestate.json（可选 bin/prestate-proof.json 用于哈希校验）
#
# 用法:
#   bash scripts/chain-ops/run-op-challenger.sh              # 前台运行（chain-start.sh 以此方式拉起）
#   bash scripts/chain-ops/run-op-challenger.sh --background # 后台运行并写 pid/log
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "${USE_FAULT_PROOFS:-false}" != "true" ]; then
  echo "USE_FAULT_PROOFS != true：非 Fault Proof 模式，无需 op-challenger。"
  exit 0
fi

BACKGROUND=false
[ "${1:-}" = "--background" ] && BACKGROUND=true

# 配置统一取 config/<context>/（git 跟踪、经 runbook patch 的规范配置），与 chain-start.sh 一致。
CFG_DIR="${_CALLER_DEPLOYMENT_CONFIG_PATH:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}}"
ROLLUP_JSON="$CFG_DIR/rollup.json"
GENESIS_JSON="$CFG_DIR/genesis.json"
ARTIFACT_JSON="$CFG_DIR/artifact.json"

# trace-type 跟随 GAME_TYPE：1=PERMISSIONED_CANNON→permissioned，0=CANNON→cannon。
# 与部署时 respectedGameType 及 op-proposer 的 --game-type 保持一致。
if [ "${GAME_TYPE:-1}" = "1" ]; then
  TRACE_TYPE=permissioned
else
  TRACE_TYPE=cannon
fi

# L1 Beacon：op-challenger 的 --l1-beacon 是必填项，用于按 blob 拉取 DA。
# 本地 anvil 没有 Beacon API：calldata DA 模式下通常不会触发 blob 请求，可先回退到 L1 RPC；
# 若 challenger 因 beacon 连接失败起不来，需指向真实 Beacon 或运行一个 fake beacon，
# 并用 L1_BEACON_URL 覆盖。
L1_BEACON="${L1_BEACON_URL:-$L1_RPC_URL}"

CANNON_BIN="$BASE_PATH/bin/cannon"
OP_PROGRAM_BIN="$BASE_PATH/bin/op-program"
# reproducible-prestate 产出的是单线程(ST) prestate.json；其 .pre 记录在 prestate-proof.json。
PRESTATE="$BASE_PATH/bin/prestate.json"
PRESTATE_PROOF="$BASE_PATH/bin/prestate-proof.json"

# ---------- 预检：配置文件 ----------
for f in "$ROLLUP_JSON" "$GENESIS_JSON" "$ARTIFACT_JSON"; do
  [ -f "$f" ] || fail "缺少配置文件: ${f}（先执行 bash scripts/deploy-chain/chain-setup.sh ${DEPLOYMENT_CONTEXT}）"
done

# ---------- 预检：二进制 ----------
for b in "$CANNON_BIN" "$OP_PROGRAM_BIN" "$PRESTATE"; do
  [ -f "$b" ] || fail "缺少 fault-proof 依赖: ${b}（先执行 bash scripts/build-binaries.sh，需 USE_FAULT_PROOFS=true）"
done

# ---------- 预检：DisputeGameFactory 地址 ----------
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // empty' "$ARTIFACT_JSON")
[ -n "$GAME_FACTORY" ] || fail "artifact 中缺少 DisputeGameFactoryProxy: $ARTIFACT_JSON"

# ---------- 预检：prestate 哈希（仅告警，不拦截）----------
# challenger 除参与 dispute（需正确 prestate 生成 claim）外，也负责 resolve/claim bond 等
# 不依赖 prestate 的操作。本项目当前用官方 beta3 op-program，对 CGT/Jovian 定制链算出的状态根
# 与链上 absolute prestate 不一致，无法真正挑战成功；但仍允许启动 challenger 做 resolve。
# 故此处 prestate 不匹配只告警，不退出。
EXPECTED_PRESTATE=$(jq -r '.faultGameAbsolutePrestate // empty' "$DEPLOY_CONFIG_PATH" 2>/dev/null || true)
if [ -f "$PRESTATE_PROOF" ] && [ -n "$EXPECTED_PRESTATE" ]; then
  ACTUAL_PRESTATE=$(jq -r '.pre // empty' "$PRESTATE_PROOF")
  if [ "$ACTUAL_PRESTATE" != "$EXPECTED_PRESTATE" ]; then
    echo "WARN: prestate 哈希不匹配！链上(deploy-config)=${EXPECTED_PRESTATE}，本地=${ACTUAL_PRESTATE}。"
    echo "      无法用此 prestate 参与 dispute game（生成的 claim 状态根对不上），"
    echo "      但 resolve / claim bond 等操作不受影响，继续启动。"
    echo "      若要真正挑战：用与部署一致的 op-program/cannon 重建 prestate，或用新 prestate 重新部署合约。"
  else
    echo "prestate 哈希校验通过: ${ACTUAL_PRESTATE}"
  fi
else
  echo "WARN: 未能自动校验 prestate 哈希（缺 ${PRESTATE_PROOF} 或 deploy-config 无 faultGameAbsolutePrestate）。"
  echo "      请手动确认 bin/prestate-proof.json 的 .pre == ${EXPECTED_PRESTATE}"
fi

# ---------- 预检：链是否在运行 ----------
cast block-number --rpc-url "$L2_RPC_URL" >/dev/null 2>&1 \
  || fail "L2 RPC 不可达: ${L2_RPC_URL}（先执行 bash scripts/chain-ops/chain-start.sh）"
cast rpc optimism_syncStatus --rpc-url "$OP_NODE_RPC_URL" >/dev/null 2>&1 \
  || fail "op-node RPC 不可达: ${OP_NODE_RPC_URL}（op-node 未就绪）"

# challenger 交易私钥。
# permissioned 模式（GAME_TYPE=1）下，challenger 地址必须等于部署时授权的 challenger：
#   PermissionedDisputeGame._challenger = deploy-config.l2OutputOracleChallenger（Deploy.s.sol），
#   本项目 config.sh 把该字段设为 GS_ADMIN_ADDRESS。地址不符时链上会 BadAuth revert。
# 因此 permissioned 默认用 GS_ADMIN_PRIVATE_KEY；permissionless(cannon) 无授权限制，用默认测试私钥。
# 两种情况都可用 OP_CHALLENGER_PRIVATE_KEY 覆盖。
if [ "$TRACE_TYPE" = "permissioned" ]; then
  CHALLENGER_KEY="${OP_CHALLENGER_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
else
  CHALLENGER_KEY="${OP_CHALLENGER_PRIVATE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
fi

# permissioned 模式预检：challenger 私钥对应地址必须是部署授权地址，避免起来后每次操作都 BadAuth。
if [ "$TRACE_TYPE" = "permissioned" ]; then
  AUTH_CHALLENGER=$(jq -r '.l2OutputOracleChallenger // empty' "$DEPLOY_CONFIG_PATH" 2>/dev/null || true)
  MY_CHALLENGER=$(cast wallet address --private-key "$CHALLENGER_KEY" 2>/dev/null || true)
  if [ -n "$AUTH_CHALLENGER" ] && [ -n "$MY_CHALLENGER" ]; then
    if [ "$(printf '%s' "$AUTH_CHALLENGER" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$MY_CHALLENGER" | tr 'A-Z' 'a-z')" ]; then
      fail "permissioned challenger 地址不匹配：部署授权=${AUTH_CHALLENGER}，当前私钥地址=${MY_CHALLENGER}。
      PermissionedDisputeGame 只接受授权 challenger，否则 BadAuth。
      请用授权私钥（本项目默认 GS_ADMIN_PRIVATE_KEY），或用 OP_CHALLENGER_PRIVATE_KEY 覆盖。"
    fi
    echo "permissioned challenger 地址校验通过: $MY_CHALLENGER"
  else
    echo "WARN: 未能校验 challenger 授权地址（缺 $DEPLOY_CONFIG_PATH 的 l2OutputOracleChallenger，或 cast 不可用）。"
  fi
fi

FLAGS=(
  --log.level=debug
  --trace-type="$TRACE_TYPE"
  --datadir="$BASE_PATH/data/op-challenger"
  --l1-eth-rpc="$L1_RPC_URL"
  --l1-beacon="$L1_BEACON"
  --l2-eth-rpc="$L2_RPC_URL"
  --rollup-rpc="$OP_NODE_RPC_URL"
  --private-key="$CHALLENGER_KEY"
  --game-factory-address="$GAME_FACTORY"
  --cannon-rollup-config="$ROLLUP_JSON"
  --cannon-l2-genesis="$GENESIS_JSON"
  --cannon-bin="$CANNON_BIN"
  --cannon-server="$OP_PROGRAM_BIN"
  --cannon-prestate="$PRESTATE"
  --network-timeout=600s
  --num-confirmations=1
)

# 预建 datadir：challenger 的周期性清理任务会 ls 此目录，不存在时会刷 "Unable to cleanup
# game data" 的 error 噪音（resolve-only 模式从不写 cannon trace，目录本不会自动生成）。
mkdir -p "$BASE_PATH/data/op-challenger"

echo "Starting op-challenger ..."
echo "  trace-type   : $TRACE_TYPE"
echo "  game-factory : $GAME_FACTORY"
echo "  rollup config: $ROLLUP_JSON"
echo "  l2 genesis   : $GENESIS_JSON"
echo "  prestate     : $PRESTATE"
echo "  l1-beacon    : $L1_BEACON"

if [ "$BACKGROUND" = "true" ]; then
  mkdir -p "$BASE_PATH/data/logs" "$BASE_PATH/data/pids"
  nohup op-challenger "${FLAGS[@]}" >> "$BASE_PATH/data/logs/op-challenger.log" 2>&1 &
  echo $! > "$BASE_PATH/data/pids/op-challenger.pid"
  echo "  op-challenger 已后台启动 (pid $(cat "$BASE_PATH/data/pids/op-challenger.pid"))"
  echo "  日志: data/logs/op-challenger.log"
else
  exec op-challenger "${FLAGS[@]}"
fi
