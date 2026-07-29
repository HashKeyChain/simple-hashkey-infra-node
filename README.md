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

Pull submodules first, then build binaries (the build depends on submodule sources).

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

# Edit .envrc to configure versions, ports and fork times for each component
source .envrc
```

远端/测试网 L1 没有单独的 example 文件，从 `.envrc.local.example` 复制后改 `L1_RPC_URL`、
`L1_CHAIN_ID` 和各账户私钥即可（remote 的账户必须已充值）。

## 脚本布局

```
scripts/deploy-chain/   部署与重建：chain-setup / activate-fork / chain-reset / deploy-jovian-chain
scripts/chain-ops/      运行期编排与各组件启动器：chain-start / chain-stop / run-op-*
scripts/flashblocks/    Flashblocks 组件与相位切换：build / run-* / switch-to-flashblocks-dryrun
scripts/jovian/         Jovian SystemConfig 参数配置与验证
```

## Docs

- **`doc/chain-lifecycle.md` — 链生命周期操作手册（从零到运行、推分叉、接 Flashblocks、重建，先看这份）**
- `doc/flashblocks_local_impl.md` — Flashblocks 本地接入方案与验证门
- `scripts/flashblocks/verify/README.md` — Flashblocks 验证脚本（P0~P3 逐门可重复执行）
- `doc/LOCAL_CGT_JOVIAN_UPGRADE_RUNBOOK.md` — 本地 Anvil L1 的 CGT + Jovian runbook
- `doc/remote_l1_cgt_jovian_deploy_runbook.md` — 远端/测试网 L1 部署 runbook

## Run Anvil (Local L1)

```shell
bash scripts/chain-ops/run-anvil.sh
```

## Deploy Contracts

```shell
# Local Anvil L1
bash scripts/deploy-chain/chain-setup.sh local

# Existing remote/testnet L1
bash scripts/deploy-chain/chain-setup.sh remote
```

## Start / stop the chain

```shell
bash scripts/chain-ops/chain-start.sh local
bash scripts/chain-ops/chain-stop.sh
```

`chain-start.sh` 按 `.envrc` 的 `FLASHBLOCKS_MODE`（`off` / `dry_run` / `enabled`）决定
额外拉起哪些 Flashblocks 组件；`chain-stop.sh` 会一并停掉。详见 `doc/chain-lifecycle.md` 第 6 节。

## Run individual components (`run-op-*.sh`)

`scripts/chain-ops/run-op-<component>.sh` 是各组件 flags 的唯一真源，既被 `chain-start.sh`
编排调用，也可单独运行用于调试/重启。单独运行前需先
`bash scripts/deploy-chain/chain-setup.sh <local|remote>` 生成配置，并确保 op-geth datadir
已初始化、JWT 已生成（首次由 `chain-start.sh` 幂等完成；或参考 `chain-start.sh` 里的
`op-geth init` 步骤手动初始化）。

```shell
# op-geth（不再执行 op-geth init，需 datadir 已初始化）
bash scripts/chain-ops/run-op-geth.sh

# op-node
bash scripts/chain-ops/run-op-node.sh

# op-batcher
bash scripts/chain-ops/run-op-batcher.sh

# op-proposer
bash scripts/chain-ops/run-op-proposer.sh
```

## Run op-challenger

当 `USE_FAULT_PROOFS=true` 时，`chain-start.sh` 会在启动链后**自动拉起** op-challenger
（可用 `SKIP_CHALLENGER=1 bash scripts/chain-ops/chain-start.sh` 跳过）。也可单独运行：

```shell
bash scripts/chain-ops/run-op-challenger.sh              # 前台
bash scripts/chain-ops/run-op-challenger.sh --background # 后台，写 data/pids、data/logs
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
| `OP_GETH_REF` | op-geth version | `v1.101605.0` |
| `OP_NODE_REF` | op-node version（本地 CGT/Jovian 定制分支） | `cgt-jovian/v1.16.5` |
| `OP_BATCHER_REF` | op-batcher version | `op-batcher/v1.16.3` |
| `OP_PROPOSER_REF` | op-proposer version | `op-proposer/v1.10.0` |
| `OP_CHALLENGER_REF` | op-challenger version（与 op-node 同分支，需识别最新 L1 头部） | `cgt-jovian/v1.16.5` |
| `OP_PROGRAM_REF` | op-program version（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `CANNON_REF` | cannon version（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `OP_CONTRACTS_REF` | contracts-bedrock version | `op-contracts/v2.0.0-beta.3` |

> fault-proof 组件（`op-challenger`/`op-program`/`cannon`）的 ref 应与 `OP_CONTRACTS_REF` 指向
> **同一 monorepo commit**，这样 MIPS 实现与 prestate 才与已部署合约配套。注意官方 tag 快照不含
> 本链 CGT/Jovian 执行定制；要对定制链算出正确状态根，需换成含相同定制的 op-program。

## Flashblocks components (optional)

Rust 组件从 submodule 源码自编，只有要跑 Flashblocks 时才需要：

```shell
bash scripts/flashblocks/build-flashblocks.sh
```

| Variable | Description | Example |
|----------|-------------|---------|
| `ROLLUP_BOOST_REF` | rollup-boost + flashblocks-websocket-proxy（同一 submodule 同一 tag） | `v0.7.11` |
| `OP_RBUILDER_REF` | op-rbuilder（flashblocks builder） | `op-rbuilder/v0.2.13` |
| `OP_RETH_REF` | op-reth（flashblocks-aware RPC 副本） | `v1.9.3` |

从 `off` 切到 `dry_run` 用外科式切换脚本（op-rbuilder 只起一次、全程不杀）：

```shell
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local
```

相位含义、切换步骤、端口分配与故障排查见 `doc/chain-lifecycle.md` 第 6、8、10 节。

切换完成后验证：

```bash
bash scripts/flashblocks/verify/run-all.sh
```

会按 rollup-boost 的当前执行模式自动挑选该跑的验证门（P0 编译与创世对齐、P1 影子同步、
P2 dry_run 对账与交易覆盖、P3 enabled 与降级能力）。各脚本职责与判定口径见
`scripts/flashblocks/verify/README.md`。
