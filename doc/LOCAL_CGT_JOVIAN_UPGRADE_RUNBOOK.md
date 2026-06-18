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

Refresh the L1 genesis hash from the currently running local Anvil chain. Use the L1 block number already recorded in `rollup.json`; this block hash changes every time the local L1 is rebuilt:

```bash
L1_GENESIS_NUMBER=$(jq -r '.genesis.l1.number' "$DEPLOYMENT_CONFIG_PATH/rollup.json")
L1_GENESIS_HASH=$(cast block "$L1_GENESIS_NUMBER" --rpc-url http://localhost:8545 --json | jq -r '.hash')

jq --arg hash "$L1_GENESIS_HASH" \
  '.genesis.l1.hash = $hash' \
  "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"
```

Remove fields that the runtime `cgt-jovian/v1.16.5` op-node does not understand:

```bash
jq 'del(.da_challenge_contract_address)' \
  "$DEPLOYMENT_CONFIG_PATH/rollup.json" > /tmp/rollup.json \
  && mv /tmp/rollup.json "$DEPLOYMENT_CONFIG_PATH/rollup.json"
```

Ensure `chain_op_config` exists:

```bash
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

Update `scripts/chain-start.sh` so `op-geth` gets the same fork times through overrides:

```bash
export FJORD GRANITE HOLOCENE ISTHMUS JOVIAN

python3 - <<'PY'
import os
from pathlib import Path

path = Path("scripts/chain-start.sh")
s = path.read_text()

lines = []
for line in s.splitlines():
    if "--override.fjord=" in line or "--override.granite=" in line:
        continue
    lines.append(line)

s = "\n".join(lines) + "\n"

needle = 'OP_GETH_FLAGS="--verbosity=3 --datadir=$OP_GETH_DATA_PATH --http --http.corsdomain=* --http.vhosts=* --http.addr=0.0.0.0 --http.port=8645 --http.api=web3,debug,eth,txpool,net,engine,miner --ws --ws.addr=0.0.0.0 --ws.port=8646 --ws.origins=* --ws.api=debug,eth,txpool,net,engine,miner --syncmode=full --gcmode=archive --nodiscover --maxpeers=0 --networkid=42069 --authrpc.vhosts=* --authrpc.addr=0.0.0.0 --authrpc.port=8651 --authrpc.jwtsecret=$JWT_FILE --state.scheme=hash"'

insert = f'''{needle}
OP_GETH_FLAGS="$OP_GETH_FLAGS --override.fjord={os.environ["FJORD"]}"
OP_GETH_FLAGS="$OP_GETH_FLAGS --override.granite={os.environ["GRANITE"]} --override.holocene={os.environ["HOLOCENE"]} --override.isthmus={os.environ["ISTHMUS"]} --override.jovian={os.environ["JOVIAN"]}"'''

if needle not in s:
    raise SystemExit("Could not find OP_GETH_FLAGS line in scripts/chain-start.sh")

s = s.replace(needle, insert)
path.write_text(s)
PY
```

Confirm both sides match:

```bash
jq '{fjord_time, granite_time, holocene_time, isthmus_time, jovian_time}' "$DEPLOYMENT_CONFIG_PATH/rollup.json"
rg -- '--override\.(fjord|granite|holocene|isthmus|jovian)' scripts/chain-start.sh
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
