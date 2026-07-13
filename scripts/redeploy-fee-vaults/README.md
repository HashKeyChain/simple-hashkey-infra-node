# Re-deploy FeeVault impls on HSK mainnet

通过部署一份新的 FeeVault impl（构造参数里写新 recipient），再走 L1 Safe → OptimismPortal → L2 ProxyAdmin.upgrade()
把 3 个 vault 切到新 impl，从而**修改 fee recipient**。

> 当前 mainnet FeeVault impl（`op-contracts/v2.0.0-beta.3`，`version="1.5.0-beta.2"`）的 `recipient`、
> `MIN_WITHDRAWAL_AMOUNT`、`WITHDRAWAL_NETWORK` 全是 **immutable**，且没有 setter，
> **只能通过升级 implementation 合约来更换**。

## 前提

1. 已经在仓库内开了 worktree：
  ```bash
   cd optimism
   git worktree add ../optimism-v2.0.0-beta.3 op-contracts/v2.0.0-beta.3
   cd ../optimism-v2.0.0-beta.3
   git submodule update --init --recursive lib
   cd packages/contracts-bedrock
   forge build --use 0.8.15 \
     src/L2/BaseFeeVault.sol \
     src/L2/L1FeeVault.sol \
     src/L2/SequencerFeeVault.sol
  ```
2. 编译产出的 deployedBytecode（immutable 涂 0 后）已与 mainnet 现 impl
  `0x6d4bec23eeec8d5adefcc628533ce507391cd403` 等 3 个地址做过 sha256 比对，全部 match。
   （构造参数差异被 immutable 槽位吸收，模板完全一致）

## 参数（部署阶段）


| 参数                   | 默认值                                          | 说明                                                               |
| -------------------- | -------------------------------------------- | ---------------------------------------------------------------- |
| `NEW_RECIPIENT`      | `0xe9d87622269c6490d776be2f6ab5dcc9ecf76fde` | 新的 fee 收款地址（**在 L2 上**）                                          |
| `MIN_WITHDRAWAL_WEI` | `10000000000000000000` (10 HSK)              | `withdraw()` 触发的最小余额阈值                                           |
| `WITHDRAWAL_NETWORK` | `1`                                          | `0=L1`、`1=L2`。本次默认 1，表示 fee 在 L2 上直接 `SafeCall.send` 给 recipient |


> ⚠️ `WITHDRAWAL_NETWORK = 1` 含义：每次调 `withdraw()`，FeeVault 会直接在 L2 上用
> `SafeCall.send` 把整笔余额发给 recipient。
>
> - recipient **必须能在 L2 上接收 HSK**（EOA 或带 `receive() payable` 的合约）。
> - 如果是合约，调用 gas 是 `WITHDRAWAL_MIN_GAS = 400_000`，fallback/receive 在该 gas 内不能 revert，
> 否则 `withdraw()` 会失败。
> - **不再走 L1 提现**，所以没有 prove + finalize 流程，钱直接落在 L2。

## 执行

```bash
# 1) 部署 3 个 impl 到 HSK mainnet L2
export L2_DEPLOY_PK=0x...    # 需要少量 HSK 付 gas（< 0.005 HSK）
bash scripts/redeploy-fee-vaults/deploy.sh

# 2) 部署后验证 immutable 全对、字节码模板与 mainnet 一致
bash scripts/redeploy-fee-vaults/verify.sh

# 3) 在 HSK Blockscout 上 verify 源码（让浏览器分别显示 BaseFeeVault/L1FeeVault/SequencerFeeVault）
bash scripts/redeploy-fee-vaults/verify-on-blockscout.sh

# 4) 生成 Safe Tx Builder batch JSON（不发交易，只生成可导入文件）
bash scripts/redeploy-fee-vaults/safe-batch.sh
```

`deploy.sh` 写 `deployed.json`，`verify.sh` / `verify-on-blockscout.sh` / `safe-batch.sh` 都读它。
`safe-batch.sh` 产出 `safe-batch.json`，可直接被 Safe Tx Builder 的 "Load file" 导入。

## Blockscout 源码验证

> BaseFeeVault 和 L1FeeVault 在 v2.0.0-beta.3 这版的 deployed bytecode **逐字节相同**
> （除了合约名，源码完全一致；foundry profile 又关掉了 bytecode metadata hash）。
> 但 Blockscout 是按 fully-qualified contract name 走 verify 的，所以即便 bytecode 相同，
> 也能让两个地址分别显示成 `BaseFeeVault` 和 `L1FeeVault`，互不干扰。

`verify-on-blockscout.sh` 可选 env：


| 变量               | 默认值                                         | 说明                                                                   |
| ---------------- | ------------------------------------------- | -------------------------------------------------------------------- |
| `BLOCKSCOUT_URL` | `https://hashkey.blockscout.com`            | 浏览器站点根 URL，verify API = `${BLOCKSCOUT_URL}/api/`                     |
| `OUT_FILE`       | `scripts/redeploy-fee-vaults/deployed.json` | 输入                                                                   |
| `WT`             | 项目内 worktree 路径                             | forge verify 在该目录跑，确保编译产物匹配                                          |
| `ONLY`           | 空                                           | 设 `BaseFeeVault` / `L1FeeVault` / `SequencerFeeVault` 可单独 verify 某一个 |


脚本会：

1. 从 `deployed.json` 读 constructor 参数 + 3 个 vault 地址
2. 用 `cast abi-encode` 拼出 constructor calldata
3. 依次跑 `forge verify-contract --verifier blockscout --verifier-url ${URL}/api/ <addr> src/L2/XxxVault.sol:XxxVault`
4. `--watch` 阻塞到 Blockscout 返回 verified / fail
5. 最后打印 3 个浏览器 contract 页面链接

