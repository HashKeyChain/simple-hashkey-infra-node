# Jovian 升级与验证操作文档

这个目录下的脚本用于本地链 Jovian 升级后的 L1 `SystemConfig` 升级、参数设置和 L2 生效验证。所有命令默认从仓库根目录执行：

```bash
cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node
```

## 1. 前置条件

执行这些脚本前，需要先完成本地链初始化和启动：

```bash
bash scripts/deploy-chain/chain-setup.sh local
bash scripts/chain-ops/chain-start.sh
```

确认 `.envrc` 中至少有这些变量：

```bash
L1_RPC_URL=...
L2_RPC_URL=...
GS_ADMIN_PRIVATE_KEY=...
CONTRACTS_BEDROCK_PATH=...
DEPLOYMENT_CONFIG_PATH=...
```

脚本会读取 `artifact.json` 中的 `SystemConfigProxy`、`ProxyAdmin`、`SystemOwnerSafe` 等地址。默认交易私钥来自 `GS_ADMIN_PRIVATE_KEY`，也可以用每个脚本对应的私钥环境变量覆盖。

## 2. 推荐执行顺序

完整流程建议按这个顺序走：

```bash
# 1. 部署 Jovian 版本 SystemConfig implementation
bash scripts/jovian/deploy-systemconfig.sh

# 2. 把 SystemConfigProxy 升级到上一步输出的 implementation
bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>

# 3. 停止 L2 服务；不要停止 Anvil/L1
bash scripts/chain-ops/chain-stop.sh

# 4. 配置分叉时间
source .envrc
NOW_HEX=$(cast block latest --rpc-url "$L1_RPC_URL" --json | jq -r .timestamp)
NOW=$((NOW_HEX))
FJORD=$((NOW + 120))
GRANITE=$((FJORD + 300))
HOLOCENE=$((GRANITE + 300))
ISTHMUS=$((HOLOCENE + 300))
JOVIAN=$((ISTHMUS + 300))

jq \
  --argjson fjord "$FJORD" \
  --argjson granite "$GRANITE" \
  --argjson holocene "$HOLOCENE" \
  --argjson isthmus "$ISTHMUS" \
  --argjson jovian "$JOVIAN" \
  '.fjord_time = $fjord
   | .granite_time = $granite
   | .holocene_time = $holocene
   | .isthmus_time = $isthmus
   | .jovian_time = $jovian' \
  "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"

# 5. 从 rollup.json 读取 fork 时间，写入 .envrc 的 OP_GETH_OVERRIDE_FLAGS。
#    op-geth 的启动参数已收敛到 scripts/chain-ops/run-op-geth.sh（唯一真源），它会 source .envrc
#    并把 OP_GETH_OVERRIDE_FLAGS 追加到 op-geth flags 末尾；chain-start.sh 编排调用它即可生效。
python3 - <<'PY'
import json
import os
import re
from pathlib import Path

rollup_path = Path(os.environ["DEPLOYMENT_CONFIG_PATH"]) / "rollup.json"
envrc = Path(".envrc")

rollup = json.loads(rollup_path.read_text())
forks = {
    "fjord": rollup["fjord_time"],
    "granite": rollup["granite_time"],
    "holocene": rollup["holocene_time"],
    "isthmus": rollup["isthmus_time"],
    "jovian": rollup["jovian_time"],
}

override = " ".join(f"--override.{name}={ts}" for name, ts in forks.items())
new_line = f'export OP_GETH_OVERRIDE_FLAGS="{override}"'

text = envrc.read_text()
pattern = re.compile(r'^export OP_GETH_OVERRIDE_FLAGS=.*$', re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(new_line, text)
else:
    text = text.rstrip("\n") + "\n" + new_line + "\n"

envrc.write_text(text)
print("Updated .envrc OP_GETH_OVERRIDE_FLAGS:", override)
PY

# 6. 重启 L2 服务
bash scripts/chain-ops/chain-start.sh local

# 7. 查询当前 L1/L2 参数状态
bash scripts/jovian/query-systemconfig-params.sh

# 8. 设置 operator fee 参数
bash scripts/jovian/set-operator-fee.sh 1 1000000

# 9. 发一笔 L2 交易验证 operator fee 和 Jovian receipt 字段
bash scripts/jovian/verify-jovian-fees.sh

# 10. 设置 minBaseFee，单位是 wei
bash scripts/jovian/set-min-base-fee.sh 1000000000

# 11. 验证 minBaseFee 是否进入 L2 block extraData，并且 baseFeePerGas >= minBaseFee
bash scripts/jovian/verify-min-base-fee.sh 1000000000

# 12. 设置 EIP-1559 参数：denominator、elasticity
bash scripts/jovian/set-eip1559-params.sh 250 6

# 13. 设置 DA footprint gas scalar
bash scripts/jovian/set-da-footprint-gas-scalar.sh 400

# 14. 最后再统一查询一次
bash scripts/jovian/query-systemconfig-params.sh
```

