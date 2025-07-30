
submodules: ## Updates git submodules
	git submodule update --init --recursive
.PHONY: submodules

docker: submodules ## Builds Docker images for Go components using buildx
	HK_GETH_BRANCH=${HK_GETH_BRANCH} \
	HK_VERSE_BRANCH=${HK_VERSE_BRANCH} \
	IMAGE_TAGS=${HK_GETH_BRANCH} \
	docker buildx bake \
			--progress plain \
			--load \
			-f docker-bake.hcl \
			verse-node verse-batcher verse-proposer verse-challenger verse-deployer verse-geth
.PHONY: docker