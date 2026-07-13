#!/bin/bash
#
# Deploy an OP Stack chain via op-deployer (v6.0.0 contracts + alt-DA).
# Replaces the legacy `forge script Deploy.s.sol` flow that no longer works on v6+.
#
# All parameters come from .envrc:
#   L1_CHAIN_ID, L2_CHAIN_ID, L1_RPC_URL
#   GS_ADMIN_ADDRESS, GS_ADMIN_PRIVATE_KEY
#   GS_BATCHER_ADDRESS, GS_PROPOSER_ADDRESS, GS_SEQUENCER_ADDRESS
#   USE_ALT_DA, ALT_DA_COMMITMENT_TYPE, ALT_DA_CHALLENGE_WINDOW, ALT_DA_RESOLVE_WINDOW
#
# Usage:
#   bash scripts/deploy-with-deployer.sh build     # build op-deployer binary (~10 min)
#   bash scripts/deploy-with-deployer.sh init      # generate intent.toml from .envrc
#   bash scripts/deploy-with-deployer.sh noop      # dry-run, no L1 tx
#   bash scripts/deploy-with-deployer.sh live      # send real L1 tx (will prompt confirmation)
#   bash scripts/deploy-with-deployer.sh export    # export genesis / rollup / l1-addresses
#   bash scripts/deploy-with-deployer.sh all       # init -> noop -> live -> export
#   bash scripts/deploy-with-deployer.sh clean     # remove deployer-workdir/
#
# Optional env overrides:
#   WORKDIR=...        directory holding intent.toml + state.json (default: deployer-workdir)
#   CONFIG_DIR=...     output dir for genesis/rollup/l1-addresses (default: config/local)
#   FORCE_INIT=1       overwrite existing intent.toml even if present
#   FORCE_BUILD=1      rebuild op-deployer even if bin/op-deployer already exists
#   SKIP_CONFIRM=1     skip the "are you sure" prompt before live deploy
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

WORKDIR="${WORKDIR:-$BASE_PATH/deployer-workdir}"
# CONFIG_DIR defaults to .envrc's DEPLOYMENT_CONFIG_PATH (so chain-start.sh server
# finds the configs without further changes). Falls back to config/local.
# Special case: if L1_RPC_URL points to localhost (= deploying against local anvil),
# force CONFIG_DIR=config/local because chain-start.sh local hardcodes that path.
CONFIG_DIR="${CONFIG_DIR:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/local}}"
if echo "${L1_RPC_URL:-}" | grep -qE 'localhost|127\.0\.0\.1'; then
  CONFIG_DIR="$BASE_PATH/config/local"
fi
OP_DEPLOYER_BIN="$BASE_PATH/bin/op-deployer"
LOG_DIR="$BASE_PATH/data/logs"
mkdir -p "$LOG_DIR"

CMD="${1:-help}"

# ============================================================================
# Helpers
# ============================================================================

_die() { echo "Error: $*" >&2; exit 1; }

_require_bin() {
  [ -x "$OP_DEPLOYER_BIN" ] || _die "op-deployer binary not found at $OP_DEPLOYER_BIN. Run: bash scripts/deploy-with-deployer.sh build"
}

_require_envrc_vars() {
  for v in L1_CHAIN_ID L2_CHAIN_ID L1_RPC_URL \
           GS_ADMIN_ADDRESS GS_ADMIN_PRIVATE_KEY \
           GS_BATCHER_ADDRESS GS_PROPOSER_ADDRESS GS_SEQUENCER_ADDRESS; do
    [ -n "${!v}" ] || _die "$v is not set in .envrc"
  done
}

_l2_chain_id_hex() {
  printf '0x%064x' "$L2_CHAIN_ID"
}

# ============================================================================
# build: build op-deployer binary with embedded artifacts
# ============================================================================

