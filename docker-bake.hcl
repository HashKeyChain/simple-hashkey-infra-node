variable "REPOSITORY" {
  default = "rothcold/"
}

variable "HK_VERSE_BRANCH" {
  default = "latest" // split by ","
}

variable "HK_VERSE_COMMIT" {
  default = "dev"
}

variable "HK_VERSE_DATE" {
  default = "0"
}

variable "HK_GETH_BRANCH" {
  default = "latest" // split by ","
}

variable "HK_GETH_COMMIT" {
  default = "dev"
}

variable "HK_GETH_DATE" {
  default = "0"
}

variable "PLATFORMS" {
  // You can override this as "linux/amd64,linux/arm64".
  // Only specify a single platform when `--load` ing into docker.
  // Multi-platform is supported when outputting to disk or pushing to a registry.
  // Multi-platform builds can be tested locally with:  --set="*.output=type=image,push=false"
  default = "linux/amd64,linux/arm64,linux/riscv64"
}

variable "GIT_COMMIT" {
  default = "${HK_VERSE_COMMIT}"
}

variable "GIT_DATE" {
  default = "${HK_VERSE_DATE}"
}

// Each of the services can have a customized version, but defaults to the global specified version.
variable "OP_NODE_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "OP_BATCHER_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "OP_PROPOSER_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "OP_CHALLENGER_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "CANNON_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "OP_DEPLOYER_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

variable "OP_FAUCET_VERSION" {
  default = "${HK_VERSE_BRANCH}"
}

target "verse-node" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT      = "${GIT_COMMIT}"
    GIT_DATE        = "${GIT_DATE}"
    OP_NODE_VERSION = "${OP_NODE_VERSION}"
  }
  target = "op-node-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-node:${tag}"]
}

target "verse-batcher" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT         = "${GIT_COMMIT}"
    GIT_DATE           = "${GIT_DATE}"
    OP_BATCHER_VERSION = "${OP_BATCHER_VERSION}"
  }
  target = "op-batcher-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-batcher:${tag}"]
}

target "verse-proposer" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT          = "${GIT_COMMIT}"
    GIT_DATE            = "${GIT_DATE}"
    OP_PROPOSER_VERSION = "${OP_PROPOSER_VERSION}"
  }
  target = "op-proposer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-proposer:${tag}"]
}

target "verse-challenger" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT            = "${GIT_COMMIT}"
    GIT_DATE              = "${GIT_DATE}"
    OP_CHALLENGER_VERSION = "${OP_CHALLENGER_VERSION}"
  }
  target = "op-challenger-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-challenger:${tag}"]
}

target "verse-deployer" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT          = "${GIT_COMMIT}"
    GIT_DATE            = "${GIT_DATE}"
    OP_DEPLOYER_VERSION = "${OP_DEPLOYER_VERSION}"
  }
  target = "op-deployer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-deployer:${tag}"]
}

target "verse-faucet" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT        = "${GIT_COMMIT}"
    GIT_DATE          = "${GIT_DATE}"
    OP_FAUCET_VERSION = "${OP_FAUCET_VERSION}"
  }
  target = "verse-faucet-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-faucet:${tag}"]
}

target "verse-cannon" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT     = "${GIT_COMMIT}"
    GIT_DATE       = "${GIT_COMMIT}"
    CANNON_VERSION = "${CANNON_VERSION}"
  }
  target = "cannon-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-cannon:${tag}"]
}

target "verse-geth" {
  dockerfile = "./Dockerfile"
  context    = "verse-geth"
  target = ""
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_GETH_BRANCH) : "${REPOSITORY}verse-geth:${tag}"]
}