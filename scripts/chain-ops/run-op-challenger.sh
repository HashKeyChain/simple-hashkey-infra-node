#!/bin/bash
#
# Start op-challenger (the Fault Proof challenger, trace-type=cannon/permissioned).
#
# Prerequisites:
#   1. USE_FAULT_PROOFS=true
#   2. chain-setup and chain-start have run, and the chain is running (op-geth / op-node)
#   3. Fault-proof binaries have been built (bash scripts/build-binaries.sh builds them when USE_FAULT_PROOFS=true):
#      bin/cannon, bin/op-program, and bin/prestate.json (optionally bin/prestate-proof.json for hash verification)
#
# Usage:
#   bash scripts/run-op-challenger.sh              # Run in the foreground (chain-start.sh launches it this way)
#   bash scripts/run-op-challenger.sh --background # Run in the background and write PID/log files
#

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$BASE_PATH"

source .envrc

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "${USE_FAULT_PROOFS:-false}" != "true" ]; then
  echo "USE_FAULT_PROOFS != true: Fault Proof mode is disabled; op-challenger is not required."
  exit 0
fi

BACKGROUND=false
[ "${1:-}" = "--background" ] && BACKGROUND=true

# Read configuration consistently from config/<context>/ (the canonical, Git-tracked configuration patched by the runbook), as chain-start.sh does.
CFG_DIR="${_CALLER_DEPLOYMENT_CONFIG_PATH:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}}"
ROLLUP_JSON="$CFG_DIR/rollup.json"
GENESIS_JSON="$CFG_DIR/genesis.json"
ARTIFACT_JSON="$CFG_DIR/artifact.json"

# Derive trace-type from GAME_TYPE: 1=PERMISSIONED_CANNON -> permissioned; 0=CANNON -> cannon.
# Keep it consistent with respectedGameType at deployment and op-proposer's --game-type.
if [ "${GAME_TYPE:-1}" = "1" ]; then
  TRACE_TYPE=permissioned
else
  TRACE_TYPE=cannon
fi

# L1 Beacon: op-challenger requires --l1-beacon to retrieve DA by blob.
# Local anvil has no Beacon API. Blob requests are generally not triggered in calldata DA mode, so the L1 RPC
# can be used as a fallback. If the challenger fails to start because the Beacon connection fails, point it to
# a real Beacon endpoint or run a fake Beacon endpoint and override it with L1_BEACON_URL.
L1_BEACON="${L1_BEACON_URL:-$L1_RPC_URL}"

CANNON_BIN="$BASE_PATH/bin/cannon"
OP_PROGRAM_BIN="$BASE_PATH/bin/op-program"
# reproducible-prestate produces the single-threaded (ST) prestate.json; its .pre value is recorded in prestate-proof.json.
PRESTATE="$BASE_PATH/bin/prestate.json"
PRESTATE_PROOF="$BASE_PATH/bin/prestate-proof.json"

# ---------- Preflight: configuration files ----------
for f in "$ROLLUP_JSON" "$GENESIS_JSON" "$ARTIFACT_JSON"; do
  [ -f "$f" ] || fail "Missing configuration file: ${f} (run bash scripts/chain-setup.sh ${DEPLOYMENT_CONTEXT} first)"
done

# ---------- Preflight: binaries ----------
for b in "$CANNON_BIN" "$OP_PROGRAM_BIN" "$PRESTATE"; do
  [ -f "$b" ] || fail "Missing fault-proof dependency: ${b} (run bash scripts/build-binaries.sh first with USE_FAULT_PROOFS=true)"
done

# ---------- Preflight: DisputeGameFactory address ----------
GAME_FACTORY=$(jq -r '.DisputeGameFactoryProxy // empty' "$ARTIFACT_JSON")
[ -n "$GAME_FACTORY" ] || fail "DisputeGameFactoryProxy is missing from artifact: $ARTIFACT_JSON"

