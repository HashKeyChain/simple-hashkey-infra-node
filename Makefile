
submodules: ## Updates git submodules
	git submodule update --init --recursive
.PHONY: submodules

docker: # submodules ## Builds Docker images for Go components using buildx
	sh scripts/build-dockers.sh
.PHONY: docker