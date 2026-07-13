# 设计文档：chain-start 编排层重构（调用 run-op-* 单组件脚本）

- 日期：2026-07-07
- 状态：待实现（已通过 brainstorming 评审）
- 范围：仓库根 `scripts/` 下的启动/停止脚本与相关文档，**不涉及 `optimism/` 子模块源码**
- 提交策略：由用户本人提交，本设计与后续实现均**不自动 commit**

---

## 1. 背景与动机

当前项目存在**两套并行的组件启动逻辑**：

1. `scripts/chain-start.sh`：一键编排脚本，内部**内联**了 op-geth / op-node / op-batcher / op-proposer 四个组件的完整命令行 flags，并负责 anvil、JWT、`op-geth init`、就绪等待、PID/日志管理。
2. `scripts/run-op-geth.sh` / `run-op-node.sh` / `run-op-batcher.sh` / `run-op-proposer.sh`：四个"单组件"启动脚本，各自也维护了一份组件 flags，供单独调试/重启使用。

两套 flags 各写一份，**没有单一真源**，已经产生实际漂移：

| 组件 | chain-start.sh 现值 | run-op-*.sh 现值 | 问题 |
|------|--------------------|------------------|------|
| op-proposer | `--game-type=${GAME_TYPE:-0}` (第154行) | `--game-type=${GAME_TYPE:-1}` (第12行) | 默认值不一致，permissioned/permissionless 起步语义相反 |
| op-geth | 编排层带 `if [ ! -d geth ]` 的幂等 init | 无条件 `op-geth init`（第10行） | 单跑脚本每次都会尝试 init |

维护负担与漂移风险随组件 flags 演进只增不减。用户已明确观察到此问题，并提出方向：**让 `chain-start.sh` 直接调用这四个 `run-op-*.sh`，把组件 flags 收敛为单一真源。**

---

## 2. 目标与非目标

### 2.1 目标

1. **单一真源**：每个组件的运行时 flags 只在其 `run-op-<c>.sh` 中定义一处；`chain-start.sh` 不再内联组件 flags。
2. **分层清晰**：
   - `chain-start.sh` = 编排层（environment 装配 + 生命周期管理）。
   - `run-op-<c>.sh` = 纯组件启动器（只负责"用正确 flags 起这一个进程"）。
3. **消除已知漂移**：统一 proposer `--game-type` 默认值、统一 `op-geth init` 的归属。
4. **命名统一**：把脚本与文档中的 `local/server` 二元命名统一为 `local/remote`（用户明确要求）。
5. **行为等价**：重构后由 `chain-start.sh` 起的四个进程命令行，与重构前**逐字等价**（除刻意消除的漂移点，见 §5）。

### 2.2 非目标

1. **不改 `optimism/` 子模块**任何源码（子模块在部署时会被 `git checkout` 重置，改了也会丢）。
2. **不改编排层已验证的核心逻辑**：anvil 启动、JWT 生成、`op-geth init` 幂等判定、就绪等待、PID/日志管理、`config/<context>/` 配置加载路径，全部保留。
3. **不引入新的进程管理框架**（不上 systemd/supervisor/docker-compose 等）。
4. **不改 flags 的运行时语义**（端口、私钥、DA 类型等一律以 `chain-start.sh` 当前值为基准）。
5. **不做无关重构**（不顺手重排目录、不改无关脚本风格）。

---

## 3. 架构与职责

### 3.1 分层图

```
                bash scripts/chain-start.sh [local|remote]
                                │
          ┌─────────────────────┴──────────────────────┐
          │            编排层（chain-start.sh）           │
          │  - local/remote 解析、anvil（仅 local）        │
          │  - config/<context>/ 配置路径装配 + export     │
          │  - JWT 生成、op-geth init（仅首次，幂等）        │
          │  - 就绪等待、PID 记录、日志重定向               │
          └───┬──────────┬───────────┬──────────┬────────┘
              │ export env + nohup ... &         │
     ┌────────▼───┐ ┌────▼─────┐ ┌───▼──────┐ ┌─▼──────────┐
     │run-op-geth │ │run-op-   │ │run-op-   │ │run-op-      │
     │   .sh      │ │ node.sh  │ │batcher.sh│ │proposer.sh │
     │（纯启动器） │ │（纯启动器）│ │（纯启动器）│ │（纯启动器）  │
     └─────┬──────┘ └────┬─────┘ └────┬─────┘ └─────┬──────┘
           │ exec        │ exec       │ exec        │ exec
        op-geth       op-node     op-batcher    op-proposer
```

