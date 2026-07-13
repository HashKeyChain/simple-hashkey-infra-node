# 从 L2OutputOracle 升级到 PermissionedDisputeGame（Fault Proofs）

本文档记录把一条已部署的 OP Stack 链从 **L2OutputOracle（L2OO）** 模式切换到
**PermissionedDisputeGame（Fault Proofs，gameType=1）** 模式的全过程，并把 `OptimismPortal2`
与 `AnchorStateRegistry` 两个合约实现升级到 **op-contracts/v2.0.0-beta.3**。

文档只讲“用了哪些合约、做了哪些操作、为什么这么做”，不依赖任何具体脚本。

---

## 1. 背景与目标

- 初始链用 **beta.2** 部署，提款最终性走 **L2OutputOracle**（一个受信任 oracle 合约）。
- 目标改为 **Fault Proofs 的 permissioned 变体**：output 提案变成在 `DisputeGameFactory`
  里创建 `PermissionedDisputeGame`（gameType = 1，PERMISSIONED_CANNON），提款时把 withdrawal
  绑定到某个已 resolve 的 game 上再 finalize。
- 顺带把 `OptimismPortal` / `AnchorStateRegistry` 两个合约的**实现**升级到 beta.3。

一个关键事实：beta.2 首次部署时，**Fault-Proofs 这一整套合约已经一并部署好了**
（`DisputeGameFactory`、`AnchorStateRegistry`、`DelayedWETH`、`MIPS`、`PreimageOracle`、
`OptimismPortal2` 实现、以及 gameType=0/1 的 game 实现都已注册），只是没有启用。
因此本次工作的本质是 **“切换 + 升级实现”，不是从零部署**。

---

## 2. 涉及的合约

### 2.1 代理（地址在升级前后保持不变）

| 合约 | 作用 |
|------|------|
| `OptimismPortalProxy` | L1↔L2 资金/消息出入口；提款的 prove / finalize 都打到这里 |
| `AnchorStateRegistryProxy` | 记录每种 gameType 当前“已确认的锚点 output root”，新 game 从锚点起步 |
| `DisputeGameFactoryProxy` | 创建并登记所有 dispute game；owner 是 SystemOwnerSafe |
| `SystemConfigProxy` | 系统参数（gas、resourceConfig、gasPayingToken 等） |
| `SuperchainConfigProxy` | guardian / pause 等全局开关 |
| `DelayedWETHProxy` | dispute game 的保证金（bond）托管 |
| `L2OutputOracleProxy` | 旧的 L2OO；升级后不再用于提款最终性 |

### 2.2 实现（impl）

| 合约 | 版本 | 说明 |
|------|------|------|
| `OptimismPortal2`（升级后新 impl） | beta.3 `3.11.0-beta.4` | 替换旧 `OptimismPortal`（`2.8.1-beta.1`） |
| `AnchorStateRegistry`（升级后新 impl） | beta.3 `2.0.1-beta.2` | 替换旧 ASR（`1.0.0`），新增 `superchainConfig` 字段与 `setAnchorState` |
| `PermissionedDisputeGame` | beta.2（无变化，沿用） | gameType=1 的 game 模板，已在 DGF 注册 |
| `MIPS` / `PreimageOracle` | beta.2（沿用） | Cannon 容错证明的 VM 与 preimage 预言机 |

### 2.3 权限相关

| 合约/账户 | 作用 |
|-----------|------|
| `ProxyAdmin` | 所有 ERC1967 代理的 admin；只有它能改 impl |
| `SystemOwnerSafe` | Gnosis Safe，是 `ProxyAdmin` 与 `DisputeGameFactory` 的 owner（threshold=1） |

> 升级所有“改 impl / 改 DGF”操作都必须由 `SystemOwnerSafe` 发起（再由它调用 `ProxyAdmin`）。

---

## 3. 升级前的链上状态（升级判断依据）

- `OptimismPortalProxy.version()` = `2.8.1-beta.1`（旧 L2OO 版 Portal），`_initialized = 1`
- `AnchorStateRegistryProxy.version()` = `1.0.0`（beta.2 极简版），`_initialized = 1`
- `DisputeGameFactory.gameImpls(1)` 已注册 PermissionedDisputeGame，其 `absolutePrestate`、
  `anchorStateRegistry`、`proposer`、`challenger` 均已配置好，initBond = 0
- `ProxyAdmin.owner()` 与 `DisputeGameFactory.owner()` 都是 `SystemOwnerSafe`

**核心难点：两个代理的 `_initialized` 都已是 1。** beta.3 的 `OptimismPortal2.initialize`
与 `AnchorStateRegistry.initialize` 都带 OZ `initializer` 修饰符（只能执行一次），直接在已初始化的
代理上调用会 revert。因此升级时**不能用 `initialize`，必须用一个 `reinitializer(2)` 的入口**
重新写入新版本所需的存储。

---

## 4. 升级安全性核对（升级前必须做）

### 4.1 存储布局兼容（最关键）

把代理切到新实现的前提是：新旧实现的 **storage layout 在已用 slot 上完全一致**，否则会读到错位的数据。
逐 slot 对比结论：

