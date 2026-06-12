# EIP-7702 Verification

This folder verifies EIP-7702 support after the Isthmus/Jovian upgrade path is active.

Run from the repository root:

```bash
bash scripts/jovian/7702/run.sh
```

Optional arguments:

```bash
bash scripts/jovian/7702/run.sh <payer_private_key> <delegate_address>
```

If `delegate_address` is omitted, the verifier compiles and deploys `EIP7702Delegate.sol` first.

The verification checks:

- `GasPriceOracle.isIsthmus()` is `true`.
- `GasPriceOracle.isJovian()` is `true`.
- A real EIP-7702 `SetCodeTx` with `authorizationList` is accepted on L2.
- The temporary authority account code becomes `0xef0100 + delegate_address`.
- Calling the authority account executes `EIP7702Delegate` through 7702 delegation and returns the expected magic value.

This script sends real L2 transactions and should be used in local or testnet environments.