单独调试时也可直接 `bash scripts/run-op-<c>.sh`（前提：已 `chain-setup` 生成配置、已有 JWT 与 geth datadir）。

### 3.2 职责边界

| 职责 | 归属 | 说明 |
|------|------|------|
| local/remote 识别 | chain-start | 单跑脚本不做环境识别 |
| anvil 启停 | chain-start（仅 local） | run-op-* 不碰 L1 |
| 配置路径装配（`DEPLOYMENT_CONFIG_PATH`、genesis/rollup/artifact） | chain-start，通过 export 下传 | run-op-* 只消费 |
| JWT 生成 | chain-start | run-op-* 只读 JWT 文件 |
| `op-geth init` | chain-start（幂等，仅首次） | **从 run-op-geth 移除** |
| 就绪等待（geth engine RPC） | chain-start | run-op-* 不等待 |
| PID/日志 | chain-start（`nohup ... & ; echo $! > pid`） | run-op-* 用 `exec`，PID 即组件进程 |
| **组件 flags 定义** | **run-op-<c>.sh（唯一真源）** | chain-start 不再内联 |

---

## 4. 环境传递约定

`chain-start.sh` 与 `run-op-*.sh` 都会 `source .envrc`。冲突点在于：编排层会对若干变量做**运行期覆盖**（如 local 把 `L1_RPC_URL` 改成 `http://localhost:8545`、把配置路径指向 `config/<context>/`）。若 run-op-* 重新 source 后用 `.envrc` 原值，会与编排层不一致。

### 4.1 约定：编排层覆盖值优先，`.envrc` 兜底

采用 `_CALLER_*` 传递模式：编排层把已覆盖的关键变量以 `_CALLER_<VAR>` 形式 export；run-op-* 在 `source .envrc` 之后，用"调用方值优先，否则用 .envrc 值"的方式取值。

run-op-* 中的取值范式（示例）：

```bash
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
# 配置文件（rollup/artifact）兜底从 config/<context>/ 派生，而非 .envrc 默认的 deployments 产物：
OP_NODE_ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"
DEPLOYMENT_OUTFILE="${_CALLER_DEPLOYMENT_OUTFILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/artifact.json}"
```

- 由 `chain-start` 调起：`_CALLER_*` 已 export，取到编排层覆盖后的正确值（config 目录）。
- 单独 `bash scripts/run-op-<c>.sh` 运行：`_CALLER_*` 为空，配置文件兜底仍从 `config/<context>/` 派生（与编排层一致）。

> **关键**：`.envrc` 里 `OP_NODE_ROLLUP_FILE` / `DEPLOYMENT_OUTFILE` / `OP_GETH_GENESIS_FILE` 默认指向
> `optimism/packages/contracts-bedrock/deployments/`（部署构建的**原始产物**）。而 `chain-start.sh` 以及本项目
> 运行期统一使用 `config/<context>/`（git 跟踪、经 runbook patch 的**规范配置**）。因此 run-op-* 的兜底
> **不能**直接回落到 `.envrc` 的 `$OP_NODE_ROLLUP_FILE`，必须从 `DEPLOYMENT_CONFIG_PATH`（= config 目录）重新派生。

### 4.2 需要经 `_CALLER_*` 下传的变量清单

编排层运行期会覆盖或计算、且 run-op-* 需要的变量：

| 变量 | 编排层来源 | 消费方 |
|------|-----------|--------|
| `L1_RPC_URL` | local 覆盖为 `http://localhost:8545` | node / batcher / proposer |
| `DEPLOYMENT_CONFIG_PATH` | `config/$DEPLOYMENT_CONTEXT` | geth / node |
| `OP_GETH_GENESIS_FILE` | `$DEPLOYMENT_CONFIG_PATH/genesis.json` | geth（init 已在编排层，仅备用） |
| `OP_NODE_ROLLUP_FILE` | `$DEPLOYMENT_CONFIG_PATH/rollup.json` | node |
| `DEPLOYMENT_OUTFILE` | `$DEPLOYMENT_CONFIG_PATH/artifact.json` | proposer（读取 factory/l2oo 地址） |
| `OP_GETH_DATA_PATH` | `$DATA_DIR/op-geth` | geth（datadir、jwt） |
| `JWT_FILE` | `$OP_GETH_DATA_PATH/jwt.txt` | geth / node |
| `SAFEDB_PATH` | `$DATA_DIR/op-node/safedb` | node |

> 说明：`GAME_TYPE`、`USE_FAULT_PROOFS`、`PROPOSAL_INTERVAL`、各 `GS_*` 私钥等来自 `.envrc` 且编排层不覆盖，run-op-* 直接用 `.envrc` 值即可，无需 `_CALLER_*`。

