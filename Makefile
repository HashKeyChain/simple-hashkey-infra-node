

docker: ## Builds Docker images for Go components using buildx
	# We don't use a buildx builder here, and just load directly into regular docker, for convenience.
	IMAGE_TAGS=latest \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
			op-node op-batcher op-proposer op-challenger op-deployer op-geth
.PHONY: docker