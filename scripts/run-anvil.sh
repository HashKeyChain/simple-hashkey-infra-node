#!/bin/bash

source .envrc

# --host=0.0.0.0
# TODO: Due to a bug in Foundry, we temporarily use anvil by docker container.
docker run --rm -it -p 8545:8545 --entrypoint anvil ghcr.io/foundry-rs/foundry:v1.2.3 --chain-id=$L1_CHAIN_ID --accounts=20 --host=0.0.0.0