---

## 5. 组件级改动（run-op-*.sh 成为 flags 唯一真源）

原则：以 `chain-start.sh` **当前**内联 flags 为基准，逐字迁入对应 run-op-*，仅在下列"刻意消除的漂移点"处统一取值。

### 5.1 run-op-geth.sh

- **移除** `op-geth init` 段（第 7–10 行）：init 由编排层幂等负责；单跑前提是 datadir 已初始化。
- flags 与 chain-start 第 111 行对齐（当前二者实质等价，jwt 路径均为 `$OP_GETH_DATA_PATH/jwt.txt`）。
- **fork override 扩展点**：flags 末尾追加 `${OP_GETH_OVERRIDE_FLAGS:-}`，用于 jovian 等硬分叉时间覆盖（见 §6.2）。
- 结尾用 `exec op-geth $flags`，保证 PID 是 op-geth 本体。
- 加环境保护：`source .envrc` 后按 §4.1 取 `_CALLER_*` 优先值。

### 5.2 run-op-node.sh

- flags 与 chain-start 第 132 行对齐（当前二者已等价：jwt=`$BASE_PATH/data/op-geth/jwt.txt`、safedb 默认 `$BASE_PATH/data/op-node/safedb`）。
- 按 §4.1 取 `L1_RPC_URL`、`OP_NODE_ROLLUP_FILE`、`SAFEDB_PATH`、jwt 路径的 `_CALLER_*` 优先值。
- 结尾 `exec op-node $flags`。

### 5.3 run-op-batcher.sh

- flags 与 chain-start 第 142 行对齐（当前二者已逐字等价，无漂移）。
- 按 §4.1 取 `L1_RPC_URL` 的 `_CALLER_*` 优先值。
- 结尾 `exec op-batcher $flags`。

### 5.4 run-op-proposer.sh

- flags 与 chain-start 第 153–155 行对齐。
- **消除漂移点**：`--game-type` 默认值统一为 `${GAME_TYPE:-1}`（permissioned 起步，与 `.envrc` 的 `GAME_TYPE=1`、部署时 `respectedGameType=1` 一致）。即以 run-op-proposer 现值 `:-1` 为准，**chain-start 内联的 `:-0` 将被本重构删除**（因为该分支整体迁走）。
- 按 §4.1 取 `L1_RPC_URL`、`DEPLOYMENT_OUTFILE` 的 `_CALLER_*` 优先值。
- 保留已加的 anchor 说明注释。
- 结尾 `exec op-proposer $flags`。

### 5.5 chain-start.sh（编排层）

**保留**：`local/remote` 解析、anvil（仅 local）、`config/<context>/` 配置装配与 export、JWT 生成、`op-geth init`（幂等仅首次）、geth engine 就绪等待、`SKIP_BATCHER`/`SKIP_PROPOSER` 开关、PID/日志。

**替换**：把四段内联 `nohup op-<c> $FLAGS >> log &` 改为：

```bash
# 下传编排层覆盖后的关键变量
export _CALLER_L1_RPC_URL="$L1_RPC_URL"
export _CALLER_DEPLOYMENT_OUTFILE="$DEPLOYMENT_OUTFILE"
export _CALLER_OP_NODE_ROLLUP_FILE="$OP_NODE_ROLLUP_FILE"
export _CALLER_SAFEDB_PATH="$SAFEDB_PATH"
# ...（按 §4.2 清单）

nohup bash "$SCRIPT_DIR/run-op-geth.sh" >> "$LOG_DIR/op-geth.log" 2>&1 &
echo $! > "$PID_DIR/op-geth.pid"
```

四个组件同此模式。由于 run-op-* 用 `exec`，`$!` 记录的 PID 最终即组件进程本体，`chain-stop.sh` 的 PID 与特征匹配保持有效（见 §6.1）。

### 5.6 local/server → local/remote 改名

- `chain-start.sh` / `chain-setup.sh`：`CHAIN_ENV` 取值、用法提示、注释中的 `server` → `remote`；自动识别分支的 else 分支赋值 `CHAIN_ENV=remote`。
- `chain-stop.sh`：文案中 `server` → `remote`（无功能逻辑依赖该字面量）。
- **不保留 `server` 兼容别名**（已定稿）：直接切到 `local/remote`，老命令 `... server` 将报用法错误。README 需标注此破坏性变更。参数校验分支只接受 `local` / `remote`，自动识别的 else 分支赋值 `CHAIN_ENV=remote`。

---

## 6. 兼容性

