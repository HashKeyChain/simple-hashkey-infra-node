# 临时升级 SuperchainConfig 改 Guardian

通过 transient upgrade 模式修改 ETH mainnet 上 `SuperchainConfigProxy.guardian()` 字段的值。

## 原理

mainnet 上 `SuperchainConfig` 是 `op-contracts/v2.0.0-beta.3` 时代的 `version "1.1.1-beta.1"`，
源码里 `_setGuardian` 是 internal，没有外部 setter。

这里用一个**带 setter 的临时 impl** 替换、改 storage、再升回原 impl：

```
┌────────────────┐     1) upgrade(SCProxy, NEW_IMPL)
│ PAO Safe (3/5) │ ─────────────────────────────────► 切换 impl 到带 setter 的版本
└────┬───────────┘
     │           2) SCProxy.setGuardian(NEW_GUARDIAN)
     │            ──────────────────► transparent proxy fallback delegate 到 impl，
     │                                 setGuardian 检查 msg.sender == ProxyAdmin.owner()
     │                                 → 写入 GUARDIAN_SLOT
     │           3) upgrade(SCProxy, ORIGINAL_IMPL)
     └─────────────────────────────► 升回原 impl，对外 ABI/行为完全恢复
```

storage 兼容性：原版 SuperchainConfig 把 `guardian` 和 `paused` 都写在 hardcoded keccak slot
（`GUARDIAN_SLOT`, `PAUSED_SLOT`），不依赖顺序 storage，所以新 impl 继承原 impl 后两者
storage 完全一致（已用 `forge inspect storageLayout` 比对确认）。

## 涉及到的合约 / 地址（mainnet 实测值）

| 角色 | 地址 |
|---|---|
| `SuperchainConfigProxy` | `0xfd1255b6c09D939E7F3896A16C32CDBCD6F8B40A` |
| 原 impl `version "1.1.1-beta.1"` | `0x1d31a15050dbe75c6c060d6da696332a5cb943e1` |
| `SuperchainConfig` 的 ProxyAdmin | `0x7986ed289935a0f47fc434c00cde309fe2c51f1c` |
| ProxyAdmin owner = PAO Safe (3/5) | `0x441F31C4cdf772558D4EA31f3114de59aE145E7c` |
| 当前 guardian (Safe 1.4.1, 3/5) | `0xC7fCbE26c1Db751d63869F72F782a56710f6be5A` |

## 文件

```
scripts/upgrade-guardian/
├── README.md            ← 本文
├── deploy-impl.sh       ← 在 ETH mainnet 上部署 SuperchainConfigWithSetGuardian impl
├── safe-batch.sh        ← 生成 PAO Safe 的 3 笔 batch JSON
├── verify.sh            ← 任意阶段查 SC 当前状态
└── deployed.json        ← 部署后自动写入

optimism-v2.0.0-beta.3/packages/contracts-bedrock/src/redeploy/
└── SuperchainConfigWithSetGuardian.sol   ← 临时 impl 源码（继承 v1.1.1-beta.1）
```

## 操作流程

### Step 1 — 编译临时 impl（已经做过的话跳过）

```bash
cd optimism-v2.0.0-beta.3/packages/contracts-bedrock
forge build --use 0.8.15 src/redeploy/SuperchainConfigWithSetGuardian.sol
```

### Step 2 — 部署到 ETH mainnet

```bash
export DEPLOYER_PK=0x...    # ETH mainnet 需要 ~0.01 ETH 付 gas
bash scripts/upgrade-guardian/deploy-impl.sh
```

部署后 `deployed.json` 里会有 `addresses.newImpl`。

### Step 3 — 跑一次升级前 verify

```bash
bash scripts/upgrade-guardian/verify.sh
# 期望: implementation = ORIGINAL_IMPL, stage = original
```

### Step 4 — 生成 Safe batch JSON

```bash
bash scripts/upgrade-guardian/safe-batch.sh 0x<NEW_GUARDIAN_ADDRESS>
# 输出 safe-batch.json
```

终端会同时打印 3 笔的 `to/value/data`，方便你手贴 Safe Tx Builder。

### Step 5 — Safe 多签执行 batch

1. 打开 https://app.safe.global → 连接 ETH mainnet → 进入 PAO Safe
   （`0x441F31C4cdf772558D4EA31f3114de59aE145E7c`）
2. **Apps → Tx Builder → 拖入 `safe-batch.json`** 即可加载 3 笔
3. 收 3-of-5 owner 签名 → Execute
4. 一次链上交易完成 3 笔 sub-tx，原子执行（要么全成功要么全失败）

### Step 6 — 升级后 verify

```bash
bash scripts/upgrade-guardian/verify.sh
# 期望:
#   implementation  = ORIGINAL_IMPL  （已回滚）
#   guardian()      = NEW_GUARDIAN   （已修改）
#   stage           = original
```

## 为什么这个方案安全

1. **storage layout 100% 兼容**（用 `forge inspect storageLayout` 验证过）
2. **setGuardian 权限严格**：仅 `ProxyAdmin.owner()`（PAO Safe）可调，即便 transient impl
   被忘了回滚，外部攻击面也是 0
3. **3 笔在 Safe batch 里原子执行**：不存在"升了 impl 但中途被插队改 guardian"的窗口
4. **可逆**：如果 batch 内某一笔失败，整个 batch revert，链上状态保持原样
5. **不动 superchain-registry / 任何其他合约**：影响面仅限 SuperchainConfigProxy 一个合约的
   一个 storage slot

## 已知风险

| # | 风险 | 缓解 |
|---|---|---|
| 1 | mainnet 操作不可逆 | 在 testnet 用同流程演练；deploy 前 verify.sh 看清现状 |
| 2 | NEW_GUARDIAN 写错 → 失去 pause 能力 | safe-batch.sh 的输出在 Safe Tx Builder 里再人工核对一遍 |
| 3 | 升级期间 Guardian 紧急 pause 时机 | batch 在一笔 L1 tx 内原子完成，~12 秒内执行完 3 笔，几乎无窗口 |
| 4 | 部署 impl 时构造函数行为 | constructor 调 `initialize(0, false)` 只影响 impl 自己 storage（_initialized=1），不影响 proxy |
