#!/bin/bash
set -euo pipefail

# 若由 chain-setup 调用且已设置，不要被 .envrc 覆盖（如 local 用 localhost L1、config/local）
_CALLER_L1_RPC="${L1_RPC_URL:-}"
_CALLER_DEPLOYMENT_CONTEXT="${DEPLOYMENT_CONTEXT:-}"
source .envrc
[ -n "$_CALLER_L1_RPC" ] && export L1_RPC_URL="$_CALLER_L1_RPC"
if [ -n "$_CALLER_DEPLOYMENT_CONTEXT" ]; then
  export DEPLOYMENT_CONTEXT="$_CALLER_DEPLOYMENT_CONTEXT"
  export DEPLOYMENT_CONFIG_PATH="$BASE_PATH/config/$DEPLOYMENT_CONTEXT"
  export DEPLOY_CONFIG_PATH="$CONTRACTS_BEDROCK_PATH/deploy-config/$DEPLOYMENT_CONTEXT.json"
fi

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

# config.sh 固定把配置写到 deploy-config/getting-started.json；
# 若当前 context 不是 getting-started（如 local），复制成对应文件名，
# 否则下面的 jq 和 Deploy.s.sol 会按 $DEPLOY_CONFIG_PATH 找不到 <context>.json 而报错。
if [ "$(basename "$DEPLOY_CONFIG_PATH")" != "getting-started.json" ]; then
  cp deploy-config/getting-started.json "$DEPLOY_CONFIG_PATH"
fi

# Add custom gas token and fault proofs config to deploy config
# respectedGameType：0=CANNON(permissionless)，1=PERMISSIONED_CANNON(permissioned)。
# 仅 fault proofs 生效；缺省 1（新链按官方生产实践以 permissioned 起步）。
# 在此脚本层注入，避免改动 optimism 子模块（子模块在部署时会被 git checkout 重置）。
RESPECTED_GAME_TYPE="${RESPECTED_GAME_TYPE:-1}"
# faultGameGenesisOutputRoot：AnchorStateRegistry 的初始 anchor（第一个 dispute game 的博弈起点）。
# 缺省用官方 op-deployer 同款非零占位 0xdead…000：只要非零就能过 game 初始化的
# AnchorRootNotFound 检查，proposer 首次即可建 game，无需事后种 anchor。
# 第一个诚实 game 解决后，anchor 会经 tryUpdateAnchorState 前移为真实 root，占位退役。
# 想用真实创世 root，可导出 FAULT_GAME_GENESIS_OUTPUT_ROOT 覆盖（或改回 0 走脚本种 anchor）。
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
# forge install 内部用 git clone/submodule，git 经常长时间无输出，属正常现象
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
# 用 submodule 当前 checkout（$OP_CONTRACTS_REF = op-contracts/v2.0.0-beta.2）的 op-node 生成配置，
# 因为它认识 deploy-config 里的 CGT 字段（customGasTokenAddress 等）。
# 注意：生成的 rollup.json 可能含“启动用的 op-node（cgt-jovian/v1.16.5）”不认识的字段
# （如 da_challenge_contract_address），需在 chain-start 前手动从 config/<context>/rollup.json 删除。
cd $BASE_PATH/optimism/op-node
go run ./cmd genesis l2 \
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