配置分叉时间时只停止 L2，不要停止 Anvil/L1。`rollup.json` 给 `op-node` 使用，`--override.*` 给 `op-geth` 使用，两边时间必须一致。L1 配置交易确认后，L2 不一定立刻生效；需要等 `op-node` derive 到包含该 L1 交易的 L1 block，后续 L2 block 才会带上新配置。

## 3. 脚本说明

### 3.1 部署和升级 SystemConfig

`deploy-systemconfig.sh`

```bash
bash scripts/jovian/deploy-systemconfig.sh [contracts_ref]
```

作用：

- 切到指定 contracts 分支；默认读取 `scripts/jovian/upgrade.env` 的 `CONTRACTS_UPGRADE_REF`（已从全局 `.envrc` 移出）；该文件不存在时用脚本内置默认值兜底。
- 如果命令行传入 `[contracts_ref]`，则临时覆盖 `CONTRACTS_UPGRADE_REF`（优先级：命令行 > upgrade.env > 脚本默认）。
- 编译合约并部署新的 `SystemConfig` implementation。
- 只部署 implementation，不升级 proxy，不修改 `artifact.json`。

输出里的 `SystemConfig implementation` 要作为下一步 `upgrade-systemconfig.sh` 的入参。

`upgrade-systemconfig.sh`

```bash
bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>
```

作用：

- 检查新 implementation 在 L1 上有 code。
- 通过 `ProxyAdmin.upgrade(SystemConfigProxy, newImplementation)` 升级代理。
- 升级后查询 `SystemConfig.version()` 验证 proxy 已指向新实现。
- 不部署 implementation，不设置任何 Jovian 参数，不修改 `artifact.json`。

## 4. 参数设置脚本

### 4.1 Operator Fee

```bash
bash scripts/jovian/set-operator-fee.sh [scalar] [constant]
```

默认值：

- `scalar = ${OPERATOR_FEE_SCALAR:-1}`
- `constant = ${OPERATOR_FEE_CONSTANT:-1000000}`

作用：

- 调用 L1 `SystemConfig.setOperatorFeeScalars(uint32,uint64)`。
- 设置后先验证 L1 `SystemConfig` 中的值。
- 等 L2 derive 后，可以用 `query-systemconfig-params.sh` 或 `verify-jovian-fees.sh` 验证 L2 生效。

验证重点：

- L2 `GasPriceOracle.isJovian()` 返回 `true`。
- L2 receipt 中出现 `operatorFeeScalar`、`operatorFeeConstant`。
- `OperatorFeeVault` 余额增量等于脚本计算出的 operator fee。

### 4.2 Min Base Fee

```bash
bash scripts/jovian/set-min-base-fee.sh [min_base_fee_wei]
```

默认值：

- `min_base_fee_wei = ${MIN_BASE_FEE:-1000000000}`

作用：

- 调用 L1 `SystemConfig.setMinBaseFee(uint64)`。
- 设置前会打印当前 L2 `baseFeePerGas`，方便选择一个能明显触发 clamp 的 `minBaseFee`。
- `0` 表示关闭最小 base fee 约束。

建议：

- 如果想看到明显效果，设置值应大于当前 L2 `baseFeePerGas`。
- 最准确的验证方式是查 L2 最新区块的 `extraData.minBaseFee` 和 `baseFeePerGas`，不是看单笔交易。

验证：

```bash
bash scripts/jovian/verify-min-base-fee.sh [expected_min_base_fee_wei]
```

如果不传入参，脚本会读取 L1 `SystemConfig.minBaseFee()` 作为期望值。

### 4.3 EIP-1559 Params

```bash
bash scripts/jovian/set-eip1559-params.sh [denominator] [elasticity]
```

默认值：

- `denominator = ${EIP1559_DENOMINATOR:-250}`
- `elasticity = ${EIP1559_ELASTICITY:-6}`

作用：

- 调用 L1 `SystemConfig.setEIP1559Params(uint32,uint32)`。
- 两个参数都必须大于等于 `1`，脚本会拒绝 `0`。
- 生效后会进入 L2 block `extraData`，控制后续区块 `baseFeePerGas` 的调整速度和目标 gas 使用量。

验证方式：

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

重点看 `L2 latest block fee params` 中的：

- `extraData.denominator`
- `extraData.elasticity`
- `baseFeePerGas`

### 4.4 DA Footprint Gas Scalar

```bash
bash scripts/jovian/set-da-footprint-gas-scalar.sh [scalar]
```

默认值：

- `scalar = ${DA_FOOTPRINT_GAS_SCALAR:-400}`

作用：

- 调用 L1 `SystemConfig.setDAFootprintGasScalar(uint16)`。
- 该值用于把交易预估 DA size 转成区块内的 DA footprint gas 额度。
- L1 设置为 `0` 时，L2 derivation 会映射到默认值 `400`。

验证方式：

```bash
bash scripts/jovian/query-systemconfig-params.sh
bash scripts/jovian/verify-jovian-fees.sh
```

