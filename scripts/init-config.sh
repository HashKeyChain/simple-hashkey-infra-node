#!/bin/bash

source .envrc

# Create accounts and configs
cd $CONTRACTS_BEDROCK_PATH
git checkout $HK_VERSE_BRANCH
sh scripts/getting-started/config.sh

git checkout develop && cd $BASE_PATH