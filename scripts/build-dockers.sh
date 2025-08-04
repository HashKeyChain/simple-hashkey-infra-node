#!/bin/bash

source .envrc

echo "Building Verse Docker images with branches: $HK_GETH_BRANCH and $HK_VERSE_BRANCH"

# Empty("") value depends on current machine's platform.
export PLATFORMS="linux/amd64,linux/arm64,linux/riscv64"
echo "PLATFORMS: $PLATFORMS"

# checkout to the target branches.
cd verse-geth && git checkout $HK_GETH_BRANCH && cd -
cd verse && git checkout $HK_VERSE_BRANCH && cd -

export HK_GETH_COMMIT=$(git log -1 --format=%H -- verse-geth)
export HK_GETH_DATE=$(git log -1 --format=%cd --date=iso -- verse-geth)

export HK_VERSE_COMMIT=$(git log -1 --format=%H -- verse)
export HK_VERSE_DATE=$(git log -1 --format=%cd --date=iso -- verse)

echo "HK_VERSE_BRANCH: $HK_VERSE_BRANCH"
echo "HK_VERSE_COMMIT: $HK_VERSE_COMMIT"
echo "HK_VERSE_DATE: $HK_VERSE_DATE"

echo "HK_GETH_BRANCH: $HK_GETH_BRANCH"
echo "HK_GETH_COMMIT: $HK_GETH_COMMIT"
echo "HK_GETH_DATE: $HK_GETH_DATE"

# Build images and push.
HK_GETH_BRANCH=$HK_GETH_BRANCH \
HK_GETH_COMMIT=$HK_GETH_COMMIT \
HK_GETH_DATE=$HK_GETH_DATE \
HK_VERSE_BRANCH=$HK_VERSE_BRANCH \
HK_VERSE_COMMIT=$HK_VERSE_COMMIT \
HK_VERSE_DATE=$HK_VERSE_DATE \
PLATFORMS=$PLATFORMS \
  docker buildx bake \
  --progress plain \
  --push \
	-f docker-bake.hcl \
	verse-node

# revert branches.
cd verse-geth && git checkout develop && cd -
cd verse && git checkout develop && cd -
