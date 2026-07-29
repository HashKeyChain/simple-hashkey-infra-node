# 链生命周期操作手册

一条 HashKey / OP Stack 定制链（CGT + Jovian）从零到运行、推进分叉、接入 Flashblocks、
再到停止重建的**命令手册**。每一步基本对应一个脚本，按顺序执行即可。

```
链本身：   设置 env → 编译 → 部署环境 → 启动 → (推进分叉)* → 停止 / 重建
            .envrc    build   chain-setup  chain-start  activate-fork   chain-stop / chain-reset

Flashblocks 相位（正交于上面这条线，链跑着的时候切）：
            off ──switch-to-flashblocks-dryrun──▶ dry_run ──▶ enabled
             ▲                                                  │
             └──────────── 改 FLASHBLOCKS_MODE + 重启 ◀──────────┘
```

> 所有命令在仓库根目录执行；脚本内部会 `source .envrc`。示例用 `local`（本地 anvil）；
> 远端真实 L1 把参数换成 `remote` 即可。脚本按目录分三类：
> `scripts/deploy-chain/`（部署与重建）、`scripts/chain-ops/`（运行期编排与各组件启动器）、
> `scripts/flashblocks/`（Flashblocks 组件与相位切换）。

---

## 0. 前置准备（首次 clone 后一次性）

```bash
git submodule update --init --recursive
```

依赖工具：Docker（跑 anvil + 构建可复现 prestate）、Foundry（forge/cast/anvil）、Go、
Rust（仅 Flashblocks 组件需要）、make、jq、python3、openssl。

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
| `L1_BLOCK_TIME` / `L2_BLOCK_TIME` | 出块间隔；见下方约束 | `6` / `2` |
| `MAX_CHANNEL_DURATION` | batcher 一条 channel 最多开几个 L1 块 | `5` |
| `DEPLOY_*` / `GS_*` | 部署与运维账户（local 是测试账户；remote 必须已充值） | 测试账户 |
| `USE_CUSTOM_GAS_TOKEN` / `CUSTOM_GAS_TOKEN_ADDRESS` | CGT 开关与地址；**全新本地链留空**由 setup 部署并回填 | `true` / 留空 |
| `USE_FAULT_PROOFS` / `GAME_TYPE` | Fault Proof 开关；`1`=permissioned 起步 | `true` / `1` |
| `OP_*_REF` / `CANNON_REF` / `OP_PROGRAM_REF` | Go 组件版本（node 用 `cgt-jovian/v1.16.5`；FP 组件跟随合约 tag） | 见文件 |
| `ROLLUP_BOOST_REF` / `OP_RBUILDER_REF` / `OP_RETH_REF` | Flashblocks 三个 Rust 组件的 tag | 见文件 |
| `FORK_*_TIME` | **分叉激活时间单一真源**（见第 5 节）；初始 `fjord=0` 其余留空 | fjord=0 |
| `FLASHBLOCKS_MODE` | `off` / `dry_run` / `enabled`，见第 6 节 | `off` |

### `FORK_*_TIME` 语义

`0`=创世激活；**留空**=不启动该分叉。分叉时间从这批变量派生到 `rollup.json` 的 `*_time`
（op-node 读），再由 `activate-fork.sh` 把分叉表烘入 `genesis.json`（`bake-genesis-forks.sh`），
op-geth 与 reth 系（op-rbuilder / op-reth）共用这份 genesis 读分叉——geth **不再用 `--override.*`**，
改一处（`.envrc`）即全链一致。

### `L1_BLOCK_TIME` 的上下界

不能随便调，两头都有硬约束：

- **下界 `>= L2_BLOCK_TIME`**：L2 区块的 L1 origin 每个 L2 块最多前进一格。L1 出块比 L2 快，
  origin 就会被 L1 头持续甩开，最终耗尽 `max_sequencer_drift`。
- **上界看 op-node 重启延迟**：分叉激活后至少要再跑 `50 × L1_BLOCK_TIME` 秒才能安全重启 op-node
  （原因见第 6.6 节）。6 秒即 5 分钟；调回 12 秒就要等 10 分钟。

`MAX_CHANNEL_DURATION=5` 是配套的：默认 300 会让 safe head 长时间落后 L1 头，而"能否安全重启
op-node"取决于 safe head 的 L1 origin 追到哪，落后多少就要多等多少。本地链没有 L1 gas 压力，
调小让 safe head 紧跟 L1。

---