- **OptimismPortal（旧 L2OO）→ OptimismPortal2（beta.3）**：完全兼容。OP 官方在旧 Portal 里预留了
  spacer（`spacer_52`、`spacer_54`、`spacer_56` 等），新 Portal2 的 `disputeGameFactory` /
  `provenWithdrawals` / `respectedGameType` 等字段正好落在这些原本为空的 slot 上，旧字段位置不变。
- **AnchorStateRegistry（1.0.0）→（2.0.1-beta.2）**：兼容。beta.3 只是在 `anchors` mapping
  之后**追加**了 `superchainConfig`（新 slot），没有移动已有字段；`DISPUTE_GAME_FACTORY` 是
  `immutable`（不占 slot）。

### 4.2 跨版本外部调用兼容

beta.3 的 `OptimismPortal2` 运行时会调用链上其它（仍是 beta.2 的）代理的方法，需确认都存在：

- `SystemConfig.gasPayingToken()`、`SystemConfig.resourceConfig()` ——存在
- `SuperchainConfig.guardian()`、`SuperchainConfig.paused()` ——存在

> 因此“只升级 Portal2/ASR 两个 impl、其它仍是 beta.2”在运行时是自洽的。

---

## 5. 升级操作步骤

### 5.1 准备：能在已初始化代理上重新初始化的入口

beta.3 官方合约的 `initialize` 不能重复执行。做法是基于 beta.3 的两个合约各派生一个**薄子类**，
新增 `reinitialize(...)`：

- `OptimismPortal2`（beta.3）→ 子类新增 `reinitialize(IDisputeGameFactory, ISystemConfig,
  ISuperchainConfig, GameType)`，修饰符为 `reinitializer(2)`，函数体与官方 `initialize` 等价
  （写入 disputeGameFactory / systemConfig / superchainConfig，按需设置 l2Sender，设置
  respectedGameType 与 respectedGameTypeUpdatedAt，调用 `__ResourceMetering_init()`）。
- `AnchorStateRegistry`（beta.3）→ 子类新增 `reinitialize(StartingAnchorRoot[],
  ISuperchainConfig)`，修饰符为 `reinitializer(2)`，函数体与官方 `initialize` 等价
  （写入各 gameType 的锚点 root，写入 superchainConfig）。

> 这两个子类只是“加了一个可重入的初始化入口”，不改变 beta.3 合约本身的任何逻辑或存储布局。

### 5.2 部署两个新实现

用 beta.3 代码编译并部署：

1. `OptimismPortal2`（子类）impl —— 构造参数：
   - `proofMaturityDelaySeconds`（本次本地测试用 12 秒）
   - `disputeGameFinalityDelaySeconds`（本次用 12 秒）
2. `AnchorStateRegistry`（子类）impl —— 构造参数：
   - `DisputeGameFactory` 地址（ASR 把它存为 immutable）

### 5.3 切换 OptimismPortalProxy 的实现并重初始化

由 `SystemOwnerSafe` 调用：

```
ProxyAdmin.upgradeAndCall(
    OptimismPortalProxy,
    新 OptimismPortal2 impl,
    reinitialize(DisputeGameFactoryProxy, SystemConfigProxy, SuperchainConfigProxy, GameType=1)
)
```

效果：Portal 代理指向 beta.3 Portal2；`respectedGameType` 设为 1；`disputeGameFactory` /
`systemConfig` / `superchainConfig` 写好；`_initialized` 变为 2。

### 5.4 切换 AnchorStateRegistryProxy 的实现并重初始化

锚点 output root 取自 op-node 的 `optimism_outputAtBlock`（本次用创世区块 0 的 output root）。
由 `SystemOwnerSafe` 调用：

```
ProxyAdmin.upgradeAndCall(
    AnchorStateRegistryProxy,
    新 AnchorStateRegistry impl,
    reinitialize([
        {gameType:1 (PERMISSIONED_CANNON), outputRoot:{root: genesisRoot, l2BlockNumber:0}},
        {gameType:0 (CANNON),              outputRoot:{root: genesisRoot, l2BlockNumber:0}}
    ], SuperchainConfigProxy)
)
```

效果：ASR 代理指向 beta.3 ASR；写入锚点；写入 superchainConfig；`_initialized` 变为 2。

### 5.5 DisputeGameFactory

**无需操作**。gameType=1 的 PermissionedDisputeGame 实现及其参数（prestate、ASR、proposer、
challenger、initBond）在 beta.2 部署时已注册。

### 5.6 切换并重启 op-proposer

- 配置切到 Fault Proofs：`USE_FAULT_PROOFS=true`、`GAME_TYPE=1`。
- 停掉旧的 L2OO proposer，用 Fault-Proofs 参数重启：
  - `--game-factory-address = DisputeGameFactoryProxy`
  - `--game-type = 1`
  - `--proposal-interval`（本次 30s）
  - 本地持续出块时建议 `--wait-node-sync=false`，否则会卡在等 L1 view 追上 tip。

重启后 proposer 会周期性向 `DisputeGameFactory` 创建新的 `PermissionedDisputeGame`。