cmd_build() {
  if [ -x "$OP_DEPLOYER_BIN" ] && [ "${FORCE_BUILD:-0}" != "1" ]; then
    local size; size=$(ls -lh "$OP_DEPLOYER_BIN" | awk '{print $5}')
    echo "op-deployer already exists at $OP_DEPLOYER_BIN ($size)."
    echo "Use FORCE_BUILD=1 to rebuild."
    return 0
  fi

  command -v just >/dev/null 2>&1 || _die "'just' command not found. Install: brew install just"

  echo "==> Patching foundry.toml: deny_warnings = true -> false"
  echo "    (newer forge versions emit extra deprecation warnings that didn't exist when v6.0.0 was tagged)"
  local TOML="$BASE_PATH/optimism/packages/contracts-bedrock/foundry.toml"
  if grep -qE '^\s*deny_warnings\s*=\s*true' "$TOML"; then
    sed -i.bak -E 's/^(\s*)deny_warnings\s*=\s*true/\1deny_warnings = false/' "$TOML"
    rm -f "$TOML.bak"
    echo "    Patched."
  else
    echo "    Already patched (or not present)."
  fi

  echo "==> Building op-deployer (just build): forge build + mktar artifacts + go build (~5-10 min)"
  cd "$BASE_PATH/optimism/op-deployer"
  just build 2>&1 | tee "$LOG_DIR/deployer-build.log"
  cd "$BASE_PATH"

  cp "$BASE_PATH/optimism/op-deployer/bin/op-deployer" "$OP_DEPLOYER_BIN"
  local size; size=$(ls -lh "$OP_DEPLOYER_BIN" | awk '{print $5}')
  echo "==> Done. $OP_DEPLOYER_BIN ($size)"
  if [ "$size" \< "100M" ] && [[ ! "$size" == *G* ]]; then
    echo "    WARNING: binary is $size, expected 100M+ (with embedded artifacts)."
    echo "    just build may have skipped the mktar step. Check $LOG_DIR/deployer-build.log"
  fi
}

# ============================================================================
# init: generate intent.toml from .envrc (and a fresh empty state.json)
# ============================================================================

