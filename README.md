# Simple OP Stack Infra Node

A simplified setup for deploying and running an OP Stack L2 on either a local
L1 (Anvil) or an existing remote/testnet L1 RPC.

## Required Tools

* Install build tools

```shell
brew install just make jq
```

* Install foundry tool

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup --install stable
```

## Download Submodules

先拉子模块，再构建二进制（构建依赖子模块源码）。

```shell
git submodule update --init --recursive
```

## Build binaries

```shell
bash scripts/build-binaries.sh
```

> 若 `USE_FAULT_PROOFS=true`，脚本会额外构建 fault-proof 依赖：`cannon`、`op-program`，
> 并用 `reproducible-prestate`（**需 Docker**，会拉取官方 `golang` 镜像）生成 `prestate.json` /
> `prestate-proof.json`。其 `.pre` 必须等于 deploy-config 的 `faultGameAbsolutePrestate`，
> 否则 op-challenger 无法参与已部署的 dispute game。

## Configuration

```shell
# Local Anvil L1 config
cp .envrc.local.example .envrc

# Or remote/testnet L1 config
cp .envrc.testnet.example .envrc

# Edit .envrc to configure versions for each component
source .envrc
```

## Runbooks

- Local Anvil L1: `doc/local_cgt_jovian_upgrade_runbook.md`
- Remote/testnet L1: `doc/remote_l1_cgt_jovian_deploy_runbook.md`

## Run Anvil (Local L1)

```shell
bash scripts/run-anvil.sh
```

## Deploy Contracts

```shell
# Local Anvil L1
bash scripts/chain-setup.sh local

# Existing remote/testnet L1
bash scripts/chain-setup.sh remote
```

## Run individual components (`run-op-*.sh`)

`scripts/run-op-<component>.sh` 是各组件 flags 的唯一真源，既被 `chain-start.sh` 编排调用，
也可单独运行用于调试/重启。单独运行前需先 `bash scripts/chain-setup.sh <local|remote>`
生成配置，并确保 op-geth datadir 已初始化、JWT 已生成（首次由 `chain-start.sh` 幂等完成；
或参考 `chain-start.sh` 里的 `op-geth init` 步骤手动初始化）。

```shell
# op-geth（不再执行 op-geth init，需 datadir 已初始化）
bash scripts/run-op-geth.sh

# op-node
bash scripts/run-op-node.sh

# op-batcher
bash scripts/run-op-batcher.sh

# op-proposer
bash scripts/run-op-proposer.sh
```

## Run op-challenger

当 `USE_FAULT_PROOFS=true` 时，`chain-start.sh` 会在启动链后**自动拉起** op-challenger
（可用 `SKIP_CHALLENGER=1 bash scripts/chain-start.sh` 跳过）。也可单独运行：

```shell
bash scripts/run-op-challenger.sh              # 前台
bash scripts/run-op-challenger.sh --background # 后台，写 data/pids、data/logs
```

前置条件与要点：

- 已构建 fault-proof 二进制：`bin/cannon`、`bin/op-program`、`bin/prestate.json`
  （`build-binaries.sh` 在 `USE_FAULT_PROOFS=true` 时构建）。
- `trace-type` 跟随 `GAME_TYPE`：`1`→`permissioned`，`0`→`cannon`，与部署时 `respectedGameType`
  及 op-proposer 的 `--game-type` 保持一致。
- prestate 一致性：启动前脚本会校验 `bin/prestate-proof.json` 的 `.pre` 是否等于
  deploy-config 的 `faultGameAbsolutePrestate`，不一致会直接报错退出。
- L1 Beacon：`--l1-beacon` 为必填项。本地 anvil 无 Beacon API，默认回退到 L1 RPC；
  calldata DA 下通常不触发 blob 请求，若因 beacon 起不来需指向真实 Beacon 或运行 fake beacon
  并用 `L1_BEACON_URL` 覆盖。
- permissioned 模式下 challenger 地址必须是部署时授权的 challenger，用
  `OP_CHALLENGER_PRIVATE_KEY` 覆盖默认私钥。

## Version Configuration

Each component can be configured with its own version/branch/commit:

| Variable | Description | Example |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth version | `v1.101411.1` |
| `OP_NODE_REF` | op-node version | `v1.9.5` |
| `OP_BATCHER_REF` | op-batcher version | `v1.9.5` |
| `OP_PROPOSER_REF` | op-proposer version | `v1.9.5` |
| `OP_CHALLENGER_REF` | op-challenger version（与 op-node 同分支，需识别最新 L1 头部） | `cgt-jovian/v1.16.5` |
| `OP_PROGRAM_REF` | op-program version（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `CANNON_REF` | cannon version（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `op-contracts/v2.0.0-beta.3` |

> fault-proof 组件（`op-challenger`/`op-program`/`cannon`）的 ref 应与 `OP_CONTRACTS_REF` 指向
> **同一 monorepo commit**，这样 MIPS 实现与 prestate 才与已部署合约配套。注意官方 tag 快照不含
> 本链 CGT/Jovian 执行定制；要对定制链算出正确状态根，需换成含相同定制的 op-program。
