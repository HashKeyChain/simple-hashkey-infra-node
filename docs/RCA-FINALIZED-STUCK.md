# RCA: Testnet L2 finalized 永久卡在 0

**事件时间**: 2026-04-28 ~ 2026-04-29  
**影响范围**: HSK testnet alt-DA L2 (chain ID `10086`)  
**严重程度**: P1 — 链可用但 finality 永久失效，任何依赖 L2 finalized 的 bridge / withdraw 流程全部不可用

---

## TL;DR

> 当前 L2 (chain `10086`) 部署初期 batcher 一次提交了 7000+ block 的大 SpanBatch，被 op-node 以 "sequence window expired" 全部拒收，导致 L2 block 1 - 7000 没有有效 batch tx 锚点。OP Stack 的 finalize 机制要求**从 block 0 连续推进**，而早期 block 的 finalize 锚点**数学上永远不可能补出来**——`inclusion_block - first_epoch > sequence_window` 在那段历史上恒成立。**唯一治本方案是重新部署生产链**，并在新链上配置：`sequencerWindowSize=14400` + 激进的 batcher 小批次提交参数。本地 anvil 已完整复现 + 验证修复方案有效。

---

## 1. 现象

```text
$ curl optimism_syncStatus → http://op-node:9545
{
  "unsafe_l2":    1234567,    ← sequencer 持续出块（正常）
  "safe_l2":     1227362,    ← batcher → DA → derivation 链路工作（正常）
  "finalized_l2":      0,    ← ❌ 永远卡在 0，从未推进
  "finalized_l1": 27128745    ← op-node 看到 L1 finality 信号（正常）
}
```

伴随 op-node log 持续报：

```text
batch was included too late, sequence window expired
   origin=...:27092215   epoch=...:27088615   block_count=7220
Dropping invalid span batch, flushing channel (span batch prefix checks)
```

batcher log 持续 catchup 模式：

```text
sequencer did not make expected progress
syncActions: blocksToLoad: [9734, 16935]   ← batcher 反复 reload 7000+ block
Loading range of multiple blocks into state  start=9734  end=16935
```

---

## 2. 业务影响

| 操作 | 是否可用 |
|---|---|
| L2 上发交易 / call / 查询 | ✅ 正常 |
| L1 → L2 deposit | ✅ 正常 |
| L2 → L1 withdraw 发起 | ✅ 可发起 |
| **L2 → L1 withdraw 完成** | ❌ **永远无法 finalize**（需要 `finalized_l2 ≥ withdraw 所在 L2 block`）|
| 第三方 bridge 接入 | ⚠️ 取决于对方对 finality 的要求 |

---

## 3. 根因（Root Cause）

### 3.1 OP Stack derivation 的硬约束

每个 batcher 提交的 batch tx 包含一段 metadata：

```text
batch:
  start_epoch_number: M     ← batch 描述的最早 L1 origin block
  end_epoch_number:   N     ← batch 描述的最晚 L1 origin block
  L2 blocks: [...]
```

op-node 收到 batch tx 时校验：

```text
inclusion_block_l1 - start_epoch_number > sequencerWindowSize
                                               (默认 3600)
→ REJECT (sequence window expired)
```

### 3.2 当前 testnet 配置

| 字段 | 值 | 含义 |
|---|---|---|
| `sequencerWindowSize` | 3600 | OP Stack 默认（设计给 L1 block_time=12s 的 mainnet）|
| L1 block_time (HSK testnet) | 2s | **只有 mainnet 1/6 的窗口时间** |
| → 实际窗口 | **7200 秒 = 2 小时** | batcher 必须 2 小时内提交对应 epoch 的 batch |
| L2 block_time | 1s | **比标准 OP Stack 快一倍** |

### 3.3 触发链

1. 链刚部署完，sequencer 立即开始以 1 块/秒高速出块
2. **batcher 默认 `MAX_CHANNEL_DURATION=300s` + `BATCH_TYPE=SpanBatch`** → 一次攒大批次
3. catchup 模式下 batcher 单次 SpanBatch 包含 **7220 个 L2 block**（跨 ~3610 个 L1 epoch，差 10 块就到边界）
4. batch tx 上链时间 ≈ batch first_epoch + 3616 块，**已经超过 sequence window (3600)**
5. op-node REJECT，batch 被永久 drop
6. batcher 收到 sync signal 重新 load 7000+ block 重组 channel → 同样描述同样的早期 epoch → **再次 expired** → 死循环

### 3.4 为什么"补 batch"不可能

batch 的 `start_epoch_number` 绑定到 L2 block 出块时引用的 L1 origin（写在 L2 block header 里）。重新提交 batch 时，`start_epoch_number` 不能改（改了 = L2 block hash 变 = 整条链 reorg）。但 `inclusion_block` 只会随时间推进。因此：

```text
inclusion_block - start_epoch_number 永远 > 3600 → 永远 reject
```

**早期 block 的 finalize 锚点数学上不可能被生成**。OP Stack 的 finalize 又必须从 block 0 连续推进，所以 `finalized_l2` 永远卡在 0。

