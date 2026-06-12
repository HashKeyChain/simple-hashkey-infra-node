# Fork Verification Scripts

This folder contains simple post-fork verification scripts for external/private networks.

Each fork verification script sends one zero-value L2 transaction from `L2_VERIFY_PRIVATE_KEY` to itself and checks the fork-specific state.

## Config

Create `verify.env` once:

```bash
cp scripts/jovian/verify/verify.env.example scripts/jovian/verify/verify.env
```

Then edit `verify.env`:

```bash
L2_RPC=https://your-l2-rpc
L2_VERIFY_PRIVATE_KEY=0x...
L1_RPC=https://your-l1-rpc
SYSTEM_CONFIG_PROXY=0x...
SYSTEM_CONFIG_PRIVATE_KEY=0x...
SYSTEM_CONFIG_CONTRACTS_REPO=/path/to/op-contracts-repo
SYSTEM_CONFIG_CONTRACTS_REF=...
GRANITE_TIME=...
HOLOCENE_TIME=...
ISTHMUS_TIME=...
JOVIAN_TIME=...
EXPECTED_EIP1559_DENOMINATOR=...
EXPECTED_EIP1559_ELASTICITY=...
SET_EIP1559_DENOMINATOR=...
SET_EIP1559_ELASTICITY=...
SET_MIN_BASE_FEE=...
SET_OPERATOR_FEE_SCALAR=...
SET_OPERATOR_FEE_CONSTANT=...
SET_DA_FOOTPRINT_GAS_SCALAR=...
```

Use `0` for fork times to skip timestamp comparison and only run the RPC/transaction checks.
Use `0` for expected EIP-1559 params to only require decoded values to be non-zero.

`verify.env` is ignored by git because it may contain a real private key.

The SystemConfig setter scripts assume `SYSTEM_CONFIG_PRIVATE_KEY` is the direct EOA owner of `SystemConfigProxy`.
They intentionally do not implement Safe/multisig execution, so the scripts stay readable for private-network verification.

## Deploy And Verify SystemConfig On Sepolia

Fill the L1 deployment and Etherscan verification values in `verify.env`:

```bash
L1_RPC=https://your-sepolia-rpc
SYSTEM_CONFIG_PRIVATE_KEY=0x...
SYSTEM_CONFIG_CONTRACTS_REPO=/Users/zhuangqianwei/github.com/HashKeyChain/optimism
SYSTEM_CONFIG_CONTRACTS_REF=cgt-jovian/contracts-v2.0.0-beta.2

SYSTEM_CONFIG_VERIFIER=etherscan
SYSTEM_CONFIG_VERIFIER_URL=
SYSTEM_CONFIG_ETHERSCAN_API_KEY=your_etherscan_api_key
SYSTEM_CONFIG_CHAIN_ID=11155111
```

Then run:

```bash
bash scripts/jovian/verify/deploy-systemconfig.sh
```

This script deploys `src/L1/SystemConfig.sol:SystemConfig` and then submits the source code verification to Sepolia Etherscan with `forge verify-contract`.

## Usage

Set SystemConfig values:

```bash
bash scripts/jovian/verify/deploy-systemconfig.sh
bash scripts/jovian/verify/set-systemconfig-eip1559.sh
bash scripts/jovian/verify/set-systemconfig-min-base-fee.sh
bash scripts/jovian/verify/set-systemconfig-operator-fee.sh
bash scripts/jovian/verify/set-systemconfig-da-footprint.sh
```

Query SystemConfig and L2 derived values:

```bash
bash scripts/jovian/verify/query-systemconfig-params.sh
```

Verify each fork:

```bash
bash scripts/jovian/verify/verify-granite.sh
bash scripts/jovian/verify/verify-holocene.sh
bash scripts/jovian/verify/verify-isthmus.sh
bash scripts/jovian/verify/verify-jovian.sh
bash scripts/jovian/verify/verify-7702.sh
```

## Scripts

- `deploy-systemconfig.sh`: deploys `src/L1/SystemConfig.sol:SystemConfig` from `SYSTEM_CONFIG_CONTRACTS_REF`.
- `set-systemconfig-eip1559.sh`: calls `SystemConfig.setEIP1559Params(uint32,uint32)`.
- `set-systemconfig-min-base-fee.sh`: calls `SystemConfig.setMinBaseFee(uint64)`.
- `set-systemconfig-operator-fee.sh`: calls `SystemConfig.setOperatorFeeScalars(uint32,uint64)`.
- `set-systemconfig-da-footprint.sh`: calls `SystemConfig.setDAFootprintGasScalar(uint16)`.
- `query-systemconfig-params.sh`: queries L1 `SystemConfig`, L2 `L1Block`, latest L2 block `extraData`, and `GasPriceOracle` values using `verify.env`.
- `verify-granite.sh`: latest block timestamp and ordinary L2 transaction.
- `verify-holocene.sh`: EIP-1559 denominator/elasticity from block `extraData` and ordinary L2 transaction.
- `verify-isthmus.sh`: EIP-1559 params from `extraData` (9-byte Holocene/Isthmus or 17-byte Jovian format), `GasPriceOracle.isIsthmus()`, and `OperatorFeeVault` balance before/after an ordinary L2 transaction.
- `verify-jovian.sh`: `GasPriceOracle.isJovian()`, EIP-1559 params and `minBaseFee` from block `extraData`, L2 `L1Block` Jovian values, and ordinary L2 transaction receipt fields.
- `verify-7702.sh`: runs the EIP-7702 SetCodeTx verifier using `L2_RPC` and `L2_VERIFY_PRIVATE_KEY` from `verify.env`; fork flags are printed but not enforced.
