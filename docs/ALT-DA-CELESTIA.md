# Alt-DA (Celestia) 接入改造说明

本文档记录把本仓库从 **L1 calldata/blob DA** 切换到 **Celestia Alt-DA** 所做的全部改动，与原始仓库行为的差异点，以及排错过程中遇到的坑与对应修复。

- 适用分支: `alt-da`
- 适配的 op-node / op-batcher: **新版（字段已从 `plasma_config` 重命名为 `alt_da`）**
- DA 层: Celestia（通过 `celestia/op-alt-da` 提供的 DA Server，默认监听 `http://localhost:3100`）
- 本改动 **完全向后兼容**：不设置 `USE_ALT_DA` 或设为 `false` 时，所有脚本与原仓库行为一致。

---

## 1. 架构对比

### 改造前（默认，calldata / blobs）

```
L2 Block
  └─► op-batcher ──(rlp-encoded channel as L1 tx calldata or blob)──► L1 (Ethereum)
                                                                         │
                                                                         ▼
                                                                      op-node 直接从 L1 calldata/blob 读
```

### 改造后（alt-DA / Celestia）

```
L2 Block
  └─► op-batcher
        ├── ① PUT blob ──► Celestia DA Server (http://localhost:3100) ──► Celestia
        │                              │
        │                     ② return commitment (~32 bytes)
        │
        └── ③ send commitment as calldata ──► L1 (anvil / Sepolia 等)
                                              │
                                              ▼
                                           op-node 看到 commitment
                                              │
                                              ▼
                                     ④ GET blob from DA Server ──► 还原出 L2 channel
```

关键点：
- L1 上只走 **几十字节的 commitment**，实际 batch 数据落在 Celestia。
- op-batcher 的 `--data-availability-type` **只能是 `calldata`**（`blobs` / `auto` 会被源码显式拒绝）。
- Celestia 采用 **GenericCommitment** 类型，op-node 不再做链上 challenge，因此不需要部署 DAC（DataAvailabilityChallenge）合约。

---

## 2. 修改清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `.envrc` | 修改 | `OP_BATCHER_DATA_AVAILABILITY_TYPE` 从 `blobs` 改为 `calldata`，并新增 8 个 `ALT_DA_*` 变量 |
| `.envrc.example` | 新增配置段 | 为后续克隆仓库的人提供模板（默认 `USE_ALT_DA=false`） |
| `scripts/chain-start.sh` | 修改 | 注入 `alt_da` 字段到 rollup.json；op-node / op-batcher 启动参数按条件追加 `--altda.*`；强制 batcher 用 `calldata`；日志级别改为可配置 |
| `scripts/run-op-node.sh` | 修改 | 条件追加 `--altda.*` |
| `scripts/run-op-batcher.sh` | 修改 | 条件追加 `--altda.*`；日志级别可配置 |
| `config/local/rollup.json` | 自动维护 | 由 `chain-start.sh` 在启动时自动补 `alt_da`，并清理旧字段 |

原仓库里的 **关键缺失**：op-node / op-batcher 虽然支持 `--altda.*` flags，但脚本没有暴露；并且 rollup.json 里缺 `alt_da` 字段，直接启用会报 `no altDA config`。

---

## 3. 环境变量差异

### 3.1 新增（默认关闭，与原仓库行为一致）

