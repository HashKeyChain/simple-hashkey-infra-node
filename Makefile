

docker: ## Builds Docker images for Go components using buildx
	# We don't use a buildx builder here, and just load directly into regular docker, for convenience.
	REGISTRY="" \
	IMAGE_TAGS=latest \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
			op-node op-batcher op-proposer op-challenger op-deployer deop-geth
.PHONY: docker