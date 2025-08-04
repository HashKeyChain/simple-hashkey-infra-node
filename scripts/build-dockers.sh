#!/bin/bash

source .envrc

echo "Building Verse Docker images with branches: $HK_GETH_BRANCH and $HK_VERSE_BRANCH"

# Empty("") value depends on current machine's platform.
export PLATFORMS="linux/amd64"
echo "PLATFORMS: $PLATFORMS"

# checkout to the target branches.
cd verse-geth && git checkout $HK_GETH_BRANCH && cd -
cd verse && git checkout $HK_VERSE_BRANCH && cd -

export HK_GETH_COMMIT=$(git log -1 --format=%H -- verse-geth)
export HK_VERSE_COMMIT=$(git log -1 --format=%H -- verse)
export HK_VERSE_DATE=$(git log -1 --format=%cd --date=iso-strict -- verse | tr ' ' '_')

echo "HK_VERSE_BRANCH: $HK_VERSE_BRANCH"
echo "HK_VERSE_COMMIT: $HK_VERSE_COMMIT"
echo "HK_VERSE_DATE: $HK_VERSE_DATE"

# Build images and push.
docker buildx bake \
  --progress plain \
  --debug \
	-f docker-bake.hcl \
	verse-node verse-batcher verse-proposer verse-challenger verse-deployer verse-geth verse-cannon

# revert branches.
cd verse-geth && git checkout develop && cd -
cd verse && git checkout develop && cd -