## 2. 编译

### 2.1 Go 组件（必须）

```bash
bash scripts/build-binaries.sh
```

产物落在 `bin/`：`op-geth`、`op-node`、`op-batcher`、`op-proposer`、`op-challenger`。
当 `USE_FAULT_PROOFS=true` 时额外构建 `cannon`、`op-program` 和可复现 `prestate`
（`prestate.json` / `prestate-proof.json`，需要 **Docker**）。

### 2.2 Rust 组件（只有要跑 Flashblocks 才需要）

```bash
bash scripts/flashblocks/build-flashblocks.sh
```

从 submodule 源码编 `rollup-boost`、`flashblocks-websocket-proxy`（同一 submodule 同一 tag）、
`op-rbuilder`、`op-reth` 到 `bin/`。首次很慢（reth 依赖重）。toolchain 由 `RUSTUP_TOOLCHAIN`
统一固定为 `1.94`，可用 `FB_RUST_TOOLCHAIN` 覆盖。macOS 上脚本会对新二进制重新 ad-hoc 签名，
规避首次 exec 卡死。

---

## 3. 部署环境（部署 L1 合约 + 生成 L2 配置）

```bash
bash scripts/deploy-chain/chain-setup.sh local
```

它会：本地无 anvil 时自动起 anvil → 给账户充值 → 部署 Multicall3（local）→ 部署 OP L1 合约 +
CGT → 生成 `config/<context>/` 下的 `artifact.json` / `genesis.json` / `rollup.json` /
`state-dump-latest.json` → 自动调用 `patch-rollup-config.sh` 做运行时兼容修正（删 `da_challenge`、
补 `chain_op_config`、local 刷新 `genesis.l1.hash`）。

此步**不配置分叉**：部署工具产出纯-fjord 基线，`granite..jovian` 的调度统一由
`activate-fork.sh` 负责。

> 远端：`bash scripts/deploy-chain/chain-setup.sh remote`（用 `.envrc` 的真实 `L1_RPC_URL`，不起 anvil）。

---

## 4. 启动全部服务

```bash
bash scripts/chain-ops/chain-start.sh local
```

按 `FLASHBLOCKS_MODE` 决定起哪些组件（见第 6 节）。`off` 态下是 `op-geth`、`op-node`、
`op-batcher`、`op-proposer`，FP 模式下还有 `op-challenger`。日志在 `data/logs/`，PID 在 `data/pids/`。

可选开关：`SKIP_BATCHER=1` / `SKIP_PROPOSER=1` / `SKIP_CHALLENGER=1` / `SKIP_FB_USER=1`。

快速验证：

```bash
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp}'
```

单独重启某个组件：直接跑对应的 `scripts/chain-ops/run-op-*.sh`。这些脚本是各组件 flags 的
**唯一真源**，既被 `chain-start.sh` 编排调用，也可单独运行调试（前提是配置已生成、op-geth
datadir 已 init、JWT 已存在，首次由 `chain-start.sh` 幂等完成）。

---

## 5. 分叉升级（在运行中的链上推进硬分叉）

初次启动只有 fjord。

### 5.1 手动推进

```bash
# 1) 编辑 .envrc，把要激活的分叉填成目标 unix 时间戳（取"当前+N秒"以便观察过渡）：
#    export FORK_GRANITE_TIME=<ts>
#    export FORK_HOLOCENE_TIME=<ts>
#    ...
# 2) 一键推进
bash scripts/deploy-chain/activate-fork.sh local
```

`activate-fork.sh` 从 `.envrc` 读 `FORK_*_TIME`，四步推进：

1. 停 L2；
2. 同步进 `rollup.json`（op-node 读）；
3. `bake-genesis-forks.sh` 把分叉表烘入 `genesis.json`，再对既有 op-geth datadir 重跑
   `geth init`——**只更新分叉表、保留全部链数据**（geth 对创世 hash 匹配的库是非破坏更新；
   把尚未到达的未来分叉写入是兼容的，若想把已过去的分叉往前改会被 geth `mismatching` 报错拦截）；
4. 重启 L2，geth 从更新后的 genesis 读分叉表，reth 系共用同一份 genesis。

不重启 anvil、**不铲 datadir**，链从当前高度续跑，分叉在目标时间激活。

### 5.2 一键建一条已推到 Jovian 的新链

反复搭"与主网同分叉"的链去接 Flashblocks 时用这个，把第 3~5 步压成一条命令：

