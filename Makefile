
submodules: ## Updates git submodules
	git submodule update --init --recursive
.PHONY: submodules

docker: submodules ## Builds Docker images for Go components using buildx
	HK_GETH_BRANCH=latest \
	HK_VERSE_BRANCH=latest \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
			verse-node verse-batcher verse-proposer verse-challenger verse-deployer verse-geth
.PHONY: docker