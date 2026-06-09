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
rm -rf lib/openzeppelin-contracts-v5 lib/solady-v0.0.245 lib/superchain-registry 2>/dev/null || true
git checkout $OP_CONTRACTS_REF

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
    deploy_result=$(forge create --broadcast --json --rpc-url $L1_RPC_URL --private-key $DEPLOY_PRIVATE_KEY lib/openzeppelin-contracts/contracts/mocks/ERC20Mock.sol:ERC20Mock --constructor-args "hashkeyToken" "HSK" $DEPLOY_ADDRESS 10000000000000000000000)
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
echo "Adding custom gas token and fault proofs config..."
jq --arg use_cgt "$USE_CUSTOM_GAS_TOKEN" \
   --arg cgt_addr "$CUSTOM_GAS_TOKEN_ADDRESS" \
   --arg use_fp "$USE_FAULT_PROOFS" \
   '. + {
     "useCustomGasToken": ($use_cgt == "true"),
     "customGasTokenAddress": $cgt_addr,
     "useFaultProofs": ($use_fp == "true")
   }' $DEPLOY_CONFIG_PATH > tmp.json && mv tmp.json $DEPLOY_CONFIG_PATH

echo "Deploy config updated:"
echo "  - Custom gas token: $USE_CUSTOM_GAS_TOKEN"
echo "  - Custom gas token address: $CUSTOM_GAS_TOKEN_ADDRESS"
echo "  - Fault proofs: $USE_FAULT_PROOFS"

# Build and deploy contracts.
# forge install 内部用 git clone/submodule，git 经常长时间无输出，属正常现象
echo "Installing Forge dependencies (may take 2-5 min, git may have little output)..."
forge install
echo "Dependencies OK. Building..."
forge build --silent
# --slow removed for faster batch deployment
forge script scripts/Deploy.s.sol:Deploy --private-key $GS_ADMIN_PRIVATE_KEY --broadcast --rpc-url $L1_RPC_URL --batch-size 10

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
