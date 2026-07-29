#!/bin/bash
#
# 把硬分叉时间「烘入」genesis.json，使其成为 op-geth 与 reth 系（op-rbuilder/op-reth）
# 共用的唯一分叉真源。
#
# 背景：reth 没有 op-geth 的 --override.* 运行时分叉覆盖，只能从 --chain 指的 JSON 读分叉表。
# 因此不再让 geth 用启动参数配置分叉，改为把分叉时间写进 genesis.config，geth init 与 reth
# 用同一份 genesis.json 启动，创世 hash 一致、分叉表一致，无需额外配置。
#
# 单一真源是 .envrc 的 FORK_*_TIME —— 与 activate-fork.sh 写 rollup.json（sync_fork）用的是
# 同一批变量。genesis 与 rollup 各自独立地从 .envrc 派生，绝不从对方（二手产物）取值，
# 因此两者不可能相互漂移。本脚本通常由 activate-fork.sh 在激活分叉时调用。
#
# op-geth 约束：genesis 里出现 isthmusTime 时，必须同时有 pragueTime=isthmusTime，否则 init 报错。
#
# 语义：变量非空 → 写入该 *Time；变量为空 → 删除该 key（表示未调度）。幂等，可反复运行；
# 原地覆盖 genesis.json（原子写）。
#
source .envrc
set -e

CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GEN="${1:-$CFG/genesis.json}"

[ -f "$GEN" ] || { echo "genesis 不存在: $GEN"; exit 1; }

# 分叉真源：.envrc 的 FORK_*_TIME（与 rollup.json 同源）。
G="${FORK_GRANITE_TIME:-}"
H="${FORK_HOLOCENE_TIME:-}"
I="${FORK_ISTHMUS_TIME:-}"
J="${FORK_JOVIAN_TIME:-}"

TMP="$(mktemp)"
# 变量非空 → 写入对应 camelCase *Time；为空 → 删除该 key。
# 有 isthmusTime 时补 pragueTime=isthmusTime；无则一并删除 pragueTime（op-geth 硬性要求）。
jq --arg g "$G" --arg h "$H" --arg i "$I" --arg j "$J" '
  def setfork($key; $v): if $v == "" then del(.config[$key]) else .config[$key] = ($v | tonumber) end;
  setfork("graniteTime";  $g)
  | setfork("holoceneTime"; $h)
  | setfork("isthmusTime";  $i)
  | setfork("jovianTime";   $j)
  | (if .config.isthmusTime != null
       then .config.pragueTime = .config.isthmusTime
       else del(.config.pragueTime) end)
' "$GEN" > "$TMP"

mv "$TMP" "$GEN"

echo "分叉已烘入 genesis: ${GEN}（源：.envrc FORK_*_TIME）"
jq -c '.config | {graniteTime, holoceneTime, isthmusTime, jovianTime, pragueTime}' "$GEN"
