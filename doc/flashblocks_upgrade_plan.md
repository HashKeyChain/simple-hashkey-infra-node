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
- **模式切换已定**：`FLASHBLOCKS_MODE` 作启动初值（off/dry_run/enabled），决定起哪些组件；
  运行中用 rollup-boost `debug set-execution-mode` 热切、不断链。注意两套名字不是一回事——
  运行时的 ExecutionMode 只有 `enabled` / `dry_run` / `disabled` 三档，**没有 off**；
  `off` 仅指启动时不拉起 flashblocks 组件。上线后的止血档位是 `disabled`（见 7.2）。
  本地验证细节见 `doc/flashblocks_local_impl.md`。
- **对外鉴权形态已定**：对齐 Base，广播代理**不配 api-keys**、走公开 `/ws` 路由，靠连接数限流兜底。
  两种模式互斥，配了 api-keys 公开路由即消失，详见第七节。

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

生产上线把**执行模式**与**对外暴露**拆成两个独立开关，分三步推进。前两步对外零变化，第三步才交付预确认。
先备份现网状态与版本、准备一键回滚，并建立监控与告警。

**P6.1 · off → dry_run（对外无变化）**
- **做什么**：起 rollup-boost、op-rbuilder、广播代理、感知 RPC 及其 verifier op-node。代理与感知 RPC 只在内网可达——公网路由尚未建立（无 LB listener、无 DNS 记录），安全组仅放行自有感知 RPC 主机。
- **为什么不能跳过**：dry_run 是 builder 区块进入 canonical **之前**唯一的产出路径验证。基准执行层会独立重放 builder 的候选块并重算 stateRoot/receiptsRoot/gasUsed，不一致即 INVALID，在 rollup-boost 日志留下 `InvalidPayload`。"builder 高度追平基准执行层"只证明它能**跟随**执行，不证明它自己**产出**的块正确——这是两条不同的代码路径。
- **验证门**：`InvalidPayload` 为 0；builder 投递率稳定；出块节奏无退化；经内网感知 RPC 跑通 P4 的预确认验证。
- **观测周期按条件界定而非固定时长**：覆盖日内流量高峰，跨过至少一个完整的 batcher 提交与 proposer 输出周期。

**P6.2 · dry_run → enabled（对外仍无变化）**
- **做什么**：`debug set-execution-mode` 热切，不断链、不重启任何组件。
- **注意**：这是整个升级里风险最大的一步，且它在开放端口**之前**就已生效——全网交易自此由 op-rbuilder 排序打包。用户此时只是看不到预确认，底层出块权已经换人，不要误判为"对外等于没升级"。
- **为什么值得单独设一档**：拿真实生产流量验证 builder 的产出路径，强于 dry_run。dry_run 只证明基准执行层认可该块，这一档证明它真的上链、且 batcher / proposer / 同步节点全部正常。
- **回退成本极低**：对外未暴露任何东西，切回 dry_run 即可，builder 仍在跟随同步、无需追块。
- **验证门**：safe head 正常推进；proposer 输出正常；同步节点无分叉；预确认延迟符合预期（内网观测）。

**P6.3 · 开放对外端点**
- **做什么**：建 LB listener 与 DNS 记录，把广播代理与感知 RPC 纳入公网路由。**代理无需重启、配置不变**。
- **对外公告分两份受众**，见第七节。
- **验证门**：外部订阅可用；连接数与限流指标正常；预确认延迟符合公告承诺。

**回退触发**（任一即触发）：`InvalidPayload` 非零且上升 / 频繁回退兜底 / 预确认延迟劣化 / safe head 停滞 / Fault Proof 侧异常。回退动作见第八节。

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

## 七、生产网络方案（对外暴露与代理生命周期）

### 7.1 两个对外端点，两类受众

对齐 Base 的划分——两个端点服务的不是同一批人：