cmd_init() {
  _require_bin
  _require_envrc_vars

  if [ -f "$WORKDIR/intent.toml" ] && [ "${FORCE_INIT:-0}" != "1" ]; then
    echo "intent.toml already exists at $WORKDIR/intent.toml. Use FORCE_INIT=1 to overwrite."
    return 0
  fi

  if [ -f "$WORKDIR/intent.toml" ]; then
    cp "$WORKDIR/intent.toml" "$WORKDIR/intent.toml.bak.$(date +%s)"
    echo "==> Backed up existing intent.toml"
  fi

  mkdir -p "$WORKDIR"

  echo "==> Generating empty intent + state via op-deployer init (will be overwritten next)"
  "$OP_DEPLOYER_BIN" init \
    --l1-chain-id "$L1_CHAIN_ID" \
    --l2-chain-ids "$L2_CHAIN_ID" \
    --workdir "$WORKDIR" \
    --intent-type custom \
    > /dev/null

  local L2_HEX; L2_HEX=$(_l2_chain_id_hex)
  local USE_ALT_DA_BOOL="${USE_ALT_DA:-false}"
  local ALT_DA_TYPE="${ALT_DA_COMMITMENT_TYPE:-GenericCommitment}"
  local ALT_DA_CW="${ALT_DA_CHALLENGE_WINDOW:-16}"
  local ALT_DA_RW="${ALT_DA_RESOLVE_WINDOW:-16}"

  # sequencerWindowSize: how many L1 blocks the batcher has to land each batch.
  # Default is 3600 (designed for L1 block_time=12s = 12h). On a fast L1 (HSK testnet
  # 2s), 3600 only gives 2 hours, which is too tight for fast L2s (block_time=1).
  # Override default to 14400 (8 hours on a 2s L1) to give batcher comfortable margin.
  # Larger values trade off slower user withdrawal finality.
  SEQ_WINDOW_SIZE="${SEQ_WINDOW_SIZE:-14400}"

  echo "==> Writing intent.toml from .envrc:"
  echo "    L1: chain $L1_CHAIN_ID @ $L1_RPC_URL"
  echo "    L2: chain $L2_CHAIN_ID ($L2_HEX)"
  echo "    Admin/Owner: $GS_ADMIN_ADDRESS"
  echo "    Sequencer:   $GS_SEQUENCER_ADDRESS"
  echo "    Batcher:     $GS_BATCHER_ADDRESS"
  echo "    Proposer:    $GS_PROPOSER_ADDRESS"
  echo "    Alt-DA:      useAltDA=$USE_ALT_DA_BOOL, type=$ALT_DA_TYPE"
  echo "    SeqWindow:   $SEQ_WINDOW_SIZE L1 blocks ($((SEQ_WINDOW_SIZE * 2 / 3600))h on 2s L1)"

  cat > "$WORKDIR/intent.toml" <<EOF
# Generated by scripts/deploy-with-deployer.sh from .envrc on $(date)
configType = "custom"
opDeployerVersion = "untagged"
l1ChainID = $L1_CHAIN_ID
fundDevAccounts = false
l1ContractsLocator = "embedded"
l2ContractsLocator = "embedded"

# Global L2 deploy-config overrides. Use this to tune sequence window, L2 block
# time etc. without having to fork op-deployer. See genesis.DeployConfig for
# the full field list.
[globalDeployOverrides]
  sequencerWindowSize = $SEQ_WINDOW_SIZE
  l2BlockTime = $L2_BLOCK_TIME

# Superchain-level roles. For non-standard L1s (HSK testnet, devnet, etc.), there
# is no pre-existing superchain infrastructure, so op-deployer will deploy
# SuperchainConfig + ProtocolVersions + OPCM as part of \`apply\`. All four roles
# point to the admin EOA for now; rotate to multisig before mainnet.
[superchainRoles]
  SuperchainProxyAdminOwner = "$GS_ADMIN_ADDRESS"
  SuperchainGuardian        = "$GS_ADMIN_ADDRESS"
  ProtocolVersionsOwner     = "$GS_ADMIN_ADDRESS"
  Challenger                = "$GS_ADMIN_ADDRESS"

[[chains]]
  # L2 chain ID padded to 32-byte hash.
  id = "$L2_HEX"

  # Vault recipients & operator role addresses (dev: all admin EOA).
  baseFeeVaultRecipient      = "$GS_ADMIN_ADDRESS"
  l1FeeVaultRecipient        = "$GS_ADMIN_ADDRESS"
  sequencerFeeVaultRecipient = "$GS_ADMIN_ADDRESS"
  operatorFeeVaultRecipient  = "$GS_ADMIN_ADDRESS"
  chainFeesRecipient         = "$GS_ADMIN_ADDRESS"

  # Standard OP Stack EIP-1559 / gas parameters.
  eip1559DenominatorCanyon = 250
  eip1559Denominator       = 50
  eip1559Elasticity        = 6
  gasLimit                 = 30000000

  # Optional fee knobs left at 0 (defaults).
  operatorFeeScalar    = 0
  operatorFeeConstant  = 0
  minBaseFee           = 0
  daFootprintGasScalar = 0

  # On-chain role addresses. The private keys in .envrc must derive
  # to these same addresses, otherwise op-batcher/op-proposer signed
  # transactions will be rejected.
  [chains.roles]
    l1ProxyAdminOwner = "$GS_ADMIN_ADDRESS"
    l2ProxyAdminOwner = "$GS_ADMIN_ADDRESS"
    systemConfigOwner = "$GS_ADMIN_ADDRESS"
    unsafeBlockSigner = "$GS_SEQUENCER_ADDRESS"
    batcher           = "$GS_BATCHER_ADDRESS"
    proposer          = "$GS_PROPOSER_ADDRESS"
    challenger        = "$GS_ADMIN_ADDRESS"

  # Custom Gas Token v2 — disabled by default (L2 uses ETH for gas).
  # To enable, set non-empty name + symbol; LiquidityControllerOwner defaults to L2ProxyAdminOwner.
  [chains.customGasToken]
    name                     = ""
    symbol                   = ""
    liquidityControllerOwner = "0x0000000000000000000000000000000000000000"

  # Alt-DA (Celestia / generic). The "dangerous" prefix is op-deployer's convention because
  # alt-DA bypasses L1 calldata; it does not mean unsafe per se.
  # GenericCommitment mode does not enforce challenge/resolve windows on-chain;
  # values here are nominal but must be > 0 (op-node validates).
  [chains.dangerousAltDAConfig]
    useAltDA                   = $USE_ALT_DA_BOOL
    daCommitmentType           = "$ALT_DA_TYPE"
    daChallengeWindow          = $ALT_DA_CW
    daResolveWindow            = $ALT_DA_RW
    daBondSize                 = 0
    daResolverRefundPercentage = 0
EOF

  echo "==> Done: $WORKDIR/intent.toml ($(wc -l < $WORKDIR/intent.toml) lines)"
}

# ============================================================================
# noop: dry-run validation (no L1 tx)
# ============================================================================

cmd_noop() {
  _require_bin
  [ -f "$WORKDIR/intent.toml" ] || _die "intent.toml missing. Run: bash scripts/deploy-with-deployer.sh init"

  echo "==> op-deployer apply --deployment-target noop (dry-run, no L1 tx)"
  local LOGFILE="$LOG_DIR/deployer-noop.log"
  "$OP_DEPLOYER_BIN" apply \
    --workdir "$WORKDIR" \
    --deployment-target noop \
    --l1-rpc-url "$L1_RPC_URL" \
    > "$LOGFILE" 2>&1
  local EXITCODE=$?

  echo "==> noop exit: $EXITCODE  (log: $LOGFILE)"
  echo ""
  if [ $EXITCODE -ne 0 ] || grep -q 'Application failed' "$LOGFILE"; then
    echo "==== FAILED — last 30 lines ===="
    tail -30 "$LOGFILE"
    return 1
  fi

  echo "==== noop SUCCEEDED — pipeline summary ===="
  jq '{
    appliedIntent: (.appliedIntent != null),
    superchainContracts: (.superchainContracts != null),
    implementationsDeployment: (.implementationsDeployment != null),
    opChainDeployments: (.opChainDeployments | length)
  }' "$WORKDIR/state.json"
}

