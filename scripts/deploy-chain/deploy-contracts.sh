#!/bin/bash
set -euo pipefail

# Preserve values already set by chain-setup instead of overwriting them from .envrc
# (for example, local uses the localhost L1 and config/local).
_CALLER_L1_RPC="${L1_RPC_URL:-}"
_CALLER_DEPLOYMENT_CONTEXT="${DEPLOYMENT_CONTEXT:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"
if [ -n "$_CALLER_DEPLOYMENT_CONTEXT" ]; then
  export DEPLOYMENT_CONTEXT="$_CALLER_DEPLOYMENT_CONTEXT"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
  export DEPLOY_CONFIG_PATH="$CONTRACTS_BEDROCK_PATH/deploy-config/$DEPLOYMENT_CONTEXT.json"
fi

# Prefer system-installed Go binaries. A downloaded toolchain under ~/.local-go-toolchains
# can be blocked by macOS Family Controls and trigger an authorization dialog.
find_go() {
  local candidate path_go
  for candidate in /usr/local/go/bin/go /opt/homebrew/bin/go /usr/bin/go; do
    [ -x "$candidate" ] || continue
    if env -u GOROOT GOTOOLCHAIN=local "$candidate" version >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done

  path_go=$(command -v go 2>/dev/null || true)
  case "$path_go" in
    ""|*/.local-go-toolchains/*) ;;
    *)
      if env -u GOROOT GOTOOLCHAIN=local "$path_go" version >/dev/null 2>&1; then
        echo "$path_go"
        return 0
      fi
      ;;
  esac
  return 1
}

if ! GO_BIN=$(find_go); then
  echo "ERROR: no usable system Go toolchain found." >&2
  exit 1
fi
echo "Using Go: $GO_BIN ($(env -u GOROOT GOTOOLCHAIN=local "$GO_BIN" version))"

mkdir -p $DEPLOYMENT_CONFIG_PATH

# Build and deploy contracts.
cd $CONTRACTS_BEDROCK_PATH
# Remove lib dirs that often cause "unable to rmdir ... Directory not empty" on checkout;
# forge install below will reinstall the correct versions for this ref.
git checkout $OP_CONTRACTS_REF
echo "Cleaning Forge cache/artifacts for $OP_CONTRACTS_REF..."
forge clean

if [ "$OP_CONTRACTS_REF" = "op-contracts/v2.0.0-beta.3" ]; then
  DEPLOY_SCRIPT="scripts/deploy/Deploy.s.sol:Deploy"
else
  DEPLOY_SCRIPT="scripts/Deploy.s.sol:Deploy"
fi
echo "Using deploy script: $DEPLOY_SCRIPT"

# If using a custom gas token and address is not set, deploy it first.
# Mint 10000 HSK (custom gas token) to deployer address.
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"
if [ "${USE_CUSTOM_GAS_TOKEN}" = "true" ]; then
  if [ -n "$CUSTOM_GAS_TOKEN_ADDRESS" ] && [ "$CUSTOM_GAS_TOKEN_ADDRESS" != "$ZERO_ADDRESS" ]; then
    cgt_code=$(cast code "$CUSTOM_GAS_TOKEN_ADDRESS" --rpc-url "$L1_RPC_URL")
    if [ "$cgt_code" = "0x" ]; then
      echo "WARN: custom gas token $CUSTOM_GAS_TOKEN_ADDRESS has no code on $L1_RPC_URL; redeploying it."
      CUSTOM_GAS_TOKEN_ADDRESS=""
    fi
  fi

  if [ -z "$CUSTOM_GAS_TOKEN_ADDRESS" ] || [ "$CUSTOM_GAS_TOKEN_ADDRESS" = "$ZERO_ADDRESS" ]; then
    echo "Deploying custom gas token..."
    if ! deploy_result=$(forge create --json --rpc-url $L1_RPC_URL --private-key $DEPLOY_PRIVATE_KEY lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol:ERC20Mock --constructor-args "hashkeyToken" "HSK" $DEPLOY_ADDRESS 10000000000000000000000 2>&1); then
      echo "ERROR: failed to deploy custom gas token"
      echo "$deploy_result"
      exit 1
    fi
    CUSTOM_GAS_TOKEN_ADDRESS=$(echo $deploy_result | jq -r .deployedTo)
    echo "Custom gas token deployed at: $CUSTOM_GAS_TOKEN_ADDRESS"

    # Update .envrc with the new custom gas token address.
    sed -i '' "s/^export CUSTOM_GAS_TOKEN_ADDRESS=.*/export CUSTOM_GAS_TOKEN_ADDRESS=${CUSTOM_GAS_TOKEN_ADDRESS}/" $BASE_PATH/.envrc
  else
    echo "Using existing custom gas token at: $CUSTOM_GAS_TOKEN_ADDRESS"
  fi
fi

# Init deployment config.
sh scripts/getting-started/config.sh

# config.sh always writes configuration to deploy-config/getting-started.json.
# If the current context is not getting-started (for example, local), copy it to the corresponding filename;
# otherwise, jq and Deploy.s.sol below will look up <context>.json through $DEPLOY_CONFIG_PATH and fail.
if [ "$(basename "$DEPLOY_CONFIG_PATH")" != "getting-started.json" ]; then
  cp deploy-config/getting-started.json "$DEPLOY_CONFIG_PATH"
fi

# Add custom gas token and fault proofs config to deploy config
# respectedGameType: 0=CANNON (permissionless), 1=PERMISSIONED_CANNON (permissioned).
# This applies only to fault proofs and defaults to 1, starting new chains in permissioned mode
# in line with official production practice. Inject it in this script to avoid modifying the optimism
# submodule, which git checkout resets during deployment.
RESPECTED_GAME_TYPE="${RESPECTED_GAME_TYPE:-1}"
# faultGameGenesisOutputRoot: the initial AnchorStateRegistry anchor and starting point of the first dispute game.
# By default, use the same nonzero 0xdead...000 placeholder as the official op-deployer. Any nonzero value passes
# the AnchorRootNotFound check during game initialization, allowing the proposer to create its first game without
# seeding the anchor afterward. Once the first honest game resolves, tryUpdateAnchorState advances the anchor
# to the real root and retires the placeholder. To use the real genesis root, export FAULT_GAME_GENESIS_OUTPUT_ROOT
# to override this value (or restore 0 to let the script seed the anchor).
FAULT_GAME_GENESIS_OUTPUT_ROOT="${FAULT_GAME_GENESIS_OUTPUT_ROOT:-0xdead000000000000000000000000000000000000000000000000000000000000}"
echo "Adding custom gas token and fault proofs config..."
jq --arg use_cgt "$USE_CUSTOM_GAS_TOKEN" \
   --arg cgt_addr "$CUSTOM_GAS_TOKEN_ADDRESS" \
   --arg use_fp "$USE_FAULT_PROOFS" \
   --argjson rgt "$RESPECTED_GAME_TYPE" \
   --arg genesis_root "$FAULT_GAME_GENESIS_OUTPUT_ROOT" \
   '. + {
     "useCustomGasToken": ($use_cgt == "true"),
     "customGasTokenAddress": $cgt_addr,
     "useFaultProofs": ($use_fp == "true"),
     "respectedGameType": $rgt,
     "faultGameGenesisOutputRoot": $genesis_root
   }' $DEPLOY_CONFIG_PATH > tmp.json && mv tmp.json $DEPLOY_CONFIG_PATH