### 6.1 chain-stop.sh 兼容

`chain-stop.sh` 两条路径：
1. 读 `$PID_DIR/<c>.pid` 精确 kill —— 因 run-op-* 用 `exec`，`$!` 就是组件 PID，**仍有效**。
2. 按进程特征兜底匹配（`--datadir=`、`--safedb.path=`、`--rollup-rpc= + --rpc.port=` 等）—— flags 迁入 run-op-* 后这些特征**原样保留**，匹配**仍有效**。

⚠️ 校验点：确保 run-op-* 迁移后仍带 chain-stop 依赖的特征串（proposer 的 `--rpc.port=8560`、batcher 的 `--rpc.port=$OP_BATCHER_PORT`/`--rollup-rpc=`、node 的 `--safedb.path=`、geth 的 `--datadir=`）。§7 逐字等价校验覆盖此点。

### 6.2 jovian fork-override 兼容

`scripts/jovian/README.md` 现有一段 Python 教程，直接**文本 patch** `chain-start.sh` 的 `OP_GETH_FLAGS` 行插入 `--override.*`（对应 chain-start 第 112–113 行被注释的示例）。重构后 flags 不再在 chain-start，需改注入点：

**采用方案（环境变量注入）**：
- run-op-geth flags 末尾追加 `${OP_GETH_OVERRIDE_FLAGS:-}`（见 §5.1）。
- jovian 教程改为：把 override flags 写入 `.envrc` 的 `export OP_GETH_OVERRIDE_FLAGS="--override.fjord=... --override.jovian=..."`（Python 用 sed/正则更新 `.envrc` 中该变量，而非 patch 脚本行）。
- 好处：注入目标从"脚本某行"变为"一个环境变量"，与 flags 真源解耦，chain-start / run-op-geth 单跑都生效。

### 6.3 文档更新

- `README.md`：`server` → `remote` 术语；补充"直接跑 `run-op-<c>.sh` 的前提（先 chain-setup、需已有 JWT/datadir）"。
- `scripts/jovian/README.md`：改为 §6.2 的 `OP_GETH_OVERRIDE_FLAGS` 注入方式。

---

## 7. 验证计划

1. **逐字等价校验（核心）**：分别在重构前后，用 `set -x` 或在 run-op-* 的 `exec` 前 `echo` 出最终命令行，对 geth/node/batcher/proposer 四条命令做 **diff**。除以下刻意差异外必须完全一致：
   - proposer `--game-type` 统一为 `1`（消除漂移）。
   - geth 不再由启动器 init。
2. **端到端**：`bash scripts/chain-start.sh local` 全新拉起 → 四进程存活、op-geth 出块、op-batcher 提交、op-proposer 成功建 game（不再 `AnchorRootNotFound`）。
3. **停止**：`bash scripts/chain-stop.sh` 四进程全部被回收（PID 路径 + 特征匹配都验证）。
4. **单跑回归**：单独 `bash scripts/run-op-<c>.sh`（`_CALLER_*` 为空）能用 `.envrc` 值起对应组件。
5. **jovian 注入**：设置 `OP_GETH_OVERRIDE_FLAGS` 后，geth 命令行末尾正确带上 `--override.*`。
6. **幂等**：重复 `chain-start` 不重复 init geth datadir、不重复生成 JWT。

---

## 8. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| 迁移遗漏某个 flag，导致组件行为变化 | 出块/提交/建 game 失败 | §7.1 逐字 diff 强制等价 |
| `_CALLER_*` 传递遗漏，run-op-* 用错 `.envrc` 原值（如 local 下 L1_RPC_URL） | 连错 L1 | §4.2 清单逐项 export；§7.4 单跑用例覆盖回落路径 |
| chain-stop 特征串因迁移变动而匹配失败 | 残留进程 | §6.1 校验点 + §7.3 停止用例 |
| `exec` 使用不当导致 PID 记录错位 | chain-stop 杀不掉 | 每个 run-op-* 结尾 `exec`，`$!` 即组件 PID；§7.3 验证 |
| local/server 改名（不保留别名）破坏现有 `... server` 调用 | 调用报错 | README 显著标注破坏性变更；仓库内全局 grep `server` 调用点一并更新 |
| jovian 教程改注入点后旧 patch 失效 | fork override 不生效 | 同步更新 `scripts/jovian/README.md`；§7.5 验证 |

---

## 9. 已定稿决策

1. proposer `--game-type` 默认统一为 `1`（permissioned 起步）。
2. `local/server` → `local/remote`，**不保留 `server` 兼容别名**。

（所有开放项均已确认，设计定稿。）
