# Local CGT Jovian Upgrade Runbook

This runbook rebuilds a local Custom Gas Token OP Stack chain from scratch, starts L1/L2, activates Fjord through Jovian, bridges gas token to L2, and verifies Jovian fee behavior.

## 1. Reset Local Environment

This deletes the current local L2 data and local generated configs.

```bash
cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node

bash scripts/chain-stop.sh || true
docker stop anvil-chain 2>/dev/null || true

rm -rf data/
source .envrc
rm -rf "$DEPLOYMENT_CONFIG_PATH"/
```

Clear the previous local custom gas token address. A freshly rebuilt Anvil chain does not contain contracts from the previous local chain:

```bash
python3 - <<'PY'
from pathlib import Path

path = Path(".envrc")
s = path.read_text()
s = "\n".join(
    "export CUSTOM_GAS_TOKEN_ADDRESS=" if line.startswith("export CUSTOM_GAS_TOKEN_ADDRESS=") else line
    for line in s.splitlines()
) + "\n"
path.write_text(s)
PY
```

## 2. Check `.envrc`

Expected local values:

```bash
source .envrc

echo "DEPLOYMENT_CONTEXT=$DEPLOYMENT_CONTEXT"
echo "USE_CUSTOM_GAS_TOKEN=$USE_CUSTOM_GAS_TOKEN"
echo "CUSTOM_GAS_TOKEN_ADDRESS=$CUSTOM_GAS_TOKEN_ADDRESS"
echo "L1_BLOCK_TIME=$L1_BLOCK_TIME"
echo "L2_BLOCK_TIME=$L2_BLOCK_TIME"
```

Recommended values:

```bash
export DEPLOYMENT_CONTEXT=local-mainnet
export USE_CUSTOM_GAS_TOKEN=true
export L1_BLOCK_TIME=12
export L2_BLOCK_TIME=2
```

For a rebuilt local L1, `CUSTOM_GAS_TOKEN_ADDRESS` should be empty before setup so the script deploys a token on the current Anvil chain:

```bash
export CUSTOM_GAS_TOKEN_ADDRESS=
```

Then reload:

```bash
source .envrc
```

## 3. Deploy L1 Contracts And Generate L2 Config

```bash
bash scripts/chain-setup.sh local
```

This should:

- Start a new local anvil L1 with `L1_BLOCK_TIME`.
- Fund deploy/operator accounts on L1.
- Deploy or reuse the custom gas token.
- Deploy OP L1 contracts.
- Generate `$DEPLOYMENT_CONFIG_PATH/artifact.json`.
- Generate `$DEPLOYMENT_CONFIG_PATH/genesis.json`.
- Generate `$DEPLOYMENT_CONFIG_PATH/rollup.json`.

## 4. Patch `rollup.json` Compatibility

> This step is now automated. `scripts/chain-setup.sh` calls
> `scripts/patch-rollup-config.sh` right after deployment, so after Step 3 the
> `rollup.json` is already patched and you can go straight to Step 5. The
> commands below are kept for reference / manual re-run only.

The automated patch does three things (all idempotent):

1. **Refresh the L1 genesis hash** (local only). Uses the L1 block number already
   recorded in `rollup.json`; this block hash changes every time the local L1 is
   rebuilt. Skipped for `remote` because a real L1 already has the correct hash.
2. **Remove `da_challenge_contract_address`**, which the runtime
   `cgt-jovian/v1.16.5` op-node does not understand.
3. **Ensure `chain_op_config` exists** with the EIP-1559 params below.

To run it manually (e.g. after rebuilding anvil without re-running setup):

```bash
bash scripts/patch-rollup-config.sh local
```

For reference, the equivalent raw commands are:

```bash
# 1) refresh genesis.l1.hash (local only)
L1_GENESIS_NUMBER=$(jq -r '.genesis.l1.number' "$DEPLOYMENT_CONFIG_PATH/rollup.json")
L1_GENESIS_HASH=$(cast block "$L1_GENESIS_NUMBER" --rpc-url http://localhost:8545 --json | jq -r '.hash')

jq --arg hash "$L1_GENESIS_HASH" \
  '.genesis.l1.hash = $hash' \
  "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"

# 2) remove field the runtime op-node does not understand
jq 'del(.da_challenge_contract_address)' \
  "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"

# 3) ensure chain_op_config exists
jq '.chain_op_config = {
  "eip1559Elasticity": 6,
  "eip1559Denominator": 50,
  "eip1559DenominatorCanyon": 250
}' "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"
```

Check:

```bash
jq '{genesis, chain_op_config}' "$DEPLOYMENT_CONFIG_PATH/rollup.json"
```

Also verify the generated L1 contract addresses exist on the currently running Anvil chain. A code length of `3` means `0x`, i.e. the contract is missing from this L1:

```bash
for key in SystemConfigProxy OptimismPortalProxy L1StandardBridgeProxy L2OutputOracleProxy; do
  addr=$(jq -r ".$key" "$DEPLOYMENT_CONFIG_PATH/artifact.json")
  len=$(cast code "$addr" --rpc-url http://localhost:8545 | wc -c | tr -d ' ')
  echo "$key $addr code_len=$len"
done
```

## 5. Start L2 Services

```bash
bash scripts/chain-start.sh local
```

Verify L2 is producing blocks:

```bash
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp,hash}'
```

Check `op-node` sync progress. `unsafe_l2` should keep increasing, and `safe_l2` should also move forward. The gaps can be non-zero, but they should not stay frozen forever:

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | jq '.result | {
    unsafe_l2:.unsafe_l2.number,
    safe_l2:.safe_l2.number,
    finalized_l2:.finalized_l2.number,
    l2_gap:(.unsafe_l2.number - .safe_l2.number),
    unsafe_l1:.unsafe_l2.l1origin.number,
    safe_l1:.safe_l2.l1origin.number,
    l1_gap:(.unsafe_l2.l1origin.number - .safe_l2.l1origin.number)
  }'
