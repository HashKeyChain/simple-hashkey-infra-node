#!/bin/bash

source .envrc

# sh scripts/balance-withdraw.sh init <balance>
# sh scripts/balance-withdraw.sh prove <tx_hash>
# sh scripts/balance-withdraw.sh finalize <tx_hash>
if [ "$1" = "init" ]; then
  init_flags="init --l2=$L2_RPC_URL --private-key=$DEPLOY_PRIVATE_KEY --value=$2 --num-confirmations=1"
  echo "op-withdrawal $init_flags"
  result=$(op-withdrawal $init_flags)
  tx_hash=$(echo $result | grep -o 'tx=0x[0-9a-fA-F]\+' | head -n1 | sed 's/tx=//')
  echo "Withdrawal tx hash: $tx_hash"
elif [ "$1" = "prove" ]; then
  prove_flags="prove --l1=$L1_RPC_URL --l2=$L2_RPC_URL --private-key=$DEPLOY_PRIVATE_KEY --tx $2 --portal-address=$(jq -r .OptimismPortalProxy $DEPLOYMENT_OUTFILE)"
  echo "op-withdrawal $prove_flags"
  op-withdrawal $prove_flags
elif [ "$1" = "finalize" ]; then
    finalize_flags="finalize --l1=$L1_RPC_URL --l2=$L2_RPC_URL --private-key=$DEPLOY_PRIVATE_KEY --tx $2 --portal-address=$(jq -r .OptimismPortalProxy $DEPLOYMENT_OUTFILE)"
    echo "op-withdrawal $finalize_flags"
    op-withdrawal $finalize_flags
fi