echo "Deploy config updated:"
echo "  - Custom gas token: $USE_CUSTOM_GAS_TOKEN"
echo "  - Custom gas token address: $CUSTOM_GAS_TOKEN_ADDRESS"
echo "  - Fault proofs: $USE_FAULT_PROOFS"
echo "  - Respected game type: $RESPECTED_GAME_TYPE ($([ "$RESPECTED_GAME_TYPE" = "1" ] && echo permissioned || echo permissionless))"
echo "  - Fault game genesis output root: $FAULT_GAME_GENESIS_OUTPUT_ROOT"

# Build and deploy contracts.
# forge install uses git clone/submodule internally, and long periods without Git output are normal.
echo "Installing Forge dependencies (may take 2-5 min, git may have little output)..."
forge install
echo "Dependencies OK. Building..."
forge build --silent
CURRENT_MAX_FEE_PER_GAS=$(cast to-dec "$(cast rpc eth_gasPrice --rpc-url "$L1_RPC_URL" | tr -d '"')")
CURRENT_PRIORITY_GAS_PRICE=$(cast to-dec "$(cast rpc eth_maxPriorityFeePerGas --rpc-url "$L1_RPC_URL" | tr -d '"')")
DEPLOY_GAS_MULTIPLIER="${DEPLOY_GAS_MULTIPLIER:-2}"
DEPLOY_PRIORITY_GAS_MULTIPLIER="${DEPLOY_PRIORITY_GAS_MULTIPLIER:-2}"
DEPLOY_MAX_FEE_PER_GAS="${DEPLOY_MAX_FEE_PER_GAS:-$((CURRENT_MAX_FEE_PER_GAS * DEPLOY_GAS_MULTIPLIER))}"
DEPLOY_PRIORITY_GAS_PRICE="${DEPLOY_PRIORITY_GAS_PRICE:-$((CURRENT_PRIORITY_GAS_PRICE * DEPLOY_PRIORITY_GAS_MULTIPLIER))}"

if echo "$L1_RPC_URL" | grep -qE 'localhost|127\.0\.0\.1'; then
  DEFAULT_DEPLOY_BATCH_SIZE=10
  DEFAULT_DEPLOY_SLOW=false
else
  DEFAULT_DEPLOY_BATCH_SIZE=1
  DEFAULT_DEPLOY_SLOW=true
fi
DEPLOY_BATCH_SIZE="${DEPLOY_BATCH_SIZE:-$DEFAULT_DEPLOY_BATCH_SIZE}"
DEPLOY_SLOW="${DEPLOY_SLOW:-$DEFAULT_DEPLOY_SLOW}"

echo "Using deployment gas fees:"
echo "  maxFeePerGas:         $DEPLOY_MAX_FEE_PER_GAS wei"
echo "  maxPriorityFeePerGas: $DEPLOY_PRIORITY_GAS_PRICE wei"
echo "  batchSize:            $DEPLOY_BATCH_SIZE"
echo "  slow:                 $DEPLOY_SLOW"

FORGE_SCRIPT_ARGS=(
  "$DEPLOY_SCRIPT"
  --private-key "$GS_ADMIN_PRIVATE_KEY"
  --broadcast
  --rpc-url "$L1_RPC_URL"
  --batch-size "$DEPLOY_BATCH_SIZE"
  --with-gas-price "$DEPLOY_MAX_FEE_PER_GAS"
  --priority-gas-price "$DEPLOY_PRIORITY_GAS_PRICE"
)
if [ "$DEPLOY_SLOW" = "true" ]; then
  FORGE_SCRIPT_ARGS+=(--slow)
fi
forge script "${FORGE_SCRIPT_ARGS[@]}"

# Create l2chain genesis state and load in file.
export CONTRACT_ADDRESSES_PATH=$DEPLOYMENT_OUTFILE
forge script scripts/L2Genesis.s.sol:L2Genesis --sig 'runWithStateDump()'

# Init rollup config and genesis file.
# Generate configuration with op-node from the submodule's current checkout
# ($OP_CONTRACTS_REF = op-contracts/v2.0.0-beta.2) because it recognizes CGT fields in deploy-config,
# such as customGasTokenAddress. Note that the generated rollup.json may contain fields not recognized
# by the runtime op-node (cgt-jovian/v1.16.5), such as da_challenge_contract_address; remove them manually
# from config/<context>/rollup.json before chain-start.
cd $BASE_PATH/optimism/op-node
env -u GOROOT GOTOOLCHAIN=local "$GO_BIN" run ./cmd genesis l2 \
  --deploy-config $DEPLOY_CONFIG_PATH \
  --l1-deployments $DEPLOYMENT_OUTFILE \
  --l2-allocs $STATE_DUMP_PATH \
  --l1-rpc $L1_RPC_URL \
  --outfile.l2 $OP_GETH_GENESIS_FILE \
  --outfile.rollup $OP_NODE_ROLLUP_FILE

# Copy the generated configs to the result path.
cp $DEPLOYMENT_OUTFILE $DEPLOYMENT_CONFIG_PATH
cp $STATE_DUMP_PATH $DEPLOYMENT_CONFIG_PATH
cp $OP_GETH_GENESIS_FILE $DEPLOYMENT_CONFIG_PATH
cp $OP_NODE_ROLLUP_FILE $DEPLOYMENT_CONFIG_PATH

echo "Deployment complete!"

cd $BASE_PATH
