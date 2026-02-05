import 'default.just'

# Updates git submodules
submodules:
    git submodule update --init --recursive

# Builds Docker images for Go components using buildx
docker: submodules
    OP_GETH_REF=latest \
    OP_NODE_REF=latest \
    OP_BATCHER_REF=latest \
    OP_PROPOSER_REF=latest \
    OP_CHALLENGER_REF=latest \
    OP_DEPLOYER_REF=latest \
    docker buildx bake \
    		--progress plain \
    		--load \
    		-f docker-bake.hcl \
    		op-node op-batcher op-proposer op-challenger op-deployer op-geth
