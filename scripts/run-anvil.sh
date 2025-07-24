#!/bin/bash

source .envrc

anvil --chain-id=$L1_CHAIN_ID --block-time=$L1_BLOCK_TIME --accounts=20
