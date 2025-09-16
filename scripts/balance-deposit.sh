#!/bin/bash

source .envrc

# Deposit 10 ETH to L2 chain.
# sh scripts/balance-deposit.sh <balance>
if [ "$USE_CUSTOM_GAS_TOKEN" = "false" ]; then
  cast send --rpc-url $L1_RPC_URL --private-key $DEPLOY_PRIVATE_KEY $(jq -r .L1StandardBridgeProxy $DEPLOYMENT_OUTFILE) "depositETH(uint32,bytes)" 50000 0x --value $1
else
  # TODO: Need to fill the custom gas token deposit case.
  echo "This case need to call depositERC20 method in L1StandardBridge contract."
fi