重点看：

- L1 `SystemConfig.daFootprintGasScalar`
- L2 `L1Block.daFootprintGasScalar`
- receipt 中的 `daFootprintGasScalar`
- receipt 中的 `blobGasUsed`

这里的 `blobGasUsed` 是 OP Stack 复用字段，用来表达 DA footprint 累积量，不表示 OP L2 支持用户发送原生 EIP-4844 blob 交易。

## 5. 查询和验证脚本

### 5.1 query-systemconfig-params.sh

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

这是只读查询脚本，不发交易。

查询内容：

- L1 `SystemConfig` 参数：`operatorFeeScalar`、`operatorFeeConstant`、`daFootprintGasScalar`、`minBaseFee`、`eip1559Denominator`、`eip1559Elasticity`。
- L2 `L1Block` predeploy 派生值：`operatorFeeScalar`、`operatorFeeConstant`、`daFootprintGasScalar`。
- L2 最新区块：`baseFeePerGas`、`extraData`、`extraData.minBaseFee`、`extraData.denominator`、`extraData.elasticity`。
- L2 `GasPriceOracle`：`isIsthmus()`、`isJovian()`、`getOperatorFee(21000)`。

### 5.2 verify-jovian-fees.sh

```bash
bash scripts/jovian/verify-jovian-fees.sh [private_key] [to]
```

默认值：

- `private_key = $DEPLOY_PRIVATE_KEY`
- `to = 0x000000000000000000000000000000000000dEaD`

这是交易型验证脚本，会在 L2 发送一笔交易。执行前发送方必须有 L2 native token 余额。

验证内容：

- Jovian fork flag 是否打开。
- receipt 是否包含 `operatorFeeScalar`、`operatorFeeConstant`、`daFootprintGasScalar`、`blobGasUsed`。
- operator fee 计算值是否等于 `OperatorFeeVault` 余额增量。

### 5.3 verify-min-base-fee.sh

```bash
bash scripts/jovian/verify-min-base-fee.sh [expected_min_base_fee_wei]
```

这是区块型验证脚本，不发交易。

验证内容：

- L1 `SystemConfig.minBaseFee()` 是否等于期望值。
- L2 最新区块 `extraData` 是否是 Jovian 17 字节格式。
- `extraData.minBaseFee` 是否等于期望值。
- L2 `baseFeePerGas` 是否大于等于 `minBaseFee`。

可调环境变量：

```bash
VERIFY_MIN_BASE_FEE_ATTEMPTS=60
VERIFY_MIN_BASE_FEE_INTERVAL=2
```

## 6. 验证原则

Jovian 参数传播路径是：

```text
L1 SystemConfig
  -> L1 ConfigUpdate event
  -> op-node derive
  -> L2 payload attributes
  -> op-geth 出块
  -> L2 block / L2 predeploy / RPC receipt
```

不同参数的最佳验证位置不同：

- `minBaseFee`：优先验证 L2 block `extraData.minBaseFee` 和 `baseFeePerGas >= minBaseFee`。
- `eip1559Denominator` / `eip1559Elasticity`：优先验证 L2 block `extraData`。
- `operatorFeeScalar` / `operatorFeeConstant`：先查 L2 `L1Block`，再用 L2 交易 receipt 和 `OperatorFeeVault` delta 验证实际收费。
- `daFootprintGasScalar`：先查 L2 `L1Block`，再用 receipt 中的 `daFootprintGasScalar` 和 `blobGasUsed` 验证交易路径。

receipt 里的 OP Stack 扩展字段是 RPC 查询时补充出来的字段，不是共识层 receipt RLP 原始字段。

## 7. 常见问题

### L1 已设置，但 L2 还没变

先确认 L1 设置交易已经成功，再等待 `op-node` derive 到对应 L1 block。可以过一会儿重新执行：

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

### receipt 里的 operator fee 字段是 null

如果 `operatorFeeScalar` 和 `operatorFeeConstant` 都是 `0`，查询 receipt 时可能看不到这两个字段或显示为 `null`。先设置非零 operator fee，再发新的 L2 交易验证。

### minBaseFee 设置后看不到 baseFee 变化

如果设置的 `minBaseFee` 小于等于当前 L2 `baseFeePerGas`，clamp 效果不明显。可以先执行：

```bash
bash scripts/jovian/set-min-base-fee.sh
```

脚本会打印当前 L2 `baseFeePerGas`，再选择一个更高的 `minBaseFee` 测试。

### EIP-1559 参数能不能设置为 0

不能用 `set-eip1559-params.sh` 设置为 `0`。`SystemConfig.setEIP1559Params` 不接受 `0`，脚本也会提前拦截。

### DA footprint 的 0 是什么意思

`daFootprintGasScalar` 在 L1 `SystemConfig` 中可以是 `0`，但 L2 derivation 会把它映射成默认值 `400`。所以 L1 看到 `0`、L2 看到 `400` 是预期行为。
