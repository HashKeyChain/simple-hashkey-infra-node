# Remote L1 CGT Jovian Deploy Runbook

This runbook is for deploying OP Stack L1 contracts to an existing remote L1 RPC, generating L2 `genesis.json` and `rollup.json`, then starting the L2 services and running the Jovian upgrade/verification flow.

It is different from the local Anvil runbook:

- Do not start or stop Anvil.
- Do not use `anvil_setBalance`.
- All deploy/operator accounts must already have enough native L1 token on the remote L1.
- Use `chain-setup.sh remote`, not `chain-setup.sh local`.

## 1. Prepare Environment

```bash
cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node
cp .envrc.testnet.example .envrc
```

Edit `.envrc` and fill at least:

```bash
export DEPLOY_ADDRESS=0xREPLACE_ME_DEPLOY_ADDRESS
export DEPLOY_PRIVATE_KEY=0xREPLACE_ME_DEPLOY_PRIVATE_KEY

export GS_ADMIN_ADDRESS=0xREPLACE_ME_ADMIN_ADDRESS
export GS_ADMIN_PRIVATE_KEY=0xREPLACE_ME_ADMIN_PRIVATE_KEY

export GS_BATCHER_ADDRESS=0xREPLACE_ME_BATCHER_ADDRESS
export GS_BATCHER_PRIVATE_KEY=0xREPLACE_ME_BATCHER_PRIVATE_KEY

export GS_PROPOSER_ADDRESS=0xREPLACE_ME_PROPOSER_ADDRESS
export GS_PROPOSER_PRIVATE_KEY=0xREPLACE_ME_PROPOSER_PRIVATE_KEY

export GS_SEQUENCER_ADDRESS=0xREPLACE_ME_SEQUENCER_ADDRESS
export GS_SEQUENCER_PRIVATE_KEY=0xREPLACE_ME_SEQUENCER_PRIVATE_KEY

export L1_RPC_URL=https://REPLACE_ME_REMOTE_L1_RPC
export L1_CHAIN_ID=REPLACE_ME_REMOTE_L1_CHAIN_ID
export L2_CHAIN_ID=REPLACE_ME_NEW_L2_CHAIN_ID
export DEPLOYMENT_CONTEXT=remote-testnet
```

Recommended local values for this CGT Jovian flow:

```bash
export OP_CONTRACTS_REF=op-contracts/v2.0.0-beta.3
export CONTRACTS_UPGRADE_REF=cgt-jovian/contracts-v2.0.0-beta.3
export USE_CUSTOM_GAS_TOKEN=true
export USE_FAULT_PROOFS=true
```

If you want the setup script to deploy a fresh custom gas token on the remote L1, keep:

```bash
export CUSTOM_GAS_TOKEN_ADDRESS=
```

If reusing an existing custom gas token on that L1, set:

```bash
export CUSTOM_GAS_TOKEN_ADDRESS=0xREPLACE_ME_EXISTING_L1_TOKEN
```

Reload:

```bash
source .envrc
```

## 2. Check L1 Readiness

The remote L1 RPC must be reachable and return the expected chain ID:

```bash
cast chain-id --rpc-url "$L1_RPC_URL"
cast block latest --rpc-url "$L1_RPC_URL"
```

Check that the configured private keys match the configured addresses:

```bash
cast wallet address --private-key "$DEPLOY_PRIVATE_KEY"
cast wallet address --private-key "$GS_ADMIN_PRIVATE_KEY"
cast wallet address --private-key "$GS_BATCHER_PRIVATE_KEY"
cast wallet address --private-key "$GS_PROPOSER_PRIVATE_KEY"
cast wallet address --private-key "$GS_SEQUENCER_PRIVATE_KEY"
```

Check L1 balances:

```bash
for addr in "$DEPLOY_ADDRESS" "$GS_ADMIN_ADDRESS" "$GS_BATCHER_ADDRESS" "$GS_PROPOSER_ADDRESS" "$GS_SEQUENCER_ADDRESS"; do
  echo "$addr $(cast balance "$addr" --rpc-url "$L1_RPC_URL")"
done
```

For remote L1 deployment, fund these accounts before setup. The scripts will not mint balances on a remote L1.

## 3. Build Binaries

If binaries are not built yet:

```bash
git submodule update --init --recursive
bash scripts/build-binaries.sh
```

Make sure these binaries exist:

```bash
ls -l bin/op-geth bin/op-node bin/op-batcher bin/op-proposer
```

If `USE_FAULT_PROOFS=true` and you plan to run challenger, also build/copy `op-challenger`, `op-program`, `cannon`, and the required prestate.

## 4. Deploy L1 Contracts And Generate L2 Config

Run setup in remote mode:

```bash
bash scripts/deploy-chain/chain-setup.sh remote
```

This will:

- Use `$L1_RPC_URL` from `.envrc`.
- Deploy or reuse the custom gas token.
- Generate deploy config for `$DEPLOYMENT_CONTEXT`.
- Deploy OP L1 contracts to the remote L1.
- Generate:
  - `$DEPLOYMENT_CONFIG_PATH/artifact.json`
  - `$DEPLOYMENT_CONFIG_PATH/genesis.json`
  - `$DEPLOYMENT_CONFIG_PATH/rollup.json`
  - `$DEPLOYMENT_CONFIG_PATH/state-dump-latest.json`

