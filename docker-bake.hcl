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
  default = ""
}

target "verse-node" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT      = "${HK_VERSE_COMMIT}"
    GIT_DATE        = "${HK_VERSE_DATE}"
    OP_NODE_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "op-node-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-node:${tag}"]
}

target "verse-batcher" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT         = "${HK_VERSE_COMMIT}"
    GIT_DATE           = "${HK_VERSE_DATE}"
    OP_BATCHER_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "op-batcher-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-batcher:${tag}"]
}

target "verse-proposer" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT          = "${HK_VERSE_COMMIT}"
    GIT_DATE            = "${HK_VERSE_DATE}"
    OP_PROPOSER_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "op-proposer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-proposer:${tag}"]
}

target "verse-challenger" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT            = "${HK_VERSE_COMMIT}"
    GIT_DATE              = "${HK_VERSE_DATE}"
    OP_CHALLENGER_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "op-challenger-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-challenger:${tag}"]
}


target "cannon" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT     = "${HK_VERSE_COMMIT}"
    GIT_DATE       = "${HK_VERSE_DATE}"
    CANNON_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "cannon-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}cannon:${tag}"]
}


target "verse-deployer" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT          = "${HK_VERSE_COMMIT}"
    GIT_DATE            = "${HK_VERSE_DATE}"
    OP_DEPLOYER_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "op-deployer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-deployer:${tag}"]
}


target "verse-faucet" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT        = "${HK_VERSE_COMMIT}"
    GIT_DATE          = "${HK_VERSE_DATE}"
    OP_FAUCET_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "verse-faucet-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-faucet:${tag}"]
}

target "verse-cannon" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "verse"
  args = {
    GIT_COMMIT     = "${HK_VERSE_COMMIT}"
    GIT_DATE       = "${HK_VERSE_DATE}"
    CANNON_VERSION = "${HK_VERSE_BRANCH}"
  }
  target = "cannon-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_VERSE_BRANCH) : "${REPOSITORY}verse-cannon:${tag}"]
}

target "verse-geth" {
  dockerfile = "./Dockerfile"
  context    = "verse-geth"
  args = {
    GIT_COMMIT             = "${HK_GETH_COMMIT}"
    GIT_DATE               = "${HK_GETH_DATE}"
    OP_INTEROP_MON_VERSION = "${HK_GETH_BRANCH}"
  }
  target = ""
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", HK_GETH_BRANCH) : "${REPOSITORY}verse-geth:${tag}"]
}