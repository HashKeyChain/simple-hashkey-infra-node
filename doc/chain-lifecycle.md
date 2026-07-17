# 链生命周期操作手册

一条 HashKey / OP Stack 定制链（CGT + Jovian）从零到运行、再到推进分叉、重建的**命令手册**。
每一步基本对应一个脚本，按顺序执行即可。

```
设置 env → 编译 → 部署环境 → 启动 → (分叉升级)* → 停止 / 重建
 .envrc    build   chain-setup  chain-start  activate-fork   chain-stop / chain-reset
```

> 所有命令在仓库根目录执行；脚本内部会 `source .envrc`。示例用 `local`（本地 anvil）；
> 远端真实 L1 把参数换成 `remote` 即可。

> **脚本目录约定**（2026-07 起）：
> - `scripts/deploy-chain/` —— 部署一条链相关：`chain-setup`、`deploy-contracts`、
>   `patch-rollup-config`、`deploy-multicall3`、`activate-fork`、`chain-reset`，
>   以及一键脚本 `deploy-jovian-chain.sh`。
> - `scripts/chain-ops/` —— 启动/停止链相关：`chain-start`、`chain-stop`、各 `run-op-*`、`run-anvil`。
> - `scripts/`（根）保留通用脚本：`build-binaries`、`bridge-to-l2*`、`upgrade-systemconfig*`；`scripts/jovian/` 不变。

---

## 快速通道：一键部署并推进到 Jovian

不想手动跑第 3~5 步、也不想手改 `FORK_*_TIME` 时，用一键脚本：**部署到 fjord 基线 → 起链 →
按当前 L2 时间自动计算各分叉激活时间（每档间隔 2s）→ 停链/同步 rollup/重启 → 等待并校验分叉激活**。

```bash
# 全新本地链，一路推进到 Jovian（--reset 会先清空 data/ 与 config/<ctx>/）
bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

常用选项：

| 选项 | 说明 | 默认 |
|---|---|---|
| `--reset` | 先 `chain-reset`（停链+删 data+删 config+清 CGT 地址）部署全新链；对已存在的链必须加 | 关 |
| `-y` / `--yes` | 传给 `chain-reset`，跳过不可逆二次确认 | 关 |
| `--pace=SEC` | 相邻分叉激活间隔秒数 | `2` |
| `--lead=SEC` | 从当前 L2 时间到首个待激活分叉的提前量（需 > 重启耗时） | `30` |
| `--target=FORK` | 推进到哪个分叉为止：`granite`\|`holocene`\|`isthmus`\|`jovian` | `jovian` |

> 为什么要走"时间激活"而不是直接生成 Jovian 创世：目前"部署时即 Jovian 分叉"的代码尚未开发，
> 只能部署到 fjord 基线后用运行时 override 按时间戳推进。分叉时间唯一真源仍是 `.envrc` 的
> `FORK_*_TIME`，脚本会现场计算并写回，再复用 `chain-setup`/`chain-start`/`activate-fork`。
> 未加 `--reset` 且检测到已存在 `data/` 或 `config/<ctx>/` 时脚本会拒绝执行，避免脏状态。

下面第 1~6 节是等价的手动分解流程，需要精细控制或排障时使用。

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
bash scripts/deploy-chain/chain-setup.sh local
```

它会：本地无 anvil 时自动起 anvil → 给账户充值 → 部署 Multicall3（local）→ 部署 OP L1 合约 +
CGT → 生成 `config/<context>/` 下的 `artifact.json` / `genesis.json` / `rollup.json` /
`state-dump-latest.json` → 自动调用 `patch-rollup-config.sh` 修正 rollup.json（含把
`FORK_*_TIME` 同步进 `*_time`，初始为纯-fjord）。

> 远端：`bash scripts/deploy-chain/chain-setup.sh remote`（用 `.envrc` 的真实 `L1_RPC_URL`，不起 anvil）。

---

## 4. 启动全部服务

```bash
bash scripts/chain-ops/chain-start.sh local
```

启动 `op-geth`、`op-node`、`op-batcher`、`op-proposer`，FP 模式下还有 `op-challenger`。
日志在 `data/logs/`，PID 在 `data/pids/`。

快速验证：

```bash
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp}'
```

单独重启某个组件（可选）：`bash scripts/chain-ops/run-op-geth.sh` 等（需先 setup + 已 init）。

---

## 5. 分叉升级（在运行中的链上推进硬分叉）

初次启动只有 fjord。要激活后续分叉：

```bash
# 1) 编辑 .envrc，把要激活的分叉填成目标 unix 时间戳（建议取"当前+N秒"以便观察过渡）：
#    export FORK_GRANITE_TIME=<ts>
#    export FORK_HOLOCENE_TIME=<ts>   # 依需要
#    ...
# 2) 一键推进（自动：停 L2 → 同步 rollup.json → 重启 L2）：
bash scripts/deploy-chain/activate-fork.sh local
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
bash scripts/chain-ops/chain-stop.sh
```

重建一条全新链（**破坏性、不可逆**）：

```bash
bash scripts/deploy-chain/chain-reset.sh local        # 交互确认；加 -y 跳过
```

`chain-reset.sh` 会：停 L2 →（local）停 anvil → 删 `data/` → 删 `config/<context>/` →
（local）清空 `.envrc` 的 `CUSTOM_GAS_TOKEN_ADDRESS`。之后重新走第 3、4 步即可。

---

## 7. 单独运行组件 / op-challenger

