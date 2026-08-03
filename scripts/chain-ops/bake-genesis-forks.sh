#!/bin/bash
#
# Bake hardfork times into genesis.json, making it the single source of fork truth shared by op-geth
# and the reth family (op-rbuilder/op-reth).
#
# Background: reth does not support op-geth's --override.* runtime fork overrides and can only read the fork
# schedule from the JSON specified by --chain. Therefore, fork times are written to genesis.config instead of
# configuring geth through startup flags. Both geth init and reth use the same genesis.json, ensuring the same
# genesis hash and fork schedule without additional configuration.
#
# The single source of truth is .envrc's FORK_*_TIME values, the same variables activate-fork.sh uses to
# write rollup.json via sync_fork. Genesis and rollup are each derived independently from .envrc and never
# from one another as secondary artifacts, preventing them from drifting. activate-fork.sh normally invokes this script.
#
# op-geth constraint: if genesis contains isthmusTime, it must also contain pragueTime=isthmusTime or init fails.
#
# Semantics: a nonempty variable writes the corresponding *Time; an empty variable deletes that key
# (meaning unscheduled). The operation is idempotent and can be repeated; genesis.json is replaced atomically in place.
#
source .envrc
set -e

CFG="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}"
GEN="${1:-$CFG/genesis.json}"

[ -f "$GEN" ] || { echo "genesis does not exist: $GEN"; exit 1; }

# Fork source of truth: .envrc FORK_*_TIME values (the same source used by rollup.json).
G="${FORK_GRANITE_TIME:-}"
H="${FORK_HOLOCENE_TIME:-}"
I="${FORK_ISTHMUS_TIME:-}"
J="${FORK_JOVIAN_TIME:-}"

TMP="$(mktemp)"
# A nonempty variable writes the corresponding camelCase *Time; an empty value deletes the key.
# Add pragueTime=isthmusTime when isthmusTime exists; otherwise delete pragueTime as well (an op-geth requirement).
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

echo "Fork schedule baked into genesis: ${GEN} (source: .envrc FORK_*_TIME)"
jq -c '.config | {graniteTime, holoceneTime, isthmusTime, jovianTime, pragueTime}' "$GEN"
