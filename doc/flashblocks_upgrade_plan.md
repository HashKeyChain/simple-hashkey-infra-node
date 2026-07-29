# Flashblocks 升级方案（任务计划 · opus）

把现有 **op-node(cgt-jovian) + op-geth** 的单序列器 CGT/Jovian 链接入 **Flashblocks** 架构的**方案级任务计划**。
描述"做什么、为什么、验证到什么程度才算通过"，不涉及具体仓库改动。
执行顺序：**私网逐阶段验证 → 生产灰度上线**，每阶段设明确验证门。

---

## 一、目标与前提结论

**目标**：为链提供亚秒级（~200/250ms）预确认体验，同时不牺牲安全与活性；正式块仍维持 2 秒节奏。

**前提结论**（决定本方案可行性）：
- 链的自定义（CGT、Holocene/Isthmus/Jovian）集中在**共识层(op-node) + 链上合约字节码**；
- **执行层(op-geth) 为官方原版、且不含 CGT 专用代码**；
- 因此：CGT/分叉逻辑对执行客户端**透明**，更换/新增执行层客户端理论上无需移植自研代码。

**据此的方案判断**：
- 接入 flashblocks **必须新增组件**（不是现有组件的开关）；
- 但**大概率无需修改自研代码**，主要工作是**组件集成 + 一致性验证**；
- "零改码"不作承诺——由验证阶段证实，若出现分歧再按配置级优先修复。

---

## 二、目标架构

```
op-node（共识层，不变）
      │ Engine API
      ▼
rollup-boost（新增：Engine API 代理 + 校验 + flashblocks 广播；三档 off/dry-run/on）
      ├───────────► op-rbuilder（新增：reth 系构建器，产 flashblocks）
      │                    │ flashblocks 流
      └───────────► 兜底执行层（前期 op-geth，后期 op-reth；作校验基准与回退）
                           ▼
              flashblocks 广播代理（新增：对外扇出 ws 流）
                           ▼
              flashblocks 感知 RPC（新增：向用户提供 `pending` 预确认）
```

**角色划分**：
- **不变**：op-node、op-batcher、op-proposer、op-challenger。
- **迁移**：主执行层由 op-geth 迁往 op-reth（顺应官方 op-geth 生命周期）。
- **新增**：rollup-boost、op-rbuilder、flashblocks 广播代理、flashblocks 感知 RPC。
- **过渡保留**：op-geth 作为校验基准/回退，验证通过后按"执行层演进路径"退役。

**关键设计原则**：
- 共识层零改动——所有自定义对执行层透明，是低风险迁移的根基。
- builder 产出的块必须由可信执行层交叉校验后才被采用（活性与安全兜底）。
- 单序列器起步，不引入高可用(op-conductor)，降低复杂度。

---

## 三、组件与版本（已锁定 · 锚定 Jovian 世代）

**选型总原则**：本链是 **Jovian 世代**（op-node `cgt-jovian/v1.16.5`、op-geth `v1.101605.0`、合约 beta3），
**未上 Karst**。所有 flashblocks 组件**锁在 Jovian 世代、从 flashbots 独立仓库取**，
**不用** OP monorepo（`ethereum-optimism/optimism/rust/`）里那套 —— 那套是 2026-05 之后 vendored 的
**Karst 世代**（op-reth v2.3.x / Engine API V5 / 要求 op-node ≥ v1.19.1），与本链 op-node v1.16.5 不兼容。

**交付策略**：新增 Rust 组件**全部 fork 到 `HSKChain` 后从源码自编**（供应链自主可控/可审计）。
下表"上游源 → fork"给出来源与自有仓库；实际 clone/编译走 `HSKChain/*` 并锁 tag。
共 3 个源仓库：`flashbots/rollup-boost`、`flashbots/op-rbuilder`、`paradigmxyz/reth`
（websocket-proxy 在 rollup-boost 仓库内，不单独 fork）。