`scripts/chain-ops/run-op-<component>.sh` 是各组件 flags 的**唯一真源**，既被 `chain-start.sh`
编排调用，也可单独运行用于调试/重启。单独运行前需先 `chain-setup` 生成配置、且 op-geth datadir
已初始化、JWT 已生成（首次由 `chain-start.sh` 幂等完成）。

```bash
bash scripts/chain-ops/run-op-geth.sh       # 不再执行 op-geth init，需 datadir 已初始化
bash scripts/chain-ops/run-op-node.sh
bash scripts/chain-ops/run-op-batcher.sh
bash scripts/chain-ops/run-op-proposer.sh
```

op-challenger（仅 `USE_FAULT_PROOFS=true`；`chain-start.sh` 会自动拉起，可用
`SKIP_CHALLENGER=1` 跳过）：

```bash
bash scripts/chain-ops/run-op-challenger.sh              # 前台
bash scripts/chain-ops/run-op-challenger.sh --background # 后台，写 data/pids、data/logs
```

要点：

- 需已构建 `bin/cannon`、`bin/op-program`、`bin/prestate.json`（`build-binaries.sh` 在 FP 模式下构建）。
- `trace-type` 跟随 `GAME_TYPE`：`1`→`permissioned`、`0`→`cannon`，须与部署时 `respectedGameType`
  及 op-proposer 的 `--game-type` 一致。
- prestate 一致性：启动前校验 `bin/prestate-proof.json` 的 `.pre` == deploy-config 的
  `faultGameAbsolutePrestate`，不一致直接报错退出。官方 tag 快照不含本链 CGT/Jovian 定制，
  要真正参与 dispute 需用含相同定制的 op-program 重建 prestate。
- permissioned 模式下 challenger 地址必须是部署时授权的地址，用 `OP_CHALLENGER_PRIVATE_KEY` 覆盖。

---

## 8. （可选）bridge CGT 到 L2 + 验证 Jovian 费用

一键脚本只推进到分叉激活；若要一条**能发交易、能验费**的链，需把自定义 gas token 桥到 L2。

```bash
# 桥入 gas token（CGT 链用 depositERC20Transaction，普通 ETH 存款不能充 L2 原生 gas）
bash scripts/bridge-to-l2.sh 100ether

# 等派生：unsafe_l1 追上包含该存款的 L1 区块
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | jq '.result | {unsafe_l2:.unsafe_l2.number, safe_l2:.safe_l2.number,
    unsafe_l1:.unsafe_l2.l1origin.number, safe_l1:.safe_l2.l1origin.number}'

# 查 L2 原生余额
cast balance "$DEPLOY_ADDRESS" --rpc-url http://localhost:8645
```

余额到账后验证 Jovian 费用行为：

```bash
bash scripts/jovian/verify-jovian-fees.sh
```

校验点：`GasPriceOracle.isFjord/isIsthmus/isJovian`、`OperatorFeeVault` 有代码、普通交易成功、
receipt 含 `operatorFeeScalar/operatorFeeConstant` 与 `daFootprintGasScalar/blobGasUsed`、
（若 operator fee 参数非零）`OperatorFeeVault` 余额增长。`scripts/jovian/` 下还有一批 SystemConfig
参数设置/查询脚本（`set-eip1559-params`、`set-min-base-fee`、`set-operator-fee` 等）。

---

## 9. 排障速查

```bash
# 各组件日志
ls data/logs/                    # op-geth.log / op-node.log / op-batcher.log / ...

# 分叉激活是否被 sequencing
grep -aoE "Sequencing (Granite|Holocene|Isthmus|Jovian) upgrade block" data/logs/op-node.log | sort -u

# op-node 报错
grep -aE "lvl=erro|lvl=crit" data/logs/op-node.log | tail

# 同步进度（unsafe/safe/finalized 应推进，不应长期冻结）
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | jq '.result | {unsafe_l2:.unsafe_l2.number, safe_l2:.safe_l2.number}'

# 分叉标志
cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645
```

常见问题：

- **8645 连接被拒**：op-geth 未运行。若刚跑完一键脚本却连不上，通常是守护进程随一次性 shell/CI
  会话被回收；数据仍在，`bash scripts/chain-ops/chain-start.sh local` 即可恢复（在你自己的终端里跑更稳）。
- **本地必须开 Docker**：anvil 以容器方式启动；Docker 没运行会卡在等待 L1。
- **不停 anvil**：`chain-setup` 与 `chain-start` 之间不要停 anvil，否则 L1 创世 hash 变化；
  重启 anvil 后需重跑 `chain-setup local`。

---

## 命令速查

| 目的 | 命令 |
|---|---|
| 子模块（首次） | `git submodule update --init --recursive` |
| 设置 env | 编辑 `.envrc` → `source .envrc` |
| 编译 | `bash scripts/build-binaries.sh` |
| 部署环境 | `bash scripts/deploy-chain/chain-setup.sh local` |
| 启动 | `bash scripts/chain-ops/chain-start.sh local` |
| 停止 | `bash scripts/chain-ops/chain-stop.sh` |
| 分叉升级 | 改 `.envrc` 的 `FORK_*_TIME` → `bash scripts/deploy-chain/activate-fork.sh local` |
| 重建（清空重来） | `bash scripts/deploy-chain/chain-reset.sh local [-y]` |
| **一键部署到 Jovian** | `bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y` |
| bridge + 验证费用 | `bash scripts/bridge-to-l2.sh 100ether` → `bash scripts/jovian/verify-jovian-fees.sh` |

完整闭环：
`chain-reset` → 设置 env → `build-binaries` → `chain-setup` → `chain-start` →（改 FORK_*_TIME →`activate-fork`）\*