Check generated files:

```bash
ls -l "$DEPLOYMENT_CONFIG_PATH"
jq '{SystemConfigProxy, OptimismPortalProxy, L1StandardBridgeProxy, DisputeGameFactoryProxy, L2OutputOracleProxy}' "$DEPLOYMENT_CONFIG_PATH/artifact.json"
jq '{genesis, l1_chain_id, l2_chain_id, chain_op_config}' "$DEPLOYMENT_CONFIG_PATH/rollup.json"
```

Verify deployed L1 contract code:

```bash
for key in SystemConfigProxy OptimismPortalProxy L1StandardBridgeProxy; do
  addr=$(jq -r ".$key" "$DEPLOYMENT_CONFIG_PATH/artifact.json")
  len=$(cast code "$addr" --rpc-url "$L1_RPC_URL" | wc -c | tr -d ' ')
  echo "$key $addr code_len=$len"
done
```

If `USE_FAULT_PROOFS=true`, also verify:

```bash
addr=$(jq -r '.DisputeGameFactoryProxy' "$DEPLOYMENT_CONFIG_PATH/artifact.json")
echo "DisputeGameFactoryProxy $addr code_len=$(cast code "$addr" --rpc-url "$L1_RPC_URL" | wc -c | tr -d ' ')"
```

## 5. Patch `rollup.json` Compatibility

Refresh the L1 genesis hash from the configured remote L1 RPC. This should already match when the deployment artifacts are generated from the same L1, but this check prevents starting `op-node` with a stale or mismatched L1 block hash:

```bash
L1_GENESIS_NUMBER=$(jq -r '.genesis.l1.number' "$DEPLOYMENT_CONFIG_PATH/rollup.json")
L1_GENESIS_HASH=$(cast block "$L1_GENESIS_NUMBER" --rpc-url "$L1_RPC_URL" --json | jq -r '.hash')

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

## 6. Start L2 Services

Start L2 services in remote mode:

```bash
bash scripts/chain-ops/chain-start.sh remote
```

This does not start or stop the remote L1. It only starts local L2 services using the generated config.

Check logs:

```bash
tail -f data/logs/op-geth.log
tail -f data/logs/op-node.log
```

Check L2 RPC:

```bash
cast block latest --rpc-url "$L2_RPC_URL"
cast rpc optimism_syncStatus --rpc-url "$OP_NODE_RPC_URL" | jq
```

## 7. Optional: Upgrade SystemConfig To Jovian Branch

If the initial deploy contracts ref does not already contain the target SystemConfig implementation, deploy and upgrade it:

```bash
bash scripts/jovian/deploy-systemconfig.sh
```

Use the printed implementation address:

```bash
bash scripts/jovian/upgrade-systemconfig.sh <new_system_config_implementation>
```

Then stop only L2:

```bash
bash scripts/chain-ops/chain-stop.sh
```

Do not stop the remote L1.

## 8. Configure Fork Times And Restart L2

Use remote L1 time as the source for future fork activation times:

```bash
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
```

Write the same fork times into `scripts/chain-ops/chain-start.sh` for `op-geth`:

```bash
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
```

Restart L2:

```bash
bash scripts/chain-ops/chain-start.sh remote
```

## 9. Verify Jovian Parameters

Query current L1 and L2 params:

```bash
bash scripts/jovian/query-systemconfig-params.sh
```

Set and verify operator fee:

```bash
bash scripts/jovian/set-operator-fee.sh 1 1000000
bash scripts/jovian/verify-jovian-fees.sh
```

Set and verify min base fee:

```bash
bash scripts/jovian/set-min-base-fee.sh 1000000000
bash scripts/jovian/verify-min-base-fee.sh 1000000000
```

Set EIP-1559 params and DA footprint scalar:

```bash
bash scripts/jovian/set-eip1559-params.sh 250 6
bash scripts/jovian/set-da-footprint-gas-scalar.sh 400
bash scripts/jovian/query-systemconfig-params.sh
```

L1 config transactions are not reflected on L2 immediately. Wait for `op-node` to derive the remote L1 block containing the config update transaction, then rerun the query/verify script.

## 10. Stop Services

Stop local L2 services:

```bash
bash scripts/chain-ops/chain-stop.sh
```

This does not stop the remote L1.

## Important Notes

- `chain-setup.sh remote` deploys to the configured remote L1. Double-check `.envrc` before running.
- Remote L1 accounts must be funded before setup. The scripts cannot use `anvil_setBalance`.
- Keep `$DEPLOYMENT_CONFIG_PATH` artifacts for the network. They are required by startup and Jovian scripts.
- If `CUSTOM_GAS_TOKEN_ADDRESS` is empty, setup deploys a new token on the remote L1 and writes the address back to `.envrc`.
- If reusing an existing custom gas token, make sure it has code on the remote L1 before setup.
- Do not mix artifacts from different L1 deployments. `artifact.json`, `genesis.json`, and `rollup.json` must come from the same setup run.
