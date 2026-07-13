# L2OutputOracle → Fault Proofs 升级（Safe 多签流程）

把现有 Sepolia 链从 L2OO 模式升级到 Fault Proofs（PermissionedDisputeGame）。
通过 SystemOwnerSafe（3/6 多签）一次性执行 3 笔交易完成。

## 0. 前置事实（已链上核对）

| 项 | 值 |
|---|---|
| SystemOwnerSafe（= DGF.owner = ProxyAdmin.owner） | `0xe9a1a112965B4e00577d6028c5116B388581a81e` |
| Safe threshold / owners | **3 / 6** |
| ProxyAdmin | `0x659c166D3f4DD2e4F6E218B0eD0C6321Dc68619f` |
| DisputeGameFactoryProxy | `0x799E013e33d05E48c8b774bFD83aaA82E92049b2` |
| OptimismPortalProxy | `0x8dc71d4d25c415C0a9F11EF57Bd64ca208531645`（proxyType=ERC1967, _initialized=1）|
| AnchorStateRegistryProxy | `0x04281Ef5FE221834dc3b6d0b0C87Ef360909C0C3`（proxyType=ERC1967, _initialized=1）|
| SystemConfigProxy | `0x62163c0C9479b4b202eFa52bF8bd9cBBEdd9042F` |
| SuperchainConfigProxy | `0x8C40a3847301926eC17de95602216758eEe25a71` |

新部署并已 verify 的 impl（本次）：

| impl | 地址 | 备注 |
|---|---|---|
| OptimismPortal2Reinit | `0xa1Cf656889Eb0A9Ee9C8500b6Ea1F6D385B29F01` | proofMaturity=302400, finalityDelay=302400 |
| AnchorStateRegistryReinit | `0xda8E4105Dd3e094FA5514410F1CfB96fe9426a1D` | DGF=0x799E013e... |
| PermissionedDisputeGame | `0xA6d7B116527dD65b607327ABAE2977aA8Cd3E277` | v1.3.1-beta.2, gameType=1, mcd=302400, ce=10800 |

> `_initialized == 1` 是关键前提：两个 Reinit 合约用 `reinitializer(2)`，只有当前版本为 1 时才能执行。已核对通过。

## 1. 三笔交易（都由 Safe 发起，operation = CALL）

| # | to | 方法 | 作用 |
|---|-----|------|------|
| Tx1 | DGF proxy `0x799E013e...` | `setImplementation(uint32 1, address 0xA6d7B116...)` | 注册新 PermissionedDG 为 gameType=1 的实现 |
| Tx2 | ProxyAdmin `0x659c166D...` | `upgradeAndCall(PortalProxy, 0xa1Cf6568..., portal.reinitialize(...))` | Portal 指向新 impl 并 reinit |
| Tx3 | ProxyAdmin `0x659c166D...` | `upgradeAndCall(ASRProxy, 0xda8E4105..., asr.reinitialize(...))` | ASR 指向新 impl 并 reinit |

内层 reinitialize 入参：
- Portal.reinitialize(dgf=DGFProxy, systemConfig=SystemConfigProxy, superchainConfig=SuperchainConfigProxy, respectedGameType=1)
- ASR.reinitialize(roots=[{gameType:1, root:genesis, l2Block:0},{gameType:0, root:genesis, l2Block:0}], superchainConfig=SuperchainConfigProxy)

## 2. 生成 batch

```bash
python3 scripts/upgrade-l2oo-to-fp/gen-safe-batch.py
# 生成 scripts/upgrade-l2oo-to-fp/safe-batch.json
```

需要覆盖参数时用环境变量，例如换 anchor：

```bash
FAULT_GAME_GENESIS_OUTPUT_ROOT=0x<root> FAULT_GAME_GENESIS_BLOCK=<block> \
python3 scripts/upgrade-l2oo-to-fp/gen-safe-batch.py
```

## 3. 多签执行（Safe Web UI）

1. 打开 https://app.safe.global ，切到 Sepolia，进入 Safe `0xe9a1a112...`。
2. 左侧 **Apps → Transaction Builder**。
3. 把 `safe-batch.json` 拖进去（或 New batch → import），加载这 3 笔。
4. **Create Batch → 逐笔核对 to/data**，与本 README / 脚本打印的 calldata 一致。
5. 一个 owner 发起（Propose），其余 owner 依次 **Confirm**，凑满 **3/6**。
6. 满足阈值后任意 owner 点 **Execute**，3 笔在一个 multiSend 里原子执行。

> Safe 会自动用 MultiSend 把 3 笔打成一个 `execTransaction`，要么全成功要么全回滚，无需担心中间态。

## 4. 执行前的模拟校验（强烈建议）

执行前跑一次链上模拟，确认不会 revert：

```bash
python3 scripts/upgrade-l2oo-to-fp/simulate.py
```

它会用 `eth_call` 以 Safe 身份分别模拟 3 笔（state override 绕过多签），命中 revert 会打印原因。

## 5. 升级后验证

```bash
python3 scripts/upgrade-l2oo-to-fp/verify-after.py
```

检查项：
- DGF.gameImpls(1) == 新 PDG
- Portal impl == 新 Portal，且 respectedGameType()==1、disputeGameFactory()==DGFProxy
- ASR impl == 新 ASR，anchors(1)/anchors(0) == genesis anchor、superchainConfig()==SuperchainConfigProxy
- Portal/ASR slot0 (_initialized) == 2

## 6. 后续：切换 op-stack 组件

合约升级完成后，链下组件要切到 FP 模式：
- op-proposer：`--game-factory-address=<DGFProxy> --game-type=1`（去掉 L2OO 相关）
- 启动 op-challenger（resolve/challenge），challenger 私钥 = 新 PDG 的 CHALLENGER `0xE4571072...`
- op-proposer 私钥 = 新 PDG 的 PROPOSER `0xe09C877f...`

> 注意：新 PDG maxClockDuration=302400（3.5 天），提款挑战期相应变长。
