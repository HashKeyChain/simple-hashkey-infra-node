#!/bin/bash

source .envrc

# --block-time sets block interval in seconds, omit for automine
docker run --rm -it -p 8545:8545 --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.3.2 --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0 --slots-in-an-epoch=1 --block-time 1
