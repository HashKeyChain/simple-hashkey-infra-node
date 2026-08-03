# Jovian Upgrade and Verification Guide

The scripts in this directory upgrade the L1 `SystemConfig`, configure parameters, and verify L2 activation after a local-chain Jovian upgrade. Run all commands from the repository root unless otherwise noted:

```bash
cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node
```

## 1. Prerequisites

Set up and start the local chain before running these scripts:

```bash
bash scripts/deploy-chain/chain-setup.sh local
bash scripts/chain-ops/chain-start.sh local
```

Confirm that `.envrc` defines at least these variables:

```bash
L1_RPC_URL=...
L2_RPC_URL=...
GS_ADMIN_PRIVATE_KEY=...
CONTRACTS_BEDROCK_PATH=...
DEPLOYMENT_CONFIG_PATH=...
```

The scripts read addresses such as `SystemConfigProxy`, `ProxyAdmin`, and `SystemOwnerSafe` from `artifact.json`. Transactions use `GS_ADMIN_PRIVATE_KEY` by default; each script also supports a script-specific private-key environment variable as an override.

## 2. Recommended Execution Order

Run the complete workflow in this order:

```bash
# 1. Deploy the Jovian SystemConfig implementation
bash scripts/jovian/deploy-systemconfig.sh

# 2. Upgrade SystemConfigProxy to the implementation output by the previous step
bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>

# 3. Stop the L2 services; keep Anvil/L1 running
bash scripts/chain-stop.sh

# 4. Configure fork times
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

# 5. Read fork times from rollup.json and write OP_GETH_OVERRIDE_FLAGS to .envrc.
#    scripts/run-op-geth.sh is the single source of truth for op-geth startup
#    arguments. It sources .envrc and appends OP_GETH_OVERRIDE_FLAGS to the
#    op-geth flags; the chain-start.sh orchestration invokes it automatically.
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

# 6. Restart the L2 services
bash scripts/chain-ops/chain-start.sh local

# 7. Query the current L1/L2 parameter state
bash scripts/jovian/query-systemconfig-params.sh

# 8. Set operator fee parameters
bash scripts/jovian/set-operator-fee.sh 1 1000000

# 9. Send an L2 transaction to verify the operator fee and Jovian receipt fields
bash scripts/jovian/verify-jovian-fees.sh

# 10. Set minBaseFee in wei
bash scripts/jovian/set-min-base-fee.sh 1000000000

# 11. Verify that minBaseFee appears in L2 block extraData and baseFeePerGas >= minBaseFee
bash scripts/jovian/verify-min-base-fee.sh 1000000000

# 12. Set the EIP-1559 denominator and elasticity parameters
bash scripts/jovian/set-eip1559-params.sh 250 6

# 13. Set the DA footprint gas scalar
bash scripts/jovian/set-da-footprint-gas-scalar.sh 400

# 14. Query all parameters again
bash scripts/jovian/query-systemconfig-params.sh
```

When configuring fork times, stop only L2 and keep Anvil/L1 running. `op-node` uses `rollup.json`, while `op-geth` uses the `--override.*` flags; the times must match on both sides. The L2 changes may not take effect immediately after the L1 configuration transaction is confirmed. Wait for `op-node` to derive the L1 block containing that transaction; subsequent L2 blocks will then include the new configuration.

## 3. Script Reference

### 3.1 Deploying and Upgrading SystemConfig

`deploy-systemconfig.sh`

```bash
bash scripts/jovian/deploy-systemconfig.sh [contracts_ref]
```

Behavior:

- Switches to the specified contracts branch; defaults to `CONTRACTS_UPGRADE_REF` from `.envrc`.
- Temporarily overrides `CONTRACTS_UPGRADE_REF` when `[contracts_ref]` is provided on the command line.
- Compiles the contracts and deploys a new `SystemConfig` implementation.
- Deploys only the implementation; it does not upgrade the proxy or modify `artifact.json`.

Pass the `SystemConfig implementation` value from the output to `upgrade-systemconfig.sh` in the next step.

`upgrade-systemconfig.sh`

```bash
bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>
```

Behavior:

- Checks that the new implementation has code on L1.
- Upgrades the proxy through `ProxyAdmin.upgrade(SystemConfigProxy, newImplementation)`.
- Queries `SystemConfig.version()` after the upgrade to verify that the proxy points to the new implementation.
- Does not deploy an implementation, set any Jovian parameters, or modify `artifact.json`.

## 4. Parameter Configuration Scripts

### 4.1 Operator Fee

```bash
bash scripts/jovian/set-operator-fee.sh [scalar] [constant]
```

Defaults:

- `scalar = ${OPERATOR_FEE_SCALAR:-1}`
- `constant = ${OPERATOR_FEE_CONSTANT:-1000000}`

Behavior:

- Calls L1 `SystemConfig.setOperatorFeeScalars(uint32,uint64)`.
- Verifies the values in the L1 `SystemConfig` after setting them.
- After L2 derivation, use `query-systemconfig-params.sh` or `verify-jovian-fees.sh` to verify L2 activation.

Key checks:

- L2 `GasPriceOracle.isJovian()` returns `true`.
- The L2 receipt contains `operatorFeeScalar` and `operatorFeeConstant`.
- The `OperatorFeeVault` balance increase equals the operator fee calculated by the script.

### 4.2 Min Base Fee

```bash
bash scripts/jovian/set-min-base-fee.sh [min_base_fee_wei]
```

Default:

- `min_base_fee_wei = ${MIN_BASE_FEE:-1000000000}`

Behavior:

- Calls L1 `SystemConfig.setMinBaseFee(uint64)`.
- Prints the current L2 `baseFeePerGas` before configuration, making it easier to choose a `minBaseFee` that clearly triggers the clamp.
- `0` disables the minimum base fee constraint.

Recommendations:

- To make the effect clearly visible, set a value greater than the current L2 `baseFeePerGas`.
- The most accurate verification is to inspect `extraData.minBaseFee` and `baseFeePerGas` in the latest L2 block, rather than examining a single transaction.

Verification:

```bash
bash scripts/jovian/verify-min-base-fee.sh [expected_min_base_fee_wei]
```

If no argument is provided, the script reads L1 `SystemConfig.minBaseFee()` as the expected value.

### 4.3 EIP-1559 Params

```bash
bash scripts/jovian/set-eip1559-params.sh [denominator] [elasticity]
```

Defaults:

- `denominator = ${EIP1559_DENOMINATOR:-250}`
- `elasticity = ${EIP1559_ELASTICITY:-6}`

Behavior:

- Calls L1 `SystemConfig.setEIP1559Params(uint32,uint32)`.
- Both parameters must be at least `1`; the script rejects `0`.
- Once active, the values appear in L2 block `extraData` and control the rate at which `baseFeePerGas` changes and the target gas usage of subsequent blocks.

Verification:

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

Inspect these fields under `L2 latest block fee params`:

- `extraData.denominator`
- `extraData.elasticity`
- `baseFeePerGas`

### 4.4 DA Footprint Gas Scalar

```bash
bash scripts/jovian/set-da-footprint-gas-scalar.sh [scalar]
```

Default:

- `scalar = ${DA_FOOTPRINT_GAS_SCALAR:-400}`

Behavior:

- Calls L1 `SystemConfig.setDAFootprintGasScalar(uint16)`.
- Converts a transaction's estimated DA size into its DA footprint gas allowance within a block.
- When set to `0` on L1, L2 derivation maps it to the default value `400`.

Verification:

```bash
bash scripts/jovian/query-systemconfig-params.sh
bash scripts/jovian/verify-jovian-fees.sh
```

Inspect:

- L1 `SystemConfig.daFootprintGasScalar`
- L2 `L1Block.daFootprintGasScalar`
- `daFootprintGasScalar` in the receipt
- `blobGasUsed` in the receipt

Here, `blobGasUsed` is an OP Stack field reused to represent accumulated DA footprint. It does not indicate that the OP L2 supports native EIP-4844 blob transactions submitted by users.

## 5. Query and Verification Scripts

### 5.1 query-systemconfig-params.sh

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

This is a read-only query script; it does not send transactions.

It queries:

- L1 `SystemConfig` parameters: `operatorFeeScalar`, `operatorFeeConstant`, `daFootprintGasScalar`, `minBaseFee`, `eip1559Denominator`, and `eip1559Elasticity`.
- Derived values in the L2 `L1Block` predeploy: `operatorFeeScalar`, `operatorFeeConstant`, and `daFootprintGasScalar`.
- The latest L2 block: `baseFeePerGas`, `extraData`, `extraData.minBaseFee`, `extraData.denominator`, and `extraData.elasticity`.
- L2 `GasPriceOracle`: `isIsthmus()`, `isJovian()`, and `getOperatorFee(21000)`.

### 5.2 verify-jovian-fees.sh

```bash
bash scripts/jovian/verify-jovian-fees.sh [private_key] [to]
```

Defaults:

- `private_key = $DEPLOY_PRIVATE_KEY`
- `to = 0x000000000000000000000000000000000000dEaD`

This transaction-based verification script sends one transaction on L2. The sender must have an L2 native token balance before it runs.

It verifies:

- Whether the Jovian fork flag is enabled.
- Whether the receipt contains `operatorFeeScalar`, `operatorFeeConstant`, `daFootprintGasScalar`, and `blobGasUsed`.
- Whether the calculated operator fee equals the `OperatorFeeVault` balance increase.

### 5.3 verify-min-base-fee.sh

```bash
bash scripts/jovian/verify-min-base-fee.sh [expected_min_base_fee_wei]
```

This block-based verification script does not send transactions.

It verifies:

- Whether L1 `SystemConfig.minBaseFee()` equals the expected value.
- Whether the latest L2 block's `extraData` uses the 17-byte Jovian format.
- Whether `extraData.minBaseFee` equals the expected value.
- Whether L2 `baseFeePerGas` is greater than or equal to `minBaseFee`.

Configurable environment variables:

```bash
VERIFY_MIN_BASE_FEE_ATTEMPTS=60
VERIFY_MIN_BASE_FEE_INTERVAL=2
```

## 6. Verification Principles

Jovian parameters propagate through:

```text
L1 SystemConfig
  -> L1 ConfigUpdate event
  -> op-node derive
  -> L2 payload attributes
  -> op-geth block production
  -> L2 block / L2 predeploy / RPC receipt
```

The best verification point depends on the parameter:

- `minBaseFee`: Prefer verifying L2 block `extraData.minBaseFee` and `baseFeePerGas >= minBaseFee`.
- `eip1559Denominator` / `eip1559Elasticity`: Prefer verifying L2 block `extraData`.
- `operatorFeeScalar` / `operatorFeeConstant`: Check L2 `L1Block` first, then verify the actual charge using an L2 transaction receipt and the `OperatorFeeVault` balance delta.
- `daFootprintGasScalar`: Check L2 `L1Block` first, then verify the transaction path using `daFootprintGasScalar` and `blobGasUsed` in the receipt.

The OP Stack extension fields in receipts are added to RPC query responses; they are not part of the original consensus-layer receipt RLP.

## 7. Troubleshooting

### L1 is configured, but L2 has not changed

First confirm that the L1 configuration transaction succeeded, then wait for `op-node` to derive the corresponding L1 block. Run this command again after a short delay:

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

### Operator fee fields in the receipt are null

If both `operatorFeeScalar` and `operatorFeeConstant` are `0`, these fields may be absent or displayed as `null` when querying the receipt. Set a nonzero operator fee first, then send a new L2 transaction for verification.

### baseFee does not change after setting minBaseFee

If the configured `minBaseFee` is less than or equal to the current L2 `baseFeePerGas`, the clamp effect will not be obvious. First run:

```bash
bash scripts/jovian/set-min-base-fee.sh
```

The script prints the current L2 `baseFeePerGas`; then choose a higher `minBaseFee` for testing.

### Can EIP-1559 parameters be set to 0?

You cannot set these parameters to `0` with `set-eip1559-params.sh`. `SystemConfig.setEIP1559Params` does not accept `0`, and the script rejects it before sending a transaction.

### What does a DA footprint value of 0 mean?

`daFootprintGasScalar` may be `0` in the L1 `SystemConfig`, but L2 derivation maps it to the default value `400`. Therefore, seeing `0` on L1 and `400` on L2 is expected.