```bash
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

内部：`chain-reset` → 归零分叉时间 → `chain-setup`（纯 fjord）→ `chain-start` → 按当前 L2
时间算出 `granite..jovian` 的激活时间写回 `.envrc` → `activate-fork` → 等墙钟到点并校验。

| 选项 | 含义 | 默认 |
|---|---|---|
| `--reset` | 先 `chain-reset` 清空重来；对已存在的链**必须**加，否则脚本拒绝执行 | 无 |
| `--pace=SEC` | 相邻分叉的激活间隔 | `2` |
| `--lead=SEC` | 从当前 L2 时间到首个分叉的提前量（需 > 重启耗时） | `30` |
| `--target=FORK` | 推进到哪个分叉为止：`granite`/`holocene`/`isthmus`/`jovian` | `jovian` |
| `-y` | 跳过 `chain-reset` 的不可逆二次确认 | 无 |

验证分叉是否生效：

```bash
cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645
```

---

## 6. Flashblocks 相位切换

`FLASHBLOCKS_MODE` 是**启动初值**，决定 `chain-start.sh` 起哪些组件、以及 op-node 的 Engine
连谁。方案背景与验证门见 `doc/flashblocks_local_impl.md`。

### 6.1 三个相位分别在跑什么

| 相位 | 进程 | op-node 的 `--l2` 指向 | 出块方 |
|---|---|---|---|
| `off` | op-geth、op-node、op-batcher、op-proposer（+ op-challenger） | op-geth `:8651` | op-geth |
| `dry_run` | 上面 + **op-rbuilder**、**rollup-boost** | rollup-boost `:8551` | op-geth；builder payload 只做校验对照 |
| `enabled` | 上面 + **ws-proxy**、**op-reth**、**verifier op-node** | rollup-boost `:8551` | op-rbuilder，产出 200ms flashblocks |

切换过程中还有一个临时相位 **SYNC**：`off` + op-rbuilder + **builder op-node**。builder op-node
只负责把冷启的 op-rbuilder 从 L1 派生 + gossip 追到链头，追平后必须停掉——它和 rollup-boost 都连
op-rbuilder 的同一个 auth RPC，并存会抢引擎驱动权。

> 注意：直接把 `.envrc` 改成 `dry_run` 再 `chain-start`，起的是 op-rbuilder + rollup-boost，
> **不起** builder op-node，也不做任何同步等待——op-rbuilder 靠热 datadir + rollup-boost 的
> Engine 调用跟上。这条路适合**稳态重启**，不适合首次切换（op-rbuilder 是空的，会从零追）。
> 首次切换走 6.2。

### 6.2 `off` → `dry_run`（外科式切换，推荐）

链在 `off` 态跑着的时候执行：

```bash
bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local
```

**op-rbuilder 只起一次、全程不杀**；切换只做"引擎驱动权交接 + op-node 重路由"，op-geth 和
op-rbuilder 全程不动。十步：

1. 预检（off 链在跑、op-geth/op-node 可达、主 op-node p2p 开、bin 就绪、`[9]` 重启安全窗口已到）
2. 起同步节点：op-rbuilder + builder op-node
3. 粗追平（`--lag`，默认 2）
4. `admin_stopSequencer` 冻结主 op-node 出块（进程仍在 → 仍 gossip，保存 head hash 供回滚）
5. 精追平到冻结高度 H
6. 停 builder op-node（交出 op-rbuilder 引擎驱动权）
7. 写 `.envrc` `FLASHBLOCKS_MODE=dry_run`
8. 起 rollup-boost（dry-run 执行模式，接管驱动 op-rbuilder）
9. 只重启主 op-node（`--l2` → rollup-boost）
10. 验证出块推进

| 选项 | 含义 | 默认 |
|---|---|---|
| `--lag=N` | 粗追平判定阈值 | `2` |
| `--timeout=SEC` | 等追平 / 等重启安全窗口的最长秒数 | `1800` |
| `--no-wait` | 重启安全窗口未到时直接失败退出，不等待 | 默认会轮询等待 |

**中断保护**：脚本装了 `EXIT` / `INT` / `TERM` trap，无论是某一步失败、Ctrl-C 还是收到信号，
都会按已推进到的阶段逐层回滚，并明确打印"切换未完成，已回滚"：

| 中断时已推进到 | 回滚动作 |
|---|---|
| `[1]` 预检 | 什么都没启动，直接退出 |
| `[2]`~`[3]` | 停 op-rbuilder + builder op-node |
| `[4]`~`[6]` | 上面 + `admin_startSequencer` 恢复出块 |
| `[7]`~`[8]` | 上面 + 停 rollup-boost + 把 `.envrc` 写回 `off` |
| `[9]` 之后 | 拓扑已切换完成，不回滚 |

回滚后链退回 `off`、不留半吊子状态，确认出块恢复后直接重跑即可，不用重建链。

### 6.3 `dry_run` → `enabled`

两条路，按需要选：

**A. 热切（不断链，秒级）**——只改 rollup-boost 采不采用 builder 块：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
  http://localhost:5555
# 查询当前模式
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"debug_getExecutionMode","params":[]}' \
  http://localhost:5555
```