| 组件 | 上游源 → fork | 版本（tag） | 说明 |
|---|---|---|---|
| op-node（共识层） | 现有 `cgt-jovian` 分支 | v1.16.5（不变） | 自研 CGT/Jovian，保持不动 |
| op-geth（兜底 + 校验基准） | 现有 stock OP Labs | v1.101605.0（不变） | 作 canonical fallback 与 VALID 校验，Jovian 期继续保留 |
| rollup-boost（sidecar） | `flashbots/rollup-boost` → **`HSKChain/rollup-boost`** | **v0.7.11** | Jovian 配套；内含 reth 1.9.3，修正 Jovian payload id 计算 |
| op-rbuilder（构建器） | `flashbots/op-rbuilder` → **`HSKChain/op-rbuilder`** | **v0.2.13** | Jovian ready（v0.2.11 不兼容 Jovian） |
| flashblocks 广播代理 | 同 **`HSKChain/rollup-boost`**（`crates/websocket-proxy`） | 随 **v0.7.11** 同 tag 一起编 | 与 rollup-boost 同仓同版；**不用**已归档的 `base/flashblocks-websocket-proxy`，也**不用** main 分支（main 已是 Karst 代） |
| flashblocks 感知 RPC（op-reth） | `paradigmxyz/reth` → **`HSKChain/reth`** | **v1.9.3** | op-reth 是 reth 的 bin target（`--bin op-reth`）；flashblocks 为原生特性（`--flashblocks-url`），**无需 base fork**。⚠️ 不从 optimism monorepo 取（那里是 Karst 代 v2.3.x，无 v1.9.3） |

> **版权**：rollup-boost = MIT，op-rbuilder / reth = MIT OR Apache-2.0，均允许 fork/改/编镜像/对外提供；
> fork 后保留 LICENSE 与版权声明（Apache 另保留 NOTICE 并标注修改），对外提供用自有品牌名、勿暗示官方背书。

**决策记录（本次已定，避免反复）**：
- **走"v1.16.5 + flashbots 仓库"路线**，**不**把自研代码 rebase 到最新版再接 flashblocks。
  理由：rebase 到最新=Karst 世代,会把 CGT 补丁跨代移植、geth→reth 全切、合约 beta3→v7、
  op-program→kona-client 四件大事和 flashblocks 捆在一起,风险乘法级；而 flashblocks 是 sidecar 增量,
  可在不动自研 fork 的前提下先落地。架构跨世代一致，将来升 Karst 只需**重新 pin 版本**，不用重构。
- websocket-proxy **来源已定为 rollup-boost 同仓库同 tag**（`v0.7.11` 的 `crates/websocket-proxy`）。
  可选升级：将来需要 API key 鉴权/trusted-proxy-cidrs 等生产特性时，改用 `base/base` monorepo 的
  `crates/infra/websocket-proxy`（协议一致，可平替）。
- **追赶 Karst**（op-reth v2.3.3 / rollup-boost v0.7.16 / op-rbuilder v0.4.9，从 OP monorepo 统一取）
  为**后续独立事项**，本方案不纳入。
- **交付形态已定**：三个 fork（`HSKChain/rollup-boost`、`HSKChain/op-rbuilder`、`HSKChain/reth`）
  以 **git submodule** 加入基础设施仓库，锁 tag、从源码自编（本地/生产同一套构建）。
- **模式切换已定**：`FLASHBLOCKS_MODE` 作启动初值（off/dry_run/enabled）；运行中 dry-run↔enabled
  用 rollup-boost `debug set-execution-mode` 热切、不断链；硬回退用改初值 + 重启。本地验证细节见
  `doc/flashblocks_local_impl.md`。

> op-reth 版本注：官方 Jovian 表中普通节点用 v1.9.2，**跑 flashblocks 的链用 v1.9.3**。

---

## 四、阶段计划

每阶段有明确**验证门**，全绿才进入下一阶段。P0–P5 在私网完成，P6 到生产执行。

### P0 · 准备
- **做什么**：获取并构建全部新增组件；确认执行层客户端能加载本链创世与分叉配置；准备好各组件间的连接与鉴权关系。
- **验证门**：新增执行层客户端能正确解析创世，且计算出的创世区块哈希与现有 op-geth 一致。

