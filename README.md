# Simple OP Stack Infra Node

本仓库用来**一键在本地拉起一条 HashKey 定制 OP Stack L2（CGT + 分叉到 Jovian）**，作为后续
开发和验证 **Flashblocks** 组件的基座链。也支持接到远端/测试网 L1。

> 为什么要"分叉到 Jovian"：Flashblocks 组件（rollup-boost / op-rbuilder / op-reth）必须与链的
> 分叉世代一致。由于"部署即 Jovian 创世"的代码尚未开发，脚本走的是**部署到 fjord 基线 → 起链 →
> 按时间自动激活各分叉到 Jovian** 的路径，一条命令搞定。

---

## TL;DR（新手照抄）

```shell
# 0) 一次性：装工具 + 拉子模块 + 编译二进制
brew install just make jq
curl -L https://foundry.paradigm.xyz | bash && foundryup --install stable
git submodule update --init --recursive
bash scripts/build-binaries.sh

# 1) 配置（本地 Anvil）
cp .envrc.local.example .envrc
source .envrc

# 2) 一键部署一条全新链并推进到 Jovian（本地需 Docker 运行，供 anvil 用）
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y

# 3) 验证已到 Jovian
cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645
```

第 2 步跑完（本地约几分钟，主要耗在合约部署）链就处于 Jovian 状态，可以在此之上开发 Flashblocks。

> 注意：如果你在**自己的终端**里跑，链会持续运行；若通过某些一次性 shell/CI 跑，后台守护进程可能随
> 会话结束被回收——这时数据仍在，`bash scripts/chain-ops/chain-start.sh local` 即可恢复。

---

## 1. 前置工具

```shell
brew install just make jq            # 构建工具
curl -L https://foundry.paradigm.xyz | bash && foundryup --install stable   # foundry: forge/cast/anvil
```

另需：**Docker**（本地跑 anvil、构建可复现 prestate）、Go、python3、openssl。

## 2. 拉取子模块

先拉子模块再构建（构建依赖子模块源码）：

```shell
git submodule update --init --recursive
```

## 3. 编译二进制

```shell
bash scripts/build-binaries.sh
```

产物落在 `bin/`：`op-geth`、`op-node`、`op-batcher`、`op-proposer`、`op-challenger`。

> `USE_FAULT_PROOFS=true` 时会额外构建 fault-proof 依赖 `cannon`、`op-program`，并用
> `reproducible-prestate`（**需 Docker**）生成 `prestate.json` / `prestate-proof.json`。

## 4. 配置 `.envrc`

```shell
cp .envrc.local.example .envrc      # 本地 Anvil L1
source .envrc
```

关键变量见 `doc/chain-lifecycle.md`。默认已是 CGT + Fault Proof + 分叉到 Jovian 的本地配置。
接远端/测试网 L1 时，在 `.envrc` 里把 `L1_RPC_URL` 等改成真实值即可（参考 `doc/history/remote_l1_cgt_jovian_deploy_runbook.md`）。

---

## 5. 一键部署一条链到 Jovian

这是本仓库的主线用法：

```shell
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

它会依次：**reset 旧链 → 部署合约生成 fjord 基线配置 → 起链 → 读实时 L2 时间自动计算各分叉激活
时间（每档间隔 2s）→ 停/同步 rollup/重启 → 等待并校验分叉激活到 Jovian**。分叉时间的唯一真源是
`.envrc` 的 `FORK_*_TIME`，脚本会把计算结果写回。

选项：

| 选项 | 说明 | 默认 |
|---|---|---|
| `--reset` | 先清空 `data/` 与 `config/<ctx>/` 部署全新链；对已存在的链必须加 | 关 |
| `-y` / `--yes` | 跳过 `chain-reset` 的不可逆二次确认 | 关 |
| `--pace=SEC` | 相邻分叉激活间隔秒数 | `2` |
| `--lead=SEC` | 从当前 L2 时间到首个待激活分叉的提前量（需 > 重启耗时） | `30` |
| `--target=FORK` | 推进到哪个分叉为止：`granite`\|`holocene`\|`isthmus`\|`jovian` | `jovian` |

验证：

```shell
cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp,baseFeePerGas}'
```

> 远端 L1：把 `local` 换成 `remote`（用 `.envrc` 里真实 `L1_RPC_URL`，不起 anvil）。

## 6. 管理运行中的链

```shell
bash scripts/chain-ops/chain-start.sh local     # 恢复/启动（数据已在，不重部署）
bash scripts/chain-ops/chain-stop.sh            # 停止 L2（保留数据）
bash scripts/deploy-chain/chain-reset.sh local  # 清空重来（破坏性，加 -y 跳过确认）
```

日志 `data/logs/*.log`，PID `data/pids/*.pid`。更细的组件单独运行、op-challenger、bridge 与费用
验证、排障，见 `doc/chain-lifecycle.md`。

---

## 脚本目录

- `scripts/deploy-chain/` —— **部署一条链**：`deploy-jovian-chain.sh`(一键)、`chain-setup`、
  `deploy-contracts`、`patch-rollup-config`、`deploy-multicall3`、`activate-fork`、`chain-reset`。
- `scripts/chain-ops/` —— **启动/停止链**：`chain-start`、`chain-stop`、各 `run-op-*`、`run-anvil`。
- `scripts/`（根）—— 通用：`build-binaries`、`bridge-to-l2*`、`upgrade-systemconfig*`；`scripts/jovian/` 为 Jovian SystemConfig 参数操作。

## 文档导航

- **详细手册（生命周期 / 组件 / 排障 / bridge+验证）**：`doc/chain-lifecycle.md`
- **下一步：接入 Flashblocks** —— 架构与任务计划 `doc/flashblocks_upgrade_plan.md`；本地实现步骤 `doc/flashblocks_local_impl.md`
- 历史/归档文档（旧手动 runbook、远端部署）：`doc/history/`

---

## 组件版本配置

每个组件可单独指定版本/分支/commit（`.envrc`）：

| 变量 | 说明 | 示例 |
|----------|-------------|---------|
| `OP_GETH_REF` | op-geth 版本 | `v1.101605.0` |
| `OP_NODE_REF` | op-node 版本（CGT/Jovian 自研分支） | `cgt-jovian/v1.16.5` |
| `OP_BATCHER_REF` | op-batcher 版本 | `op-batcher/v1.16.3` |
| `OP_PROPOSER_REF` | op-proposer 版本 | `op-proposer/v1.10.0` |
| `OP_CHALLENGER_REF` | op-challenger 版本（与 op-node 同分支，需识别最新 L1 头部） | `cgt-jovian/v1.16.5` |
| `OP_PROGRAM_REF` | op-program 版本（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `CANNON_REF` | cannon 版本（跟随合约同源） | `op-contracts/v2.0.0-beta.3` |
| `OP_CONTRACTS_REF` | contracts-bedrock 版本 | `op-contracts/v2.0.0-beta.3` |

> fault-proof 组件（`op-challenger`/`op-program`/`cannon`）的 ref 应与 `OP_CONTRACTS_REF` 指向
> **同一 monorepo commit**，MIPS 实现与 prestate 才与已部署合约配套。官方 tag 快照不含本链
> CGT/Jovian 执行定制；要对定制链算出正确状态根，需换成含相同定制的 op-program。