注意热切**不会**拉起用户面三件套（ws-proxy / op-reth / verifier op-node），也**不会**改 `.envrc`——
下次 `chain-start` 仍按文件里的值走。v0.7.11 没有 `rollup-boost debug` 子命令，只能走这个 JSON-RPC；
JSON 里是 snake_case（`dry_run`），CLI flag 是 kebab-case（`--execution-mode=dry-run`）。

**B. 全量重启（用户面齐全）**：

```bash
$EDITOR .envrc        # FLASHBLOCKS_MODE=enabled
bash scripts/chain-ops/chain-stop.sh
bash scripts/chain-ops/chain-start.sh local
```

op-rbuilder 从热 datadir 恢复，不用重新同步。这条路会重启 op-node，受 6.6 的窗口约束。

### 6.4 回退到 `off`

```bash
$EDITOR .envrc        # FLASHBLOCKS_MODE=off
bash scripts/chain-ops/chain-stop.sh
bash scripts/chain-ops/chain-start.sh local
```

op-node 重新直连 op-geth `:8651`，Flashblocks 组件不再启动。链数据不受影响。
若只是想让 rollup-boost 别再碰 builder，也可以热切成 `disabled`。

### 6.5 观察与验证

```bash
# builder payload 校验结果（dry_run 下应全 VALID）
tail -f data/logs/rollup-boost.log

# 逐块对照 op-geth 与 op-rbuilder
cast block <N> --rpc-url http://localhost:8645 --json | jq '{hash,stateRoot}'
cast block <N> --rpc-url http://localhost:8663 --json | jq '{hash,stateRoot}'

# 订阅 flashblocks 流（约每 250ms 一条）
websocat ws://localhost:1112      # rollup-boost 直出
websocat ws://localhost:1113      # 对外 ws-proxy

# pending 预确认（enabled 态；应在 2s 正式块前就能查到）
cast rpc eth_getBlockByNumber pending true --rpc-url http://localhost:8745
```

### 6.6 op-node 重启安全窗口（devnet 特有，务必了解）

**链跑过 Holocene 激活点之后，任何一次 op-node 重启**（`chain-stop`+`chain-start`、
`activate-fork`、外科式切换的第 `[9]` 步）都受这条约束。

op-node 启动时派生流水线会把 L1 读取起点回退一个 `channel_timeout`（Granite 后 50 个 L1 块，
之前 300），回退撞到 L1 创世就停在创世。若落点早于 Holocene 激活块，`BatchMux` 会装上
pre-Holocene 的 `BatchQueue`，而重放旧 batch 时校验函数按"batch 所在 L1 块已过 Holocene"返回
`BatchPast`——`BatchQueue` 不认识这个值，直接 crit 退出，且每次重启都会复现：

```
derivation failed: crit: unknown batch validity type: 4
```

条件是 safe head 的 L1 origin 要走到 `Holocene/Granite 边界块 + channel_timeout` 之后。
`L1_BLOCK_TIME=6` + `MAX_CHANNEL_DURATION=5` 下，分叉激活后约需 **5~6 分钟**。

`switch-to-flashblocks-dryrun.sh` 的预检会算出这个点并**自动轮询等待**（上限 `--timeout`），
等待发生在启动任何组件之前，链保持 off 不受影响。其它重启路径没有这个保护，需要自己掐时间。

真实主网/测试网不会遇到——那里 safe head 早就远离分叉边界几万个块了。

---

## 7. 停止 / 重建

停止 L2（保留数据与配置，可再 `chain-start`）：

```bash
bash scripts/chain-ops/chain-stop.sh
```