### P1 · 执行层一致性验证（影子）
- **目标**：证明"更换执行层"安全。
- **做什么**：以新执行层(op-reth)作为只读验证者，与现有 op-geth 同步同一条链，从创世完整重放并越过全部分叉激活块；逐块比对区块哈希 / 状态根 / 收据根，重点核对 4 个分叉激活块与含真实交易的普通块（含 CGT 费用）。
- **验证门**：关键块与抽样块**零分歧**。

### P2 · 构建器一致性验证（dry-run）
- **目标**：在不影响真实出块的前提下，验证 builder 产块与基准执行层一致。
- **做什么**：部署 rollup-boost 与 op-rbuilder，置于 **dry-run（影子）模式**——引擎调用同时下发给 builder 与基准执行层，但**只采用基准执行层的块**，builder 的块仅用于比对与记录分歧；持续运行覆盖足量区块与真实交易时段。
- **验证门**：dry-run 期间**分歧计数为 0**。

### P3 · 启用 flashblocks
- **目标**：真正产出并广播 flashblocks。
- **做什么**：将 rollup-boost 切至 **on 模式**（采用 builder 块 + 交叉校验 + 自动回退）；验证 flashblocks 按亚秒节奏稳定产出；演练"builder 掉线自动回退兜底执行层、链继续正常出块"，并验证 builder 恢复后自动恢复 flashblocks。
- **验证门**：flashblocks 稳定产出；掉线可回退、链不中断。

### P4 · 面向用户
- **目标**：把预确认能力交付到用户。
- **做什么**：部署 flashblocks 广播代理对外扇出流；部署 flashblocks 感知 RPC 消费该流；验证用户经标准 `pending` 语义在亚秒内看到预确认（无需新 RPC 方法），2s 正式块封定后状态最终一致。
- **验证门**：用户侧可见亚秒级 `pending` 预确认。

### P5 · 端到端验收
- **做什么**：验证功能（转账/合约/CGT 计费）、**Fault Proof 不受影响**（最终上链块仍为可信执行层认可的规范块，proposer/challenger 行为不变）、性能（预确认延迟与正式块无退化）、韧性（builder 崩溃/延迟/重启的回退与恢复）、重启续跑；产出私网验收报告。
- **验证门**：验收清单全过，具备上生产条件。

### P6 · 生产灰度上线
- **做什么**：备份现网状态与版本、准备一键回滚；在生产链上依次重复"执行层影子验证 → 构建器 dry-run（观测足够时长）→ 低峰灰度切 on → 接入对外代理与 RPC"；建立监控与告警；对外公告端点与 `pending` 用法。
- **验证门**：各档观测稳定、无持续分歧与异常回退。
- **回退触发**：分歧率非零且上升 / 频繁回退 / 预确认延迟劣化 / Fault Proof 侧异常——任一触发即回退到 off。

---

## 五、执行层演进路径（op-geth → op-reth）

兜底/校验执行层不是永久停留在 op-geth，而是**按验证门分阶段晋升**至 op-reth。这是**必选项**：
官方 op-geth 生命周期于 2026-05-31 结束，之后不支持新硬分叉，因此终局必然是 reth 全栈。

```
阶段 A（验证期）          阶段 B（晋升 reth）         阶段 C（退役 geth）
─────────────────        ─────────────────────       ─────────────────
基准/兜底: op-geth   ──▶   基准/兜底: op-reth      ──▶   基准/兜底: op-reth
影子验证:  op-reth         备用网:   op-geth(冷备)       (geth 移除)
构建器:    op-rbuilder     构建器:   op-rbuilder         构建器:  op-rbuilder
```

- **为什么前期用 geth 当基准**：geth 是当前链唯一"已知正确"的客户端（一直在出块），
  用它当基准去验证新来的 reth 栈（op-reth 影子 + op-rbuilder 构建器）最可靠。
- **A→B 晋升条件**：op-reth 在影子阶段与 op-geth 逐块零分歧（即 P1 验证门）。达标后
  把 rollup-boost 的兜底/校验基准由 geth 切换为 reth。