如果某个 vault verify 失败（网络抖动 / Blockscout 队列堵），不会影响其他 vault 的 verify。可单独重试：

```bash
ONLY=L1FeeVault bash scripts/redeploy-fee-vaults/verify-on-blockscout.sh
```

## Safe 多签升级（用自动生成的 batch JSON）

`safe-batch.sh` 会按下面这条调用栈，为 3 个 vault 各生成一笔 L1 交易并打包成一个 batch：

```text
L1 Safe (PAO)
  └─ OptimismPortal.depositTransaction(L2_ProxyAdmin, 0, 300000, false, _data)
         └─ (deposit derived on L2, msg.sender = L1Safe.aliased)
                └─ L2 ProxyAdmin.upgrade(vaultProxy, newImpl)
                       └─ Proxy.upgradeTo(newImpl)
```

`safe-batch.sh` 可选 env：


| 变量                | 默认值                                          | 说明                                          |
| ----------------- | -------------------------------------------- | ------------------------------------------- |
| `L1_RPC_URL`      | `https://ethereum-rpc.publicnode.com`        | 仅做 chainId 防呆，不发交易                          |
| `L1_CHAIN_ID`     | `1`                                          | 写进 Safe Tx Builder JSON 的 chainId           |
| `OPTIMISM_PORTAL` | `0xe7Aa79B59CAc06F9706D896a047fEb9d3BDA8bD3` | L1 上 HSK mainnet 的 OptimismPortalProxy      |
| `L1_SAFE_OWNER`   | `0x441F31C4cdf772558D4EA31f3114de59aE145E7c` | L1 PAO Safe（= L2 ProxyAdmin owner 在 L1 的真身） |
| `L2_GAS_LIMIT`    | `300000`                                     | 每笔 deposit 在 L2 执行 upgrade 的 gas 限额         |
| `STRICT`          | `1`                                          | =1 时若 vault 已是目标 impl 直接报错；=0 仅 warn        |
| `SKIP_L1_CHECK`   | `0`                                          | =1 跳过 L1 chainId 防呆，便于离线生成 calldata         |


执行后流程：

1. 终端打印每个 vault 的 `inner upgrade()` 和 `outer depositTransaction` calldata
  （**等下在 Safe Web UI 里要核对一致**）
2. 在 `safe-batch.json` 落盘
3. 打开 [https://app.safe.global](https://app.safe.global) ，切到 ETH mainnet
4. 进入 Safe `0x441F31C4cdf772558D4EA31f3114de59aE145E7c`
5. **Apps → Tx Builder → 右上角 "Load file" → 选 `safe-batch.json`**
6. 校对 3 笔 tx：
  - `To` 全部 = OptimismPortal (`0xe7Aa79B59CAc06F9706D896a047fEb9d3BDA8bD3`)
  - `Value` = 0
  - `Data` 与终端打印的 outer calldata 完全一致
7. **Simulate** 一下，确认 `TransactionDeposited` event 里 `_to` 是 L2 ProxyAdmin、
  `_data` 是 upgrade(...) calldata
8. 收够 owner 签名 → **Execute**
9. 等 5–15 分钟，op-node 会派生 3 笔 deposit 到 L2 自动执行 upgrade
10. 在 L2 上验证：
  ```bash
    for V in 0x4200000000000000000000000000000000000019 \
             0x420000000000000000000000000000000000001A \
             0x4200000000000000000000000000000000000011; do
      IMPL=$(cast storage --rpc-url https://mainnet.hsk.xyz $V \
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
      echo "Vault $V -> impl 0x${IMPL: -40}"
      echo "  RECIPIENT:          $(cast call --rpc-url https://mainnet.hsk.xyz $V 'RECIPIENT()(address)')"
      echo "  WITHDRAWAL_NETWORK: $(cast call --rpc-url https://mainnet.hsk.xyz $V 'WITHDRAWAL_NETWORK()(uint8)')"
    done
  ```
    每个 vault 的 `impl` 应该等于 `deployed.json` 里对应的新地址，`RECIPIENT` 等于 `NEW_RECIPIENT`，
    `WITHDRAWAL_NETWORK` 等于 1。

## 关键风险


| #   | 风险                                                                       | 缓解                                                                         |
| --- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| 1   | 升级前老 vault 累积的 HSK 仍按旧 recipient 走 withdraw 路径，且 vault balance 在升级前后是连续的 | 升级前任何人调一次 `withdraw()` 把存量发到旧 recipient；不调的话存量将归新 recipient                |
| 2   | 编译参数错 → impl 字节码模板和 mainnet 不一致                                          | `verify.sh` 会做 sha256 比对，对不上立即 abort                                       |
| 3   | `_withdrawalNetwork = 1` 时 recipient 必须能在 L2 上接收 HSK                     | 部署前用 `cast code` 确认是 EOA 或带 `receive()` 的合约，且 receive 在 400k gas 内不 revert |
| 4   | gasLimit 给 300000 不够                                                     | upgrade 实际 ~50k，留余量充足；如要保守可调 `L2_GAS_LIMIT=500000`                         |
| 5   | mainnet 操作不可逆                                                            | 强烈建议先在 testnet 用同流程演练一遍                                                    |
| 6   | L1 Safe 多签未配齐 owner / threshold 不足                                       | 提交前在 Safe UI 检查 owners + threshold                                         |