| 端点 | 受众 | Base 对应 |
|---|---|---|
| flashblocks 广播代理 | 节点运营方（合作方自建感知节点） | `wss://mainnet.flashblocks.base.org/ws` |
| flashblocks 感知 RPC | 应用开发者（标准 `pending` 语义） | `mainnet.base.org` |

Base 明确标注原始广播流"for node operators only"、应用不应直连，应用侧一律走感知 RPC 的 `pending`。
公告时必须分两份说明，否则 DApp 会直连广播流。

**鉴权形态对齐 Base：不配 api-keys、公开 `/ws` 路由，靠连接数限流兜底。**
注意本代理的两种模式互斥——一旦配置 api-keys，公开 `/ws` 路由即消失、改为 `/ws/{api_key}`，
无法在同一实例上同时服务两类受众。

### 7.2 代理生命周期：一次启动，永不封禁

订阅端（感知 RPC 的 flashblocks 客户端）**重连无退避**：连接被拒即立刻重试，中间没有任何 sleep。
因此长时间关闭端口会让每个订阅者满核空转并刷爆日志；而"端口开着但没数据"完全无害——
连接原地保持，只是变哑。两者的差别决定了下列全部运维规则。

1. **sequencer 栈升级不碰代理。** rollup-boost 停掉后代理按指数退避安静重试（上限 20s），
   外部连接不断，恢复后自动续推。此时重启代理反而凭空制造一次断连；且 sequencer 暂停期间链本就不出块，
   静默是正确行为而非降级。
2. **紧急止血切 `disabled`。** 一条 debug API、零重启：rollup-boost 不再向 builder 下发 FCU，
   builder 不产 flashblock，广播自然静默，订阅连接保持。代价是 builder 收不到 newPayload 会掉队，
   恢复前需重新同步。
3. **计划内暂停预览且需快速回切，才用 `dry_run` + 代理空上游重启。** dry_run 下 newPayload 仍转发给
   builder（保持同步、恢复快），但它照常广播未被采用的预览，必须同时把代理上游指向空地址并重启才能
   对外静默——这会带来一次断连。用一次断连换 builder 不掉队。
4. **代理自身升级走多实例滚动重启。** 外部最多经历一次正常重连。

> **`dry_run` 不是止血手段。** 它只停止*采用* builder 区块，广播照发，用户会拿到不保证兑现的预确认。
> 上线后需要止血一律用 `disabled`。

### 7.3 负载均衡与代理配置要点

- **健康检查用 `/healthz`，且不要关联上游状态。** 该端点恒返回 200、不反映上游连通性，这是期望行为：
  若健康检查跟随上游，rollup-boost 一停所有代理实例会被同时摘出 LB，制造出正要避免的断连风暴。
  流是否在推靠 Prometheus 指标（`upstream_connections`、发送计数）告警，两者职责分开。
- **必须开启客户端 ping**（默认关闭）。静默期代理不发任何字节，LB 的空闲超时（常见默认 60s）会掐断连接
  ——恰好在维护窗口把断连造出来。开启后按固定间隔心跳，可扛任意长静默。LB 空闲超时须大于心跳间隔。
- **LB 必须正确设置 `X-Forwarded-For`。** 代理按该头识别客户端 IP 做 per-IP 限流；若未设置，
  所有连接在代理看来同源于 LB，per-IP 上限会迅速开始拒绝正常订阅者。
- **连接数上限按合作方规模上调**：per-IP 与单实例上限的默认值面向小规模场景。
- **多实例需配 Redis 做跨实例限流**，否则各实例内存独立计数，扩容与滚动重启期间行为不一致。
- **开启 Brotli 压缩**：Unichain 的公开流即为 Brotli 压缩，reth 客户端原生支持解压，公网扇出省带宽。

```
公网 → LB（TLS 终止，wss）
        健康检查 /healthz（不关联上游）
        空闲超时 > 客户端心跳间隔
        正确透传 X-Forwarded-For
     → 广播代理 × N（N ≥ 2，供滚动重启）
        公开 /ws 路由、客户端 ping、Brotli
        连接数限流 + Redis 跨实例计数
     → rollup-boost 广播端口（内网，有指数退避）
```