### 3.5 为什么 `finalized_l2 = 0` 但 `safe_l2` 还在涨

`safe_l2` 不依赖连续性 —— op-node 只要看到 batch 在 sequence window 内被接受就把对应 L2 block 标 safe。后期 batcher 改成小批次后，新 block 的 safe 推进恢复正常。但 **finalize anchor 不能跳跃**，被早期 block 1 卡死整条 finalize chain。

---

## 4. 验证（本地复现 + 修复有效）

### 4.1 复现环境

- 本地 macOS + anvil (`--chain-id 133 --block-time 2 --slots-in-an-epoch 1`)
- celestia/op-alt-da DA Server @ localhost:3100
- op-deployer 部署 `op-contracts/v6.0.0-rc.1` 全套 + alt-DA GenericCommitment
- 同 binary 版本：op-node v1.16.5, op-batcher v1.16.3, op-geth v1.101605.0

### 4.2 验证结果

| 指标 | 生产链 (testnet) | 本地新链 (anvil) |
|---|---|---|
| `unsafe_l2` 出块 | ✅ | ✅ |
| `safe_l2` 推进 | ⚠️ 滞后 unsafe 7200 块 | ✅ 滞后 17 块 |
| **`finalized_l2` 推进** | ❌ **永远 0** | ✅ **正常推进**（25 min 涨到 1026）|
| 各服务 error/crit 数 | sequence window expired 频发 | **0** |

本地链验证全套配置 + 代码 + 工具链都正确，问题 **100% 是生产链的历史损坏**，跟代码 / op-deployer / alt-DA / DA Server 都无关。

---

## 5. 修复方案

### 5.1 唯一治本方案：重新部署生产链

无任何 in-place 修复方案可用：
- 不能改 rollup.json（是 chain identity 的一部分，改了等于换链）
- 不能改 op-node 源码跳过 finalize anchor 检查（破坏 OP Stack 安全模型）
- 不能让 batcher "补提交"早期 block（数学上 sequence window 永远 expired）
- 不能"重置 safedb"或类似操作（不影响 derivation 历史）

### 5.2 重新部署时的配置改动

#### 5.2.1 部署侧（op-deployer intent.toml）

`scripts/deploy-with-deployer.sh init` 已默认带这段：

```toml
[globalDeployOverrides]
  sequencerWindowSize = 14400     # 8 小时容错（默认 3600 仅 2 小时太紧）
```

可通过环境变量覆盖：

```bash
SEQ_WINDOW_SIZE=21600 bash scripts/deploy-with-deployer.sh init    # 12 小时
```

#### 5.2.2 op-batcher 侧（K8s deployment env）

```yaml
OP_BATCHER_MAX_CHANNEL_DURATION: 30s    # 默认 5min → 30s。让 batcher 频繁提交小 batch
OP_BATCHER_BATCH_TYPE: 0                 # 0 = SingularBatch（默认 1 = SpanBatch 容易触发 expired）
OP_BATCHER_TARGET_NUM_FRAMES: 1          # alt-DA 每 channel 1 frame
OP_BATCHER_MAX_PENDING_TX: 4             # 多 in-flight 提速 catchup
OP_BATCHER_SUB_SAFETY_MARGIN: 6          # HSK testnet 经常 6 块 reorg，留 6 块边界
```

#### 5.2.3 op-node 侧（K8s deployment env）

```yaml
OP_NODE_L1_BEACON_IGNORE: true                                 # 不需要 beacon node（alt-DA 走 calldata）
OP_NODE_ROLLUP_L1_CHAIN_CONFIG: /config/l1-chain-config.json   # HSK testnet 不在内置 superchain registry
OP_NODE_ALTDA_ENABLED: true
OP_NODE_ALTDA_DA_SERVER: http://da-server.celestia-da:3100
OP_NODE_ALTDA_DA_SERVICE: true
OP_NODE_ALTDA_VERIFY_ON_READ: true
OP_NODE_ALTDA_MAX_CONCURRENT_DA_REQUESTS: 1
```

---

## 6. 重新部署流程

```bash
# === 0. 让运维 K8s 停掉所有 L2 服务 ===
kubectl scale deployment hsk-sequencer-{node,geth,batcher,proposer} --replicas=0

# === 1. 本地用 op-deployer 重新部署 ===
cd simple-hashkey-infra-node
source .envrc

# 本地走 testnet RPC 部署（如果运维网络通），或者运维侧执行同样命令
rm -rf deployer-workdir
bash scripts/deploy-with-deployer.sh init      # 自动 sequencerWindowSize=14400
bash scripts/deploy-with-deployer.sh noop      # dry-run 验证 intent
bash scripts/deploy-with-deployer.sh live      # 真部署到 L1（5-10 min）
bash scripts/deploy-with-deployer.sh export    # 输出 genesis/rollup/l1-addresses

# === 2. 验证关键参数 ===
jq '{l1_chain_id, l2_chain_id, seq_window_size}' config/getting-started/rollup.json
# 期望：seq_window_size = 14400

# === 3. 把 4 个 config 文件交给运维 ===
#     config/getting-started/genesis.json
#     config/getting-started/rollup.json
#     config/getting-started/l1-addresses.json
#     config/getting-started/l1-chain-config.json
#  让运维更新 K8s ConfigMap

# === 4. 运维按 5.2 的 env 配置启动 L2 服务 ===
kubectl scale deployment hsk-sequencer-{node,geth,batcher,proposer} --replicas=1

# === 5. 验证（运维或开发侧）===
curl optimism_syncStatus → http://op-node:9545
# 等 5-10 分钟，期望：finalized_l2 > 0 并持续推进
```