```

To watch it continuously:

```bash
while true; do
  curl -s -X POST -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
    http://localhost:9545 | jq '.result | {
      unsafe_l2:.unsafe_l2.number,
      safe_l2:.safe_l2.number,
      l2_gap:(.unsafe_l2.number - .safe_l2.number),
      unsafe_l1:.unsafe_l2.l1origin.number,
      safe_l1:.safe_l2.l1origin.number,
      l1_gap:(.unsafe_l2.l1origin.number - .safe_l2.l1origin.number)
    }'
  sleep 10
done
```

## 6. Configure Fork Activation Times

Wait until L2 has produced a few blocks, then set future fork times.

```bash
NOW_HEX=$(cast block latest --rpc-url http://localhost:8645 --json | jq -r .timestamp)
NOW=$((NOW_HEX))

FJORD=$((NOW + 120))
GRANITE=$((FJORD + 300))
HOLOCENE=$((GRANITE + 300))
ISTHMUS=$((HOLOCENE + 300))
JOVIAN=$((ISTHMUS + 300))

echo "FJORD=$FJORD"
echo "GRANITE=$GRANITE"
echo "HOLOCENE=$HOLOCENE"
echo "ISTHMUS=$ISTHMUS"
echo "JOVIAN=$JOVIAN"
```

Write these times to `$DEPLOYMENT_CONFIG_PATH/rollup.json` for `op-node`:

```bash
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
```

Write the same fork times into `.envrc` as `OP_GETH_OVERRIDE_FLAGS`, so `op-geth` gets them
through `scripts/run-op-geth.sh`（组件 flags 唯一真源，会 source .envrc 并追加该变量）：

```bash
export FJORD GRANITE HOLOCENE ISTHMUS JOVIAN

python3 - <<'PY'
import os
import re
from pathlib import Path

envrc = Path(".envrc")

forks = {
    "fjord": os.environ["FJORD"],
    "granite": os.environ["GRANITE"],
    "holocene": os.environ["HOLOCENE"],
    "isthmus": os.environ["ISTHMUS"],
    "jovian": os.environ["JOVIAN"],
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
```

Confirm both sides match:

```bash
jq '{fjord_time, granite_time, holocene_time, isthmus_time, jovian_time}' "$DEPLOYMENT_CONFIG_PATH/rollup.json"
rg -- 'OP_GETH_OVERRIDE_FLAGS' .envrc
```

## 7. Restart L2 Services

Do not stop anvil here.

```bash
bash scripts/chain-stop.sh
bash scripts/chain-start.sh local
```

## 8. Watch Fork Activation

```bash
rg "Sequencing Fjord upgrade block|Sequencing Granite upgrade block|Sequencing Isthmus upgrade block|Sequencing Jovian upgrade block|error|crit" data/logs/op-node.log
```

Check fork flags:

```bash
cast call 0x420000000000000000000000000000000000000F \
  "isFjord()(bool)" \
  --rpc-url http://localhost:8645

cast call 0x420000000000000000000000000000000000000F \
  "isIsthmus()(bool)" \
  --rpc-url http://localhost:8645

cast call 0x420000000000000000000000000000000000000F \
  "isJovian()(bool)" \
  --rpc-url http://localhost:8645
```

Check latest L2 time:

```bash
cast block latest --rpc-url http://localhost:8645 --json | jq '{number,timestamp,baseFeePerGas,hash}'
```

## 9. Bridge Custom Gas Token To L2

Use the deploy key and deploy address from `.envrc`.

```bash
bash scripts/bridge-to-l2.sh 100ether
```

Monitor derivation until `unsafe_l1` reaches the L1 block that included the deposit:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"optimism_syncStatus","params":[],"id":1}' \
  http://localhost:9545 | jq '.result | {
    unsafe_l2: .unsafe_l2.number,
    safe_l2: .safe_l2.number,
    unsafe_l1: .unsafe_l2.l1origin.number,
    safe_l1: .safe_l2.l1origin.number
  }'
```

Check L2 native balance:

```bash
source .envrc
cast balance "$DEPLOY_ADDRESS" --rpc-url http://localhost:8645
```

## 10. Verify Jovian Fee Behavior

After the deploy address has L2 native balance:

```bash
bash scripts/jovian/verify-jovian-fees.sh
```

This verifies:

- Latest L2 block.
- `GasPriceOracle.isFjord()`.
- `GasPriceOracle.isIsthmus()`.
- `GasPriceOracle.isJovian()`.
- `OperatorFeeVault` has runtime code.
- A normal L2 transaction succeeds.
- Receipt contains `operatorFeeScalar` and `operatorFeeConstant`.
- Receipt contains `daFootprintGasScalar` and `blobGasUsed`.
- `OperatorFeeVault` balance increases, unless operator fee params are zero.

## Important Notes

- `chain-start.sh`, `chain-setup.sh`, and `run-anvil.sh` should use `--block-time $L1_BLOCK_TIME`, not `--block-time 1`.
- Do not stop anvil between `chain-setup.sh` and `chain-start.sh`; otherwise the L1 genesis/hash context changes.
- If anvil is restarted from scratch, rerun `chain-setup.sh local`.
- `op-node` reads `$DEPLOYMENT_CONFIG_PATH/rollup.json` on startup.
- `op-geth` does not reread `genesis.json` on every startup; this runbook uses `--override.*` flags for fork times instead.
- For CGT chains, bridge gas token with `depositERC20Transaction`; ordinary ETH deposits do not fund native L2 gas.