# ============================================================================
# live: real deployment to L1
# ============================================================================

cmd_live() {
  _require_bin
  _require_envrc_vars
  [ -f "$WORKDIR/intent.toml" ] || _die "intent.toml missing. Run: bash scripts/deploy-with-deployer.sh init"

  echo "================================================================="
  echo " WARNING: This will send REAL L1 transactions and consume ETH."
  echo ""
  echo "   From admin: $GS_ADMIN_ADDRESS"
  echo "   To L1 RPC:  $L1_RPC_URL (chain ID $L1_CHAIN_ID)"
  echo "   For L2:     chain ID $L2_CHAIN_ID"
  echo "================================================================="

  # Check admin balance
  local BAL_HEX
  BAL_HEX=$(curl -sf -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBalance\",\"params\":[\"$GS_ADMIN_ADDRESS\",\"latest\"],\"id\":1}" \
    "$L1_RPC_URL" 2>/dev/null | jq -r '.result // "0x0"')
  local BAL_DEC
  BAL_DEC=$(python3 -c "print(int('$BAL_HEX', 16) / 1e18)" 2>/dev/null || echo "?")
  echo " Admin balance: $BAL_DEC ETH (need ~0.5+ ETH on HSK testnet)"
  echo ""

  if [ "${SKIP_CONFIRM:-0}" != "1" ]; then
    read -p "Proceed with live deployment? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && _die "Aborted by user."
  fi

  # Backup state.json before live (so we can roll back if needed)
  if [ -f "$WORKDIR/state.json" ]; then
    cp "$WORKDIR/state.json" "$WORKDIR/state.json.preLive.$(date +%s).bak"
  fi

  # Critical fix: op-deployer's `noop` mode pollutes state.json with
  # appliedIntent=true (it does a full simulation but writes results back).
  # If we then run `live` against the same state.json, op-deployer thinks
  # the deployment is already applied and silently skips, producing zero
  # L1 transactions. Reset state.json before live, while preserving intent.toml.
  local APPLIED
  APPLIED=$(jq -r '.appliedIntent // null' "$WORKDIR/state.json" 2>/dev/null)
  if [ "$APPLIED" != "null" ] && [ -n "$APPLIED" ]; then
    echo "==> state.json shows appliedIntent != null (likely from a previous noop)."
    echo "    Resetting state.json so op-deployer actually deploys this time."
    cp "$WORKDIR/intent.toml" "$WORKDIR/intent.toml.preLiveReset.bak"
    "$OP_DEPLOYER_BIN" init \
      --l1-chain-id "$L1_CHAIN_ID" \
      --l2-chain-ids "$L2_CHAIN_ID" \
      --workdir "$WORKDIR" \
      --intent-type custom \
      > /dev/null 2>&1
    # init overwrites intent.toml with empty template — restore our edited version
    mv "$WORKDIR/intent.toml.preLiveReset.bak" "$WORKDIR/intent.toml"
  fi

  export DEPLOYER_PRIVATE_KEY="$GS_ADMIN_PRIVATE_KEY"

  echo "==> op-deployer apply --deployment-target live (sends real L1 tx)"
  local LOGFILE="$LOG_DIR/deployer-live.log"
  "$OP_DEPLOYER_BIN" apply \
    --workdir "$WORKDIR" \
    --deployment-target live \
    --l1-rpc-url "$L1_RPC_URL" \
    > "$LOGFILE" 2>&1
  local EXITCODE=$?

  echo "==> live exit: $EXITCODE  (log: $LOGFILE)"
  if [ $EXITCODE -ne 0 ] || grep -q 'Application failed' "$LOGFILE"; then
    echo "==== FAILED — last 50 lines ===="
    tail -50 "$LOGFILE"
    return 1
  fi

  local TX_COUNT
  # op-deployer logs both "transaction broadcasted" (lower) and
  # "Transaction confirmed" (capital). Count the latter.
  TX_COUNT=$(grep -ci 'transaction confirmed' "$LOGFILE" 2>/dev/null || echo 0)
  echo "==== live SUCCEEDED — $TX_COUNT 'Transaction confirmed' lines in log ===="
  if [ "$TX_COUNT" = "0" ]; then
    echo "    WARNING: 0 confirmed transactions detected. op-deployer may have"
    echo "    skipped deployment (e.g. state.json says it's already applied)."
    echo "    Try: rm -rf $WORKDIR && bash $0 init && bash $0 live"
  fi

  # Show first deployed contract address as sanity check
  local SC_ADDR
  SC_ADDR=$(jq -r '.opChainDeployments[0].systemConfigProxyAddress // empty' "$WORKDIR/state.json" 2>/dev/null)
  if [ -n "$SC_ADDR" ]; then
    echo "  SystemConfigProxy: $SC_ADDR"
  fi
}

