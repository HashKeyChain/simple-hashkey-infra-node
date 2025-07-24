#!/bin/bash

source .envrc

cd $OP_NODE_PATH
git checkout v1.13.2
go run cmd/main.go genesis l2 \
--deploy-config $DEPLOY_CONFIG_PATH \
--l1-deployments $DEPLOYMENT_OUTFILE \
--l2-allocs $STATE_DUMP_PATH \
--l1-rpc $L1_RPC_URL \
--outfile.l2 $OP_GETH_GENESIS_FILE \
--outfile.rollup $OP_NODE_ROLLUP_FILE

cd $BASE_PATH