- **B 阶段保留 geth 冷备**：作为回滚安全网，出问题可切回 geth。
- **B→C 退役 geth**：on 模式在生产稳定运行足够时长、信心充分，且必须赶在 geth EOL /
  下一个 geth 不支持的分叉之前，彻底移除在线 geth。

> 澄清：退役 geth 作为**在线节点** ≠ 从**故障证明**中移除 geth 系执行。当前 Fault Proof 使用
> op-program（geth 系 FPVM）。即使在线节点全部转 reth，故障证明里的 geth 系执行仍在，直到另做
> **op-program → kona-client（reth 系）** 迁移——那是独立的后续轨道，不在本方案内。

---

## 六、验证方法论（架构级）

**为什么能对照**：给定同一父块 + 同一批同序交易 + 同一分叉规则，任何规范客户端产出的块必须逐字节一致，最终浓缩为区块哈希。哈希一致即全一致；不一致即"分歧(diverge)"。

**两类影子验证**：
- **执行层影子（P1）**：验证"换客户端"安全——两个执行层消费同一条链，块必须完全一致。
- **构建器 dry-run（P2）**：验证"builder 产块"正确——builder 在旁陪跑，其块与基准执行层比对但不上链。

**分歧定位（漏斗式）**：区块哈希不一致 → 拆解到状态根 / 收据根 / gasUsed / 交易根 → 定位到具体交易 → 单笔重放对跑 → 找到分歧的执行细节。多数根因是创世/链配置未对齐（配置级修复）；仅当确系自研分叉的非规范选择才需改码，而执行层为官方版、链已在官方客户端跑通，此概率很低。

**交叉校验的本质（on 模式安全性）**：采用 builder 块前，由可信执行层对该块重新执行验证；通过才采用，否则回退兜底。因此即便 builder 是全新实现，也不危害链安全——最终采用哪个块由可信执行层的复算结果决定。

---

## 七、回滚策略

| 影响面 | 回滚动作 |
|---|---|
| flashblocks 异常 | rollup-boost 切 off → 回到纯执行层出块，用户无感 |
| 构建器异常 | 停 builder → 自动回退兜底执行层 |
| 主执行层异常 | 共识层 Engine 端点切回 op-geth（过渡期一直保留） |
| 彻底回退 | 停全部新增组件，恢复升级前形态 |

核心安全网：**rollup-boost 的 off 模式 = 升级前的纯 op-geth 出块**，任何阶段可秒级回退。

---

## 八、风险登记

| 风险 | 等级 | 应对 |
|---|---|---|
| 必须新增 4~5 个组件（非开关） | 确定 | 纳入计划，按阶段集成 |
| 分叉激活块在 reth 上产生分歧 | 中 | P1 重点核对 4 个分叉块；多为配置级修复 |
| 自研分叉的费用/参数与规范实现不一致 | 低 | 执行层为官方版、链已跑通即规范兼容；dry-run 兜底 |
| builder 与基准执行层选择策略差异 | 中 | dry-run 量化分歧；on 模式交叉校验 + 回退 |
| Fault Proof 兼容 | 低 | 最终上链块为规范块，P5 专项验收 |
| geth EOL 前未完成 reth 化 | 中 | 按"执行层演进路径"排期，赶在 EOL/下个分叉前 |
| 生产切换风险 | 中 | 影子/dry-run 前置 + 低峰灰度 + 一键回滚 |

---

## 附：阶段与验证门速览

| 阶段 | 目标 | 验证门 |
|---|---|---|
| P0 准备 | 组件就绪 | 创世哈希与 op-geth 一致 |
| P1 执行层影子 | 换客户端安全 | 关键/抽样块零分歧 |
| P2 构建器 dry-run | builder 正确 | 分歧计数为 0 |
| P3 启用 flashblocks | 真正产出 | 稳定产出 + 可回退 |
| P4 面向用户 | 交付预确认 | 亚秒 `pending` 可见 |
| P5 端到端验收 | 全面达标 | 验收清单全过 |
| P6 生产灰度 | 生产上线 | 观测稳定、可回滚 |