---

## 7. 预防（避免再次踩同样坑）

### 7.1 监控 alarm

```yaml
# 添加 alarm 规则（建议）
- alert: L2FinalizedNotProgressing
  expr: increase(op_node_finalized_l2[10m]) == 0
  for: 30m
  severity: P1

- alert: L2SafeLagTooLarge
  expr: (op_node_unsafe_l2 - op_node_safe_l2) > 3600
  for: 10m
  severity: P2

- alert: BatchSequenceWindowExpired
  expr: rate(op_node_log_warn{msg="sequence window expired"}[5m]) > 0
  for: 1m
  severity: P1
```

### 7.2 部署 checklist

新链上线 30 分钟内必须 verify：

- [ ] `finalized_l2 > 0` 且每 ~30s 推进
- [ ] `safe_l2 - unsafe_l2 < 100` 块（不积累 lag）
- [ ] op-node log 0 个 `sequence window expired`
- [ ] op-batcher log 0 个 `Dropping invalid span batch`
- [ ] L1 上 batcher 地址 nonce 持续增长

### 7.3 永久优化项

| 项 | 当前 | 推荐 |
|---|---|---|
| `sequencerWindowSize` | 3600 (默认) | **14400** |
| op-batcher 默认 `MAX_CHANNEL_DURATION` | 300s | **30s** |
| op-batcher 默认 `BATCH_TYPE` | 1 (SpanBatch) | **0 (SingularBatch)** |
| HSK L1 finality 监控 | 无 | 加 alarm |

---

## 8. 时间线

| 时间 | 事件 |
|---|---|
| 2026-04-28 上午 | 完成 v6.0.0 + alt-DA 部署，链上线 |
| 2026-04-28 下午 | 发现 batcher log 大量 `sequence window expired` |
| 2026-04-28 晚上 | 发现 `safe_l2` 滞后 `unsafe_l2` 7200+ block 且不缩小 |
| 2026-04-29 上午 | 排查 `finalized_l2 = 0` 不动；初步怀疑 L1 RPC / alt-DA 问题 |
| 2026-04-29 下午 | 通过 `optimism_syncStatus` 确认 `finalized_l1 > 0` 但 `finalized_l2 = 0` —— 排除 L1 RPC 问题 |
| 2026-04-29 下午 | 本地 anvil 复现验证 v6 + alt-DA + finality 链路完全正常 → 确诊为生产链历史损坏 |
| **TODO** | 重新部署生产链，按 §5.2 配置 |

---

## 9. 参考

- OP Stack derivation 规范：[Sequence Window](https://specs.optimism.io/protocol/derivation.html#sequencing-window)
- 本仓库 alt-DA 接入文档：`docs/ALT-DA-CELESTIA.md`
- op-deployer 部署脚本：`scripts/deploy-with-deployer.sh`
- 启动脚本：`scripts/chain-start.sh`

---

## 10. Appendix: 本地复现的关键证据

### 10.1 sequence window 算式

```python
# 生产链触发 expired 的实际数据
inclusion_block_l1  = 27092215     # batch tx 实际上 L1 的 block
batch_first_epoch   = 27088599     # batch 描述的最早 L1 origin
sequencer_window    = 3600         # 当前配置

assert inclusion_block_l1 - batch_first_epoch == 3616
assert 3616 > 3600                 # ✗ expired
```

### 10.2 本地新链 25 分钟稳定性数据

```text
T+0:     unsafe=238   safe=84    finalized=48
T+25min: unsafe=1055  safe=1038  finalized=1026

推进速度：
  unsafe:    +817 / 25min ≈ 0.54 块/s
  safe:      +954 / 25min（追上）
  finalized: +978 / 25min ✓✓
```

### 10.3 当前 op-batcher / op-node 的关键 metrics 对比

| metric | 生产链 (异常) | 本地链 (正常) |
|---|---|---|
| `op_node_log lvl=error` | 大量 | 0 |
| `op_node_log "sequence window expired"` | 持续刷 | 0 |
| `op_batcher_log "Dropping invalid span batch"` | 持续刷 | 0 |
| `unsafe_l2 - safe_l2` | 7200+ 永久 | 17 |
| `safe_l2 - finalized_l2` | safe 在涨, finalized = 0 | 12 |