# ---------- Preflight: prestate hash (warning only; does not block startup) ----------
# In addition to participating in disputes, which requires the correct prestate to generate claims, the challenger
# performs prestate-independent operations such as resolving games and claiming bonds. This project currently uses
# the official beta3 op-program, whose computed state root for the custom CGT/Jovian chain differs from the on-chain
# absolute prestate. A real challenge therefore cannot succeed, but the challenger may still start to perform resolves.
# For this reason, a prestate mismatch produces a warning but does not exit.
EXPECTED_PRESTATE=$(jq -r '.faultGameAbsolutePrestate // empty' "$DEPLOY_CONFIG_PATH" 2>/dev/null || true)
if [ -f "$PRESTATE_PROOF" ] && [ -n "$EXPECTED_PRESTATE" ]; then
  ACTUAL_PRESTATE=$(jq -r '.pre // empty' "$PRESTATE_PROOF")
  if [ "$ACTUAL_PRESTATE" != "$EXPECTED_PRESTATE" ]; then
    echo "WARN: prestate hash mismatch! On-chain (deploy-config)=${EXPECTED_PRESTATE}, local=${ACTUAL_PRESTATE}."
    echo "      This prestate cannot participate in dispute games because the generated claim state root will not match."
    echo "      Operations such as resolve and claim bond are unaffected; startup will continue."
    echo "      To submit real challenges, rebuild the prestate with the op-program/cannon versions used for deployment, or redeploy the contracts with the new prestate."
  else
    echo "Prestate hash verified: ${ACTUAL_PRESTATE}"
  fi
else
  echo "WARN: Could not verify the prestate hash automatically (${PRESTATE_PROOF} is missing or deploy-config has no faultGameAbsolutePrestate)."
  echo "      Manually confirm that bin/prestate-proof.json .pre == ${EXPECTED_PRESTATE}"
fi

# ---------- Preflight: chain availability ----------
cast block-number --rpc-url "$L2_RPC_URL" >/dev/null 2>&1 \
  || fail "L2 RPC is unreachable: ${L2_RPC_URL} (run bash scripts/chain-start.sh first)"
cast rpc optimism_syncStatus --rpc-url "$OP_NODE_RPC_URL" >/dev/null 2>&1 \
  || fail "op-node RPC is unreachable: ${OP_NODE_RPC_URL} (op-node is not ready)"

# Challenger transaction private key.
# In permissioned mode (GAME_TYPE=1), the challenger address must match the challenger authorized at deployment:
#   PermissionedDisputeGame._challenger = deploy-config.l2OutputOracleChallenger (Deploy.s.sol).
# This project's config.sh sets that field to GS_ADMIN_ADDRESS. A different address causes an on-chain BadAuth revert.
# Therefore, permissioned mode defaults to GS_ADMIN_PRIVATE_KEY. Permissionless (cannon) mode has no authorization
# restriction and uses the default test private key. OP_CHALLENGER_PRIVATE_KEY can override either case.
if [ "$TRACE_TYPE" = "permissioned" ]; then
  CHALLENGER_KEY="${OP_CHALLENGER_PRIVATE_KEY:-$GS_ADMIN_PRIVATE_KEY}"
else
  CHALLENGER_KEY="${OP_CHALLENGER_PRIVATE_KEY:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
fi

# Permissioned-mode preflight: ensure the challenger's private-key address is authorized at deployment,
# avoiding a BadAuth failure on every operation after startup.
if [ "$TRACE_TYPE" = "permissioned" ]; then
  AUTH_CHALLENGER=$(jq -r '.l2OutputOracleChallenger // empty' "$DEPLOY_CONFIG_PATH" 2>/dev/null || true)
  MY_CHALLENGER=$(cast wallet address --private-key "$CHALLENGER_KEY" 2>/dev/null || true)
  if [ -n "$AUTH_CHALLENGER" ] && [ -n "$MY_CHALLENGER" ]; then
    if [ "$(printf '%s' "$AUTH_CHALLENGER" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$MY_CHALLENGER" | tr 'A-Z' 'a-z')" ]; then
      fail "Permissioned challenger address mismatch: authorized at deployment=${AUTH_CHALLENGER}, current private-key address=${MY_CHALLENGER}.
      PermissionedDisputeGame accepts only the authorized challenger; otherwise it reverts with BadAuth.
      Use the authorized private key (GS_ADMIN_PRIVATE_KEY by default in this project), or override it with OP_CHALLENGER_PRIVATE_KEY."
    fi
    echo "Permissioned challenger address verified: $MY_CHALLENGER"
  else
    echo "WARN: Could not verify the authorized challenger address (l2OutputOracleChallenger is missing from $DEPLOY_CONFIG_PATH, or cast is unavailable)."
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

# Create the datadir in advance. The challenger's periodic cleanup task runs ls on this directory and repeatedly logs
# "Unable to cleanup game data" if it does not exist. Resolve-only mode never writes cannon traces, so the directory
# would not otherwise be created automatically.
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
  echo "  op-challenger started in the background (pid $(cat "$BASE_PATH/data/pids/op-challenger.pid"))"
  echo "  Log: data/logs/op-challenger.log"
else
  exec op-challenger "${FLAGS[@]}"
fi
