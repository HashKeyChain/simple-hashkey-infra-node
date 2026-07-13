# 链生命周期操作手册

一条 HashKey / OP Stack 定制链（CGT + Jovian）从零到运行、再到推进分叉、重建的**命令手册**。
每一步基本对应一个脚本，按顺序执行即可。

```
设置 env → 编译 → 部署环境 → 启动 → (分叉升级)* → 停止 / 重建
 .envrc    build   chain-setup  chain-start  activate-fork   chain-stop / chain-reset
```

> 所有命令在仓库根目录执行；脚本内部会 `source .envrc`。示例用 `local`（本地 anvil）；
> 远端真实 L1 把参数换成 `remote` 即可。

---

## 0. 前置准备（首次 clone 后一次性）

```bash
# 子模块（op-geth、optimism）
git submodule update --init --recursive
```

依赖工具：Docker（跑 anvil + 构建可复现 prestate）、Foundry（forge/cast/anvil）、Go、make、jq、python3、openssl。

---

## 1. 设置 env（编辑 `.envrc`）

```bash
$EDITOR .envrc
source .envrc
```

关键变量：

| 变量 | 说明 | 本地默认 |
|---|---|---|
| `DEPLOYMENT_CONTEXT` | 部署上下文名，决定 `config/<context>/` 目录 | `local-mainnet` |
| `L1_RPC_URL` | L1 RPC；local 用本机 anvil | `http://localhost:8545` |
| `L1_CHAIN_ID` / `L2_CHAIN_ID` | L1 / L2 链 ID | `11155111` / `5536` |
| `DEPLOY_*` / `GS_*` | 部署与运维账户（local 是测试账户；remote 必须已充值） | 测试账户 |
| `USE_CUSTOM_GAS_TOKEN` / `CUSTOM_GAS_TOKEN_ADDRESS` | CGT 开关与地址；**全新本地链留空**由 setup 部署并回填 | `true` / 留空 |
| `USE_FAULT_PROOFS` / `GAME_TYPE` | Fault Proof 开关；`1`=permissioned 起步 | `true` / `1` |
| `OP_*_REF` / `CANNON_REF` / `OP_PROGRAM_REF` | 各组件版本（node 用 `cgt-jovian/v1.16.5`；FP 组件跟随合约 tag） | 见文件 |
| `FORK_*_TIME` | **分叉激活时间单一真源**（见第 4 节）；初始 `fjord=0` 其余留空 | fjord=0 |

`FORK_*_TIME` 语义：`0`=创世激活；**留空**=不启动该分叉。geth 的 `--override.*` 与
`rollup.json` 的 `*_time` 都从这批变量派生，改一处即可。

---

## 2. 编译组件

```bash
bash scripts/build-binaries.sh
```

产物落在 `bin/`：`op-geth`、`op-node`、`op-batcher`、`op-proposer`、`op-challenger`。
当 `USE_FAULT_PROOFS=true` 时额外构建 `cannon` 和可复现 `prestate`（`prestate.json` /
`prestate-proof.json`，需要 **Docker**）。

---

## 3. 部署环境（部署 L1 合约 + 生成 L2 配置）

```bash
bash scripts/chain-setup.sh local
```

它会：本地无 anvil 时自动起 anvil → 给账户充值 → 部署 Multicall3（local）→ 部署 OP L1 合约 +
CGT → 生成 `config/<context>/` 下的 `artifact.json` / `genesis.json` / `rollup.json` /
`state-dump-latest.json` → 自动调用 `patch-rollup-config.sh` 修正 rollup.json（含把
`FORK_*_TIME` 同步进 `*_time`，初始为纯-fjord）。

> 远端：`bash scripts/chain-setup.sh remote`（用 `.envrc` 的真实 `L1_RPC_URL`，不起 anvil）。

---

## 4. 启动全部服务

```bash
bash scripts/chain-start.sh local
```

启动 `op-geth`、`op-node`、`op-batcher`、`op-proposer`，FP 模式下还有 `op-challenger`。
日志在 `data/logs/`，PID 在 `data/pids/`。

快速验证：

```bash
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp}'
```

单独重启某个组件（可选）：`bash scripts/run-op-geth.sh` 等（需先 setup + 已 init）。

---

## 5. 分叉升级（在运行中的链上推进硬分叉）

初次启动只有 fjord。要激活后续分叉：

```bash
# 1) 编辑 .envrc，把要激活的分叉填成目标 unix 时间戳（建议取"当前+N秒"以便观察过渡）：
#    export FORK_GRANITE_TIME=<ts>
#    export FORK_HOLOCENE_TIME=<ts>   # 依需要
#    ...
# 2) 一键推进（自动：停 L2 → 同步 rollup.json → 重启 L2）：
bash scripts/activate-fork.sh local
```

`activate-fork.sh` 从 `.envrc` 读 `FORK_*_TIME`，同步进 `rollup.json`（op-node 读），
重启后 `run-op-geth.sh` 现场组装 `--override.*`（op-geth 读），两侧同源一致。
不重启 anvil、不重建 datadir，链从当前高度续跑，分叉在目标时间激活。

验证分叉是否生效：

```bash
cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645
```

---

## 6. 停止 / 重建

停止 L2（保留数据与配置，可再 `chain-start`）：

```bash
bash scripts/chain-stop.sh
```

重建一条全新链（**破坏性、不可逆**）：

```bash
bash scripts/chain-reset.sh local        # 交互确认；加 -y 跳过
```

`chain-reset.sh` 会：停 L2 →（local）停 anvil → 删 `data/` → 删 `config/<context>/` →
（local）清空 `.envrc` 的 `CUSTOM_GAS_TOKEN_ADDRESS`。之后重新走第 3、4 步即可。

---

## 命令速查

| 目的 | 命令 |
|---|---|
| 子模块（首次） | `git submodule update --init --recursive` |
| 设置 env | 编辑 `.envrc` → `source .envrc` |
| 编译 | `bash scripts/build-binaries.sh` |
| 部署环境 | `bash scripts/chain-setup.sh local` |
| 启动 | `bash scripts/chain-start.sh local` |
| 停止 | `bash scripts/chain-stop.sh` |
| 分叉升级 | 改 `.envrc` 的 `FORK_*_TIME` → `bash scripts/activate-fork.sh local` |
| 重建（清空重来） | `bash scripts/chain-reset.sh local [-y]` |

完整闭环：
`chain-reset` → 设置 env → `build-binaries` → `chain-setup` → `chain-start` →（改 FORK_*_TIME →`activate-fork`）\*