先停 Flashblocks 组件（`stop-flashblocks.sh`，与启动顺序相反），再停
op-challenger / op-proposer / op-batcher / op-node / op-geth。先按 `data/pids/` 里的 PID 停，
再按命令行特征清理 PID 文件被覆盖的残留进程。anvil 不会被停，需要时 `docker stop anvil-chain`。

重建一条全新链（**破坏性、不可逆**）：

```bash
bash scripts/deploy-chain/chain-reset.sh local        # 交互确认；加 -y 跳过
```

会：停 L2 →（local）停 anvil → 删 `data/` → 删 `config/<context>/` →（local）清空 `.envrc` 的
`CUSTOM_GAS_TOKEN_ADDRESS`。之后重新走第 3、4 步，或直接用 5.2 的一键脚本。

---

## 8. 端口一览

来源都是 `.envrc`，改端口只改那里。

| 组件 | 用途 | 端口 | 变量 |
|---|---|---|---|
| anvil | L1 RPC（local） | 8545 | — |
| op-geth | 对外 HTTP RPC | 8645 | `OP_GETH_HTTP_PORT` |
| op-geth | 对外 WS RPC | 8646 | `OP_GETH_WS_PORT` |
| op-geth | Engine / authrpc | 8651 | `OP_GETH_AUTHRPC_PORT` |
| op-node | RPC（含 admin） | 9545 | `OP_ROLLUP_PORT` |
| op-node | CL p2p（gossip 出口） | 9222 | `SEQ_P2P_TCP_PORT` |
| op-batcher | RPC | 9645 | `OP_BATCHER_PORT` |
| op-proposer | RPC | 8560 | 硬编码在 `run-op-proposer.sh` |
| rollup-boost | Engine（op-node 连这里） | 8551 | `RB_ENGINE_PORT` |
| rollup-boost | flashblocks 广播 | 1112 | `RB_FLASHBLOCKS_WS_PORT` |
| rollup-boost | debug server（热切模式） | 5555 | `RB_DEBUG_PORT` |
| op-rbuilder | Engine / authrpc | 8661 | `RBUILDER_AUTHRPC_PORT` |
| op-rbuilder | HTTP RPC | 8663 | `RBUILDER_HTTP_PORT` |
| op-rbuilder | WS RPC | 8664 | `RBUILDER_WS_PORT` |
| op-rbuilder | flashblocks 出口 → rollup-boost | 1111 | `RBUILDER_FB_WS_PORT` |
| op-rbuilder | RLPx | 30313 | `RBUILDER_P2P_PORT` |
| builder op-node | RPC | 9565 | `RBUILDER_OPNODE_PORT` |
| builder op-node | CL p2p | 9223 | `RBUILDER_OPNODE_P2P_TCP_PORT` |
| ws-proxy | 对外 flashblocks 流 | 1113 | `FB_PROXY_PORT` |
| op-reth | 对用户 HTTP RPC | 8745 | `FB_RPC_HTTP_PORT` |
| op-reth | Engine（被 verifier op-node 驱动） | 8751 | `FB_RPC_AUTHRPC_PORT` |
| op-reth | RLPx | 30323 | `FB_RPC_P2P_PORT` |
| verifier op-node | RPC | 9555 | `FB_RPC_OPNODE_PORT` |
| verifier op-node | CL p2p | 9224 | `FB_RPC_OPNODE_P2P_TCP_PORT` |

---

## 9. 命令速查

| 目的 | 命令 |
|---|---|
| 子模块（首次） | `git submodule update --init --recursive` |
| 设置 env | 编辑 `.envrc` → `source .envrc` |
| 编译 Go 组件 | `bash scripts/build-binaries.sh` |
| 编译 Flashblocks 组件 | `bash scripts/flashblocks/build-flashblocks.sh` |
| 部署环境 | `bash scripts/deploy-chain/chain-setup.sh local` |
| 启动 | `bash scripts/chain-ops/chain-start.sh local` |
| 停止 | `bash scripts/chain-ops/chain-stop.sh` |
| 分叉升级 | 改 `.envrc` 的 `FORK_*_TIME` → `bash scripts/deploy-chain/activate-fork.sh local` |
| 一键建 Jovian 链 | `bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y` |
| 切 Flashblocks dry_run | `bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local` |
| 验证 Flashblocks | `bash scripts/flashblocks/verify/run-all.sh`（按当前模式自动挑验证门） |
| dry_run → enabled（热切） | `curl` `debug_setExecutionMode` 到 `:5555`（见 6.3） |
| dry_run → enabled（全量） | 改 `.envrc` → `chain-stop` → `chain-start` |
| 重建（清空重来） | `bash scripts/deploy-chain/chain-reset.sh local [-y]` |

