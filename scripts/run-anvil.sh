#!/bin/bash

source .envrc

anvil --chain-id=$L1_CHAIN_ID --accounts=20 --block-time=$L1_BLOCK_TIME --load-state config/$DEPLOYMENT_CONTEXT.json