### 7.4 本地演练与生产的差异

本地无 LB，用代理的监听地址模拟路由门禁：P6.1/P6.2 绑 `127.0.0.1`（自有感知 RPC 走 loopback 正常订阅，
外部不可达），P6.3 换 `0.0.0.0`。**本地这一步需要重启代理，生产对应的是新增一条路由、不涉及重启**
——切勿把本地做法照搬上线。

---

## 八、回滚策略

| 影响面 | 回滚动作 |
|---|---|
| flashblocks 异常，需立即止血 | rollup-boost 切 `disabled` → 回到纯兜底执行层出块，广播静默、订阅连接不断；代价是 builder 掉队需重新同步 |
| 需暂停预览但保留 builder 同步 | 切 `dry_run` + 代理改空上游重启 → 恢复快，代价是一次对外断连 |
| 构建器异常 | 停 builder → 自动回退兜底执行层 |
| 主执行层异常 | 共识层 Engine 端点切回 op-geth（过渡期一直保留） |
| 彻底回退 | 停全部新增组件，恢复升级前形态 |

核心安全网：**rollup-boost 的 `disabled` 模式 = 升级前的纯执行层出块**，任何阶段可秒级回退，
且不影响外部订阅连接。

两条禁忌：
- **不要靠封禁代理端口来降级**——订阅端重连无退避，会让所有外部节点持续空转报错。
- **不要用 `dry_run` 当止血手段**——它照常广播未被采用的预览。

> 关于"自动回退"的边界：兜底只在 builder **取不到 payload** 时触发（请求失败即回退基准执行层）。
> rollup-boost 默认不因健康检查跳过 builder（`ignore_unhealthy_builders` 默认关闭），
> 因此"进程还活着但产出异常"的 builder **不会**被自动绕过，必须由人工切 `disabled`。
> 监控告警要覆盖这种"活着但不对"的形态，不能只监控进程存活。

---

## 九、风险登记

| 风险 | 等级 | 应对 |
|---|---|---|
| 必须新增 4~5 个组件（非开关） | 确定 | 纳入计划，按阶段集成 |
| 分叉激活块在 reth 上产生分歧 | 中 | P1 重点核对 4 个分叉块；多为配置级修复 |
| 自研分叉的费用/参数与规范实现不一致 | 低 | 执行层为官方版、链已跑通即规范兼容；dry-run 兜底 |
| builder 与基准执行层选择策略差异 | 中 | dry-run 量化分歧；on 模式交叉校验 + 回退 |
| Fault Proof 兼容 | 低 | 最终上链块为规范块，P5 专项验收 |
| geth EOL 前未完成 reth 化 | 中 | 按"执行层演进路径"排期，赶在 EOL/下个分叉前 |
| 生产切换风险 | 中 | 影子/dry-run 前置 + 低峰灰度 + 一键回滚 |
| dry_run 期间广播未被采用的预览 | 中 | P6.1/P6.2 公网路由未建立，外部无从订阅；上线后禁止用 dry_run 止血（见 7.2） |
| 订阅端重连无退避，封端口即引发外部空转 | 中 | 端口永不封禁，降级一律用 `disabled`；代理生命周期独立于链栈（见 7.2） |
| 静默期被 LB 空闲超时掐断连接 | 中 | 开启客户端 ping，LB 空闲超时大于心跳间隔（见 7.3） |
| per-IP 限流误伤（XFF 未透传） | 中 | LB 正确设置 `X-Forwarded-For`，上线前用外部客户端实测（见 7.3） |

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
| P6.1 生产 dry_run | builder 产出路径验证 | `InvalidPayload` 为 0，对外无变化 |
| P6.2 生产 enabled | 真实流量验证出块权移交 | safe head / proposer 正常，对外仍无变化 |
| P6.3 开放端点 | 交付预确认 | 外部订阅可用，限流指标正常 |