完整闭环：
`chain-reset` → 设置 env → `build-binaries` → `chain-setup` → `chain-start` →
（改 `FORK_*_TIME` → `activate-fork`）\* → `switch-to-flashblocks-dryrun` → `enabled`

---

## 10. 常见故障

| 现象 | 原因与处理 |
|---|---|
| op-node 起来就 `crit: unknown batch validity type: 4` | 重启安全窗口未到，见 6.6。等 safe head 的 L1 origin 追过分叉边界 + `channel_timeout` 再起。 |
| `docker run` 报 `container name "anvil-chain" is already in use` | `--rm` 容器删除是异步的。`chain-setup.sh` / `chain-start.sh` 已有强删 + 等待逻辑；手工遇到就 `docker rm -f anvil-chain`。 |
| 切换脚本预检报 p2p 端口 9222 未监听 | 主 op-node 没带 p2p 起（老配置）。重启一次 off 链让它带上：`chain-stop && chain-start local`。 |
| rollup-boost 起来就 `Invalid URL: relative URL without a base` | v0.7.11 的 `--l2-url` / `--builder-url` 必须带 `http://` scheme。`run-rollup-boost.sh` 已修，自己拼命令行时注意。 |
| op-rbuilder 追不上 / 创世 hash 对不上 | reth 系与 geth 共用同一份 `genesis.json`，先比对创世 hash（`doc/flashblocks_local_impl.md` §5）。 |
| safe head 长期不前进 | 查 `data/logs/op-batcher.log`，通常是 batcher 没在提交或 L1 账户没钱。 |
| `chain-stop` 后仍有残留进程 | 脚本会按命令行特征二次清理；仍残留就 `ps axww \| rg 'op-node\|op-rbuilder\|rollup-boost'` 手动确认。 |
| 切换脚本对着已经是 dry_run 的链再跑 | 预检会检测 rollup-boost 的 `debug_getExecutionMode` 并直接以 0 退出，不会重复起组件。 |
| 单独重启 op-rbuilder 后它卡住不动（`Received block from consensus engine number=N` 但 `latest_block` 停在旧高度、`connected_peers=0`） | flashblocks 拓扑下 op-rbuilder 只由 rollup-boost 通过 Engine API 驱动，而 rollup-boost 只转发当前头部、不回填历史；op-rbuilder 又没有 P2P peer，停机期间的区块缺口没人补，于是永久停滞。**不要单独重启 op-rbuilder**：要重启就走一遍 off → `switch-to-flashblocks-dryrun.sh`，让 `[2]`~`[6]` 的 builder op-node 把缺口同步上再交接。 |
| 把 rollup-boost 切到 `disabled` 之后，切回 `enabled` 也不再出 builder 块，且持续报 `Unknown payload` | 与上一条同源。`disabled` 下 rollup-boost 停止向 builder 发送**所有**请求（含 FCU 和 newPayload），op-rbuilder 会彻底脱链；缺口同样没人回填。实测 12 秒的 `disabled` 就让它落后 30+ 块且无法自愈。**`disabled` 不是无损开关**，不要拿它当降级演练；要验证回退链路，改用 `scripts/flashblocks/verify/p3-enabled.sh` 的默认方式（翻既有日志核对每次 builder 失败是否都回退到了 `context=l2`）。已经切过的，走一遍 off → `switch-to-flashblocks-dryrun.sh` 重建。 |
| 脚本报 `XXX�: unbound variable`（变量名尾部有乱码字节） | bash 3.2 在 UTF-8 locale 下会把紧跟 `$VAR` 的全角字符首字节吃进变量名，配合 `set -u` 直接退出。写法上 `$VAR` 后紧跟中文/全角字符时必须用 `${VAR}`。自检：`rg --glob 'scripts/**/*.sh' '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]'` 应无输出。 |

相关文档：`scripts/flashblocks/verify/README.md`（验证脚本用法与判定口径）、
`doc/flashblocks_local_impl.md`（Flashblocks 方案与验证门）、
`doc/LOCAL_CGT_JOVIAN_UPGRADE_RUNBOOK.md`（本地 CGT+Jovian runbook）、
`doc/remote_l1_cgt_jovian_deploy_runbook.md`（远端 L1 部署 runbook）。
