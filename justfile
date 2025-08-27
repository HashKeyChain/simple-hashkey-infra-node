import 'default.just'

# Updates git submodules
submodules:
    git submodule update --init --recursive

# Builds Docker images for Go components using buildx
docker: submodules
    HK_GETH_BRANCH=latest \
    HK_VERSE_BRANCH=latest \
    docker buildx bake \
    		--progress plain \
    		--load \
    		-f docker-bake.hcl \
    		verse-node verse-batcher verse-proposer verse-challenger verse-deployer verse-geth