# ============================================================================
# export: dump genesis.json / rollup.json / l1-addresses.json
# ============================================================================

cmd_export() {
  _require_bin
  _require_envrc_vars
  [ -f "$WORKDIR/state.json" ] || _die "state.json missing. Run live deploy first."

  mkdir -p "$CONFIG_DIR"
  echo "==> Exporting configs to $CONFIG_DIR/"

  "$OP_DEPLOYER_BIN" inspect genesis --workdir "$WORKDIR" "$L2_CHAIN_ID" > "$CONFIG_DIR/genesis.json"
  echo "  -> genesis.json       ($(wc -l < $CONFIG_DIR/genesis.json) lines)"

  "$OP_DEPLOYER_BIN" inspect rollup --workdir "$WORKDIR" "$L2_CHAIN_ID" > "$CONFIG_DIR/rollup.json"
  echo "  -> rollup.json        ($(wc -l < $CONFIG_DIR/rollup.json) lines)"

  "$OP_DEPLOYER_BIN" inspect l1 --workdir "$WORKDIR" "$L2_CHAIN_ID" > "$CONFIG_DIR/l1-addresses.json"
  echo "  -> l1-addresses.json  ($(wc -l < $CONFIG_DIR/l1-addresses.json) lines)"

  # Alias for chain-start.sh which still reads from $DEPLOYMENT_OUTFILE
  # (defined in .envrc as $CONFIG_DIR/artifact.json). Same JSON schema.
  cp "$CONFIG_DIR/l1-addresses.json" "$CONFIG_DIR/artifact.json"
  echo "  -> artifact.json      (alias of l1-addresses.json for chain-start.sh)"

  # v1.16.5+ op-node requires a geth-style L1 genesis JSON for non-standard L1s
  # (the format wraps chainspec in a top-level "config" key). Write a minimal one
  # assuming all forks are active at L1 genesis.
  cat > "$CONFIG_DIR/l1-chain-config.json" <<EOF
{
  "config": {
    "chainId": $L1_CHAIN_ID,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "muirGlacierBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "mergeNetsplitBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "terminalTotalDifficulty": 0,
    "blobSchedule": {
      "cancun": {
        "target": 3,
        "max": 6,
        "baseFeeUpdateFraction": 3338477
      },
      "prague": {
        "target": 6,
        "max": 9,
        "baseFeeUpdateFraction": 5007716
      }
    }
  }
}
EOF
  echo "  -> l1-chain-config.json (geth-style L1 genesis JSON, all forks active at genesis)"

  echo ""
  echo "=== rollup.json sanity check ==="
  jq '{block_time, l1_chain_id, l2_chain_id, batch_inbox_address, l1_system_config_address, alt_da: (.alt_da // "(no alt-DA)")}' "$CONFIG_DIR/rollup.json"
}

# ============================================================================
# clean: remove deployer-workdir
# ============================================================================

cmd_clean() {
  if [ -d "$WORKDIR" ]; then
    echo "Removing $WORKDIR"
    rm -rf "$WORKDIR"
  fi
}

# ============================================================================
# Main dispatch
# ============================================================================

case "$CMD" in
  build)
    cmd_build
    ;;
  init)
    cmd_init
    ;;
  noop)
    cmd_noop
    ;;
  live)
    cmd_live
    ;;
  export)
    cmd_export
    ;;
  all)
    [ -x "$OP_DEPLOYER_BIN" ] || cmd_build
    cmd_init
    # NOTE: skip cmd_noop here. op-deployer's noop pollutes state.json
    # with appliedIntent=true, which makes the subsequent live run silently
    # skip deployment. Run noop manually for validation if needed.
    cmd_live
    cmd_export
    ;;
  clean)
    cmd_clean
    ;;
  help|--help|-h|"")
    sed -n '2,30p' "$0" | sed 's/^#//'
    ;;
  *)
    echo "Unknown subcommand: $CMD"
    echo "Run: bash scripts/deploy-with-deployer.sh help"
    exit 1
    ;;
esac
