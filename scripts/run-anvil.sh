#!/bin/bash

source .envrc

# --block-time sets block interval in seconds, omit for automine
echo "Starting anvil with block time ${L1_BLOCK_TIME}s..."
# 端口发布限制在宿主回环；容器内 --host=0.0.0.0 必须保留（理由见 chain-start.sh）。
docker run --rm -it -p 127.0.0.1:8545:8545 --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 --slots-in-an-epoch=1 --block-time $L1_BLOCK_TIME