```bash
# 主开关：true = 启用 Alt-DA，所有 alt-DA 相关脚本行为生效
export USE_ALT_DA=false

# DA Server 地址（celestia/op-alt-da 服务）
export ALT_DA_SERVER=http://localhost:3100

# Celestia 使用 service 模式（DA Server 生成 commitment 返回给 batcher）
export ALT_DA_DA_SERVICE=true

# 读取 blob 时是否校验 commitment（默认 true）
export ALT_DA_VERIFY_ON_READ=true

# 并发 DA 请求上限
export ALT_DA_MAX_CONCURRENT_REQUESTS=1

# commitment 类型：
#   "GenericCommitment" (Celestia / 外部 DA) -> 无链上 challenge
#   "KeccakCommitment"  (传统 DAC 模式)     -> 需要 da_challenge_contract_address
export ALT_DA_COMMITMENT_TYPE=GenericCommitment

# Challenge / resolve 窗口（L1 区块数）
# GenericCommitment 模式下不会真的触发 challenge，
# 但 op-node 源码校验这两个值必须 > 0
export ALT_DA_CHALLENGE_WINDOW=16
export ALT_DA_RESOLVE_WINDOW=16
```

### 3.2 修改（原有变量）

| 变量 | 原默认值 | 启用 Alt-DA 后必须 |
|---|---|---|
| `OP_BATCHER_DATA_AVAILABILITY_TYPE` | `calldata` / `blobs`（用户可选） | **必须 `calldata`**（`blobs` / `auto` 会被源码拒绝） |

> `scripts/chain-start.sh` 已经加了兜底：即使用户 env 里是 `blobs`，当 `USE_ALT_DA=true` 时脚本也会强制覆盖为 `calldata`，并打印 warning。

### 3.3 新增（日志控制）

| 变量 | 默认 | 说明 |
|---|---|---|
| `OP_BATCHER_LOG_LEVEL` | `info` | 原脚本写死 `debug`，实测 3 分钟写 769MB，默认降为 `info`；需要排错时 `export OP_BATCHER_LOG_LEVEL=debug` |

---

## 4. 启动参数差异

### 4.1 `op-node`

**原** CLI：
```
--log.level=info --rpc.addr=0.0.0.0
--l1=... --l1.rpckind=... --l2=... --l2.jwt-secret=...
--sequencer.enabled --p2p.disable --rpc.enable-admin
--p2p.sequencer.key=... --sequencer.l1-confs=5 --verifier.l1-confs=4
--rollup.config=... --l1.beacon.ignore --safedb.path=...
```

**新增**（仅 `USE_ALT_DA=true` 时）：
```
--altda.enabled=true
--altda.da-server=http://localhost:3100
--altda.da-service=true
--altda.verify-on-read=true
--altda.max-concurrent-da-requests=1
```

### 4.2 `op-batcher`

**原** CLI：
```
--log.level=debug                                      ← 改为 --log.level=${OP_BATCHER_LOG_LEVEL:-info}
--l1-eth-rpc=... --l2-eth-rpc=... --rollup-rpc=...
--rpc.port=...  --private-key=...
--max-channel-duration=300 --poll-interval=6s --sub-safety-margin=10
--resubmission-timeout=48s --max-l1-tx-size-bytes=1000
--data-availability-type=${OP_BATCHER_DATA_AVAILABILITY_TYPE:-calldata}
--txmgr.max-retries=2 --rpc.enable-admin --network-timeout=600s
--num-confirmations=1 --safe-abort-nonce-too-low-count=3
```

**新增/变更**（仅 `USE_ALT_DA=true` 时）：
```
--data-availability-type=calldata      ← 脚本强制覆盖
--altda.enabled=true
--altda.da-server=http://localhost:3100
--altda.da-service=true
--altda.verify-on-read=true
--altda.max-concurrent-da-requests=1
```

### 4.3 op-geth / op-proposer

**没有改动**。alt-DA 对 L2 执行层与 L2 output 提交无影响。

---

## 5. `rollup.json` 字段自动维护

`scripts/chain-start.sh` 在每次启动时都会对 `OP_NODE_ROLLUP_FILE` 做三件事：

| 操作 | 触发条件 |
|---|---|
| 删除顶层字段 `da_challenge_contract_address`（旧版残留，新版 op-node 不认） | 文件中该字段存在 |
| 删除顶层字段 `plasma_config`（老字段，新版 op-node 报 `unknown field`） | 文件中该字段存在 |
| 注入 `alt_da` 对象 | `USE_ALT_DA=true` 且字段缺失 / 类型不匹配 / 窗口为 0 |

