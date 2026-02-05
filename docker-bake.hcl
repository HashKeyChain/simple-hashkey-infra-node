variable "REPOSITORY" {
  default = "rothcold/"
}

variable "KONA_VERSION" {
  default = "1.0.1"
}

variable "ASTERISC_VERSION" {
  default = "v1.3.0"
}

variable "GIT_COMMIT" {
  default = "dev"
}

variable "GIT_DATE" {
  default = "0"
}

// The default version to embed in the built images.
// During CI release builds this is set to <<pipeline.git.tag>>
variable "GIT_VERSION" {
  default = "v0.0.0"
}

// Component version refs (for git checkout and docker tags)
variable "OP_GETH_REF" {
  default = "latest"
}

variable "OP_NODE_REF" {
  default = "latest"
}

variable "OP_BATCHER_REF" {
  default = "latest"
}

variable "OP_PROPOSER_REF" {
  default = "latest"
}

variable "OP_CHALLENGER_REF" {
  default = "latest"
}

variable "OP_DEPLOYER_REF" {
  default = "latest"
}

variable "OP_FAUCET_REF" {
  default = "latest"
}

variable "CANNON_REF" {
  default = "latest"
}

variable "PLATFORMS" {
  // You can override this as "linux/amd64,linux/arm64".
  // Only specify a single platform when `--load` ing into docker.
  // Multi-platform is supported when outputting to disk or pushing to a registry.
  // Multi-platform builds can be tested locally with:  --set="*.output=type=image,push=false"
  default = ""
}

// Build version args (embedded in binaries)
variable "OP_NODE_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_BATCHER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_PROPOSER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_CHALLENGER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_DISPUTE_MON_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_PROGRAM_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_SUPERVISOR_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_TEST_SEQUENCER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "CANNON_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_CONDUCTOR_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_DEPLOYER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_DRIPPER_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_FAUCET_VERSION" {
  default = "${GIT_VERSION}"
}

variable "OP_INTEROP_MON_VERSION" {
  default = "${GIT_VERSION}"
}


target "op-node" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT      = "${GIT_COMMIT}"
    GIT_DATE        = "${GIT_DATE}"
    OP_NODE_VERSION = "${OP_NODE_VERSION}"
  }
  target = "op-node-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_NODE_REF) : "${REPOSITORY}op-node:${tag}"]
}

target "op-batcher" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT         = "${GIT_COMMIT}"
    GIT_DATE           = "${GIT_DATE}"
    OP_BATCHER_VERSION = "${OP_BATCHER_VERSION}"
  }
  target = "op-batcher-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_BATCHER_REF) : "${REPOSITORY}op-batcher:${tag}"]
}

target "op-proposer" {
  dockerfile = "ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT          = "${GIT_COMMIT}"
    GIT_DATE            = "${GIT_DATE}"
    OP_PROPOSER_VERSION = "${OP_PROPOSER_VERSION}"
  }
  target = "op-proposer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_PROPOSER_REF) : "${REPOSITORY}op-proposer:${tag}"]
}

target "op-challenger" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT            = "${GIT_COMMIT}"
    GIT_DATE              = "${GIT_DATE}"
    OP_CHALLENGER_VERSION = "${OP_CHALLENGER_VERSION}"
    KONA_VERSION          = "${KONA_VERSION}"
    ASTERISC_VERSION      = "${ASTERISC_VERSION}"
  }
  target = "op-challenger-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_CHALLENGER_REF) : "${REPOSITORY}op-challenger:${tag}"]
}


target "cannon" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT     = "${GIT_COMMIT}"
    GIT_DATE       = "${GIT_DATE}"
    CANNON_VERSION = "${CANNON_VERSION}"
  }
  target = "cannon-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", CANNON_REF) : "${REPOSITORY}cannon:${tag}"]
}


target "op-deployer" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT          = "${GIT_COMMIT}"
    GIT_DATE            = "${GIT_DATE}"
    OP_DEPLOYER_VERSION = "${OP_DEPLOYER_VERSION}"
  }
  target = "op-deployer-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_DEPLOYER_REF) : "${REPOSITORY}op-deployer:${tag}"]
}


target "op-faucet" {
  dockerfile = "./ops/docker/op-stack-go/Dockerfile"
  context    = "optimism"
  args = {
    GIT_COMMIT        = "${GIT_COMMIT}"
    GIT_DATE          = "${GIT_DATE}"
    OP_FAUCET_VERSION = "${OP_FAUCET_VERSION}"
  }
  target = "op-faucet-target"
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_FAUCET_REF) : "${REPOSITORY}op-faucet:${tag}"]
}

target "op-geth" {
  dockerfile = "./Dockerfile"
  context    = "op-geth"
  args = {
    GIT_COMMIT             = "${GIT_COMMIT}"
    GIT_DATE               = "${GIT_DATE}"
    OP_INTEROP_MON_VERSION = "${OP_INTEROP_MON_VERSION}"
  }
  target = ""
  platforms = split(",", PLATFORMS)
  tags   = [for tag in split(",", OP_GETH_REF) : "${REPOSITORY}op-geth:${tag}"]
}