---

## 6. 升级后验证

- `OptimismPortalProxy.version()` = `3.11.0-beta.4`，`respectedGameType()` = 1，`_initialized` = 2
- `AnchorStateRegistryProxy.version()` = `2.0.1-beta.2`，`superchainConfig()` 已设置，`_initialized` = 2
- `DisputeGameFactory.gameCount()` 持续增长，新 game 的 `gameType` = 1

---

## 7. 端到端提款验证（deposit → withdraw → prove → resolve → finalize）

为了确认升级后“提款”真正可用，跑了一条完整链路：

1. **存款（L1→L2）**：调 `OptimismPortalProxy.depositTransaction(...)`，等 op-node 把 deposit
   派生到 L2，目标账户在 L2 拿到余额。
2. **L2 发起提款**：调预部署的 `L2ToL1MessagePasser`（`0x4200…0016`）的
   `initiateWithdrawal(target, gasLimit, data)`，附带要提的金额。从交易回执的 `MessagePassed`
   事件中得到 withdrawal 结构（nonce/sender/target/value/gasLimit/data）和 `withdrawalHash`。
3. **等待覆盖区块的 game**：必须等 proposer 创建出一个 `l2BlockNumber ≥ 提款所在 L2 区块` 的 game。
4. **L1 证明提款**：调 `OptimismPortalProxy.proveWithdrawalTransaction(...)`，需要：
   - withdrawal 结构
   - `_disputeGameIndex`：上一步那个 game 在 DGF 里的下标
   - `_outputRootProof`：`{version, stateRoot, messagePasserStorageRoot, latestBlockhash}`，
     取自该 game 对应 L2 区块的 `optimism_outputAtBlock`
     （`messagePasserStorageRoot` 对应返回里的 `withdrawalStorageRoot`）
   - `_withdrawalProof`：MessagePasser 中 `sentMessages[withdrawalHash]` 的存储证明
     （slot = `keccak256(withdrawalHash ++ uint256(0))`，对该 L2 区块做 `eth_getProof`）
5. **resolve 绑定的 game**：game 创建后超过 `maxClockDuration`（本次 600s）无人挑战即可 resolve。
   依次调 game 的 `resolveClaim(0, 0)` 与 `resolve()`，状态变为 `DEFENDER_WINS`。
6. **finalize**：等过 `proofMaturityDelaySeconds`（本次 12s）后，调
   `OptimismPortalProxy.finalizeWithdrawalTransaction(withdrawal)`，资金到账 L1 target。

实测结果：prove、resolve、finalize 三笔交易均成功，提款金额按预期到账 L1（扣除 finalize 的 gas）。

---

## 8. 关于 op-challenger（说明）

- PermissionedDisputeGame + 单一受信任 proposer 的场景下，**正常提款流程不需要 op-challenger**。
- challenger 的作用是在“有人提交错误 game”时应战；它通常也会顺带 resolve 到期的 game。
- 本次升级**没有启动 op-challenger**，game 的 resolve 是手动触发的。若希望 game 到期后自动 resolve，
  可另行启动 op-challenger（permissioned 模式）。

---

## 9. 参考：本次实际用到的地址

| 名称 | 地址 |
|------|------|
| OptimismPortalProxy | `0x1d0Ca7FA656E09167635a2F54C6EA7c7Ea24B422` |
| AnchorStateRegistryProxy | `0x93ff3E899722C17258908bF6069CD4f3A00E8799` |
| DisputeGameFactoryProxy | `0xd7d49e08CcE0e156fCB68CaD434935b800162b6c` |
| SystemConfigProxy | `0xf504CC88F9c17e9C4e45C460C1FbDb2e1fBD7C68` |
| SuperchainConfigProxy | `0xa6D69564B69C5D8F020f1f7F85133003cE5a6c5D` |
| DelayedWETHProxy | `0xf0013aBad395802AD3E40F243BC76A169bb5894B` |
| ProxyAdmin | `0xCBb52D39F32cD8d2dA48fe369a0D7c9a2B8C4d1C` |
| SystemOwnerSafe | `0x6d839ff61F587453CFdae3549845FBD36C634EB5` |
| MIPS | `0xa9a64d74AF28b1333aD8c1B277163602480CD823` |
| PreimageOracle | `0xf52a5c4eBdA8A5F5521E55498778E67F967ba4dF` |
| L2OutputOracleProxy（已弃用） | `0x69BF1ffB3d95a772Ae9C768F915ceB71385Bd57c` |
| L2ToL1MessagePasser（L2 预部署） | `0x4200000000000000000000000000000000000016` |
| 新 OptimismPortal2 impl | `0x220254ca2afdde617f39c376c15b420ad84759be` |
| 新 AnchorStateRegistry impl | `0x337bb23b6dd49e9bf83cfb804f7c5fa9e3e14782` |

> 注：以上为本次本地 anvil（L1 chainId=133，L2 chainId=98765）部署的实际地址，换链需替换。
> 本地测试的延迟参数（proofMaturity=12s、finality=12s、maxClockDuration=600s）均为加速验证用，
> 生产环境应使用安全的长延迟。