最终 `alt_da` 的结构（来自 `bin/op-node` 符号表反编译）：

```json
{
  "alt_da": {
    "da_commitment_type": "GenericCommitment",
    "da_challenge_window": 16,
    "da_resolve_window": 16
  }
}
```

约束：
- `da_commitment_type = "GenericCommitment"` 时，**不能** 出现 `da_challenge_contract_address`（源码校验：`Must set empty da_challenge_contract_address for generic commitments`）
- `da_challenge_window` 和 `da_resolve_window` **必须 > 0**，否则 `GetOPAltDAConfig` 报错
- `alt_da` 是新版字段名；旧版叫 `plasma_config`，两者互不兼容

---

## 6. 新旧版本字段兼容性对照

| 新版 op-node（bin/op-node, 2026-02 构建） | 旧版 op-node（workspace 子模块源码） |
|---|---|
| JSON: `alt_da` | JSON: `plasma_config` |
| Struct: `AltDAConfig` | Struct: `PlasmaConfig` |
| Func: `GetOPAltDAConfig` / `AltDAEnabled` | Func: `GetOPPlasmaConfig` / `PlasmaEnabled` |
| CLI flag: `--altda.*` | CLI flag: `--plasma.*` |

> 本文档以 **bin 目录下实际运行的二进制** 为准。如果以后重新编译 op-node，字段名可能再变化，可用以下命令验证：
> ```bash
> strings bin/op-node | grep -E 'json:"(alt_da|plasma_config|da_commitment_type)'
> ```

---

## 7. 日志体量问题（原脚本的坑）

原脚本 `scripts/chain-start.sh` 和 `scripts/run-op-batcher.sh` 给 `op-batcher` 写死了 `--log.level=debug`。实测数据：

| 日志级别 | 大约速率 | 1 小时磁盘占用 |
|---|---|---|
| `debug` | 数千行/秒 | **~15 GB** |
| `info` | 数行~数十行/秒 | < 50 MB |

改造后默认 `info`，需要排错时显式开 debug：

```bash
export OP_BATCHER_LOG_LEVEL=debug
bash scripts/chain-start.sh local
```

---

## 8. 完整使用流程

### 8.1 前置：起 Celestia DA Server

本仓库 **不负责** 启动 DA Server。需要事先用 `celestia/op-alt-da` 跑一个，默认监听 3100：

```bash
# 参考：https://github.com/celestiaorg/op-alt-da
# 要求 DA Server 连到一个 Celestia light node 或 bridge node
# 启动后验证：
curl -sf http://localhost:3100/   # 或 /health，取决于实现
```

### 8.2 配置 `.envrc`

```bash
cp .envrc.example .envrc
# 编辑 .envrc：
export USE_ALT_DA=true
export ALT_DA_SERVER=http://localhost:3100
# 其他 ALT_DA_* 变量保持默认即可（GenericCommitment + 16/16 窗口）

# 原来如果是 blobs，必须改成 calldata（脚本会强制兜底，但建议显式改）
export OP_BATCHER_DATA_AVAILABILITY_TYPE=calldata
```

### 8.3 首次启动（本地 anvil）

```bash
direnv allow   # 或 source .envrc
bash scripts/chain-up.sh local
```

`chain-up.sh` 会依次：
1. 构建 op-geth / op-node / op-batcher / op-proposer（若 `bin/` 已有则跳过）
2. 启动 anvil（L1）
3. 部署 L1 合约，生成 `config/local/genesis.json` & `rollup.json`
4. 启动 op-geth → op-node → op-batcher → op-proposer
5. `chain-start.sh` 自动把 `alt_da` 注入 rollup.json

### 8.4 仅重启（不重新部署）

```bash
bash scripts/chain-stop.sh
bash scripts/chain-start.sh local
```

### 8.5 切换 DA 模式（calldata/blobs ↔ alt-DA）后

因为 L2 genesis 对 DA 层有隐式依赖（已发出去的 batch 没法切换后端），**强烈建议重新部署**：

```bash
bash scripts/chain-stop.sh
rm -f data/.last_chain_env
rm -rf data/op-geth data/op-node/safedb
rm -f config/local/{rollup,genesis,artifact}.json
FORCE_SETUP=1 bash scripts/chain-up.sh local
```

### 8.6 验证启动成功

```bash
# 1. 端口
lsof -nP -iTCP:8545,8645,9545,9645,8560,3100 -sTCP:LISTEN

# 2. alt-DA 配置是否生效（op-node 会打 banner）
grep -iE 'alt_da|altda|Alt-DA' data/logs/op-node.log | head -5

# 3. rollup.json 字段正确
jq '.alt_da, .plasma_config' config/local/rollup.json
# 期望：alt_da 是对象，plasma_config 是 null

# 4. batcher 真的把数据发到 DA Server
#    等一个 MAX_CHANNEL_DURATION 周期（默认 300s，可调小）
grep -iE 'commitment|altda|SetInput|da_server' data/logs/op-batcher.log | tail -20
```

---

## 9. 踩坑与修复（调试回顾）

| # | 错误信息 | 根因 | 修复 |
|---|---|---|---|
| 1 | `Error: L1 SystemConfig contract ... has no code` | anvil 重启后 L1 合约丢失 | `FORCE_SETUP=1 bash scripts/chain-up.sh local` 重新部署 |
| 2 | `failed to init L2: failed to get altDA config: no altDA config` | rollup.json 缺 `alt_da` 字段 | `chain-start.sh` 启动时自动注入 |
| 3 | `failed to decode rollup config: json: unknown field "plasma_config"` | 新版 op-node 字段改名，不认旧字段 | 脚本先 `jq del(.plasma_config)`，再写入新 `alt_da` |
| 4 | `cannot use data availability type blobs or auto with Alt-DA` | `.envrc` 里 DA type 是 `blobs`，alt-DA 只接受 `calldata` | `.envrc` 改成 `calldata` + 脚本兜底强制覆盖 |
| 5 | `op-batcher.log` 3 分钟 769MB | `--log.level=debug` 写死 | 默认改为 `info`，需要时用 `OP_BATCHER_LOG_LEVEL=debug` 临时开启 |

---

## 10. 回滚到原仓库行为

如果要完全关掉 alt-DA，回到 L1 calldata/blobs：

```bash
# .envrc 改 3 处：
export USE_ALT_DA=false                             # 主开关
export OP_BATCHER_DATA_AVAILABILITY_TYPE=blobs      # 或 calldata
# 其他 ALT_DA_* 变量可保留不管，脚本只在 USE_ALT_DA=true 时读取

# rollup.json 里的 alt_da 字段不会影响启用 calldata/blobs 模式，
# 但如果介意可以手动删掉：
jq 'del(.alt_da)' config/local/rollup.json | sponge config/local/rollup.json
```

脚本逻辑全部都是 `if [ "${USE_ALT_DA:-false}" = "true" ]; then ... fi` 包着，主开关关掉后行为与原仓库一致。

---

## 11. 参考资料

- `bin/op-node` / `bin/op-batcher`：本仓库实际运行的二进制（`strings` 可查字段名）
- 错误信息源码：
  - `optimism/op-node/rollup/types.go`（workspace 子模块是旧版，但校验逻辑思路一致）
  - `optimism/op-batcher/batcher/config.go`（`cannot use data availability type blobs or auto with Alt-DA`）
- Celestia DA Server: https://github.com/celestiaorg/op-alt-da
- OP Stack Alt-DA（官方）: https://docs.optimism.io/stack/transactions/alt-da
