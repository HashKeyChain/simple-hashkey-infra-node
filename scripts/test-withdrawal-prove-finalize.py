#!/usr/bin/env python3
"""
端到端验证 Fault-Proofs (PermissionedDisputeGame) 提款的 prove + finalize 两步。

前置:
  - 已 initiateWithdrawal，拿到 L2 tx hash（环境变量 WITHDRAW_TX）
  - op-node RPC 可用，proposer 已提交覆盖提款区块的 game

用法:
  WITHDRAW_TX=0x... python3 scripts/test-withdrawal-prove-finalize.py

依赖: web3 (pip install web3)
"""
import json
import os
import sys
import time

from web3 import Web3

L1_RPC = os.environ.get("L1_RPC", "http://localhost:8545")
L2_RPC = os.environ.get("L2_RPC", "http://localhost:8645")
OP_NODE_RPC = os.environ.get("OP_NODE_RPC", "http://localhost:9545")
ARTIFACT = os.environ.get("ARTIFACT", "config/local/artifact.json")
PRIV = os.environ["WITHDRAW_PRIVATE_KEY"]
WITHDRAW_TX = os.environ["WITHDRAW_TX"]

MP_ADDR = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")
MESSAGE_PASSED_TOPIC = Web3.keccak(
    text="MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)"
).hex()

w3_l1 = Web3(Web3.HTTPProvider(L1_RPC))
w3_l2 = Web3(Web3.HTTPProvider(L2_RPC))
acct = w3_l1.eth.account.from_key(PRIV)

with open(ARTIFACT) as f:
    art = json.load(f)
PORTAL = Web3.to_checksum_address(art["OptimismPortalProxy"])
DGF = Web3.to_checksum_address(art["DisputeGameFactoryProxy"])


def op_node_call(method, params):
    import urllib.request

    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(
        OP_NODE_RPC, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        out = json.loads(resp.read())
    if "error" in out:
        raise RuntimeError(f"{method} error: {out['error']}")
    return out["result"]


# ---- ABIs (minimal) ----
PORTAL_ABI = json.loads(
    """[
  {"type":"function","name":"proveWithdrawalTransaction","stateMutability":"nonpayable",
   "inputs":[
     {"name":"_tx","type":"tuple","components":[
        {"name":"nonce","type":"uint256"},{"name":"sender","type":"address"},
        {"name":"target","type":"address"},{"name":"value","type":"uint256"},
        {"name":"gasLimit","type":"uint256"},{"name":"data","type":"bytes"}]},
     {"name":"_disputeGameIndex","type":"uint256"},
     {"name":"_outputRootProof","type":"tuple","components":[
        {"name":"version","type":"bytes32"},{"name":"stateRoot","type":"bytes32"},
        {"name":"messagePasserStorageRoot","type":"bytes32"},{"name":"latestBlockhash","type":"bytes32"}]},
     {"name":"_withdrawalProof","type":"bytes[]"}
   ],"outputs":[]},
  {"type":"function","name":"finalizeWithdrawalTransaction","stateMutability":"nonpayable",
   "inputs":[
     {"name":"_tx","type":"tuple","components":[
        {"name":"nonce","type":"uint256"},{"name":"sender","type":"address"},
        {"name":"target","type":"address"},{"name":"value","type":"uint256"},
        {"name":"gasLimit","type":"uint256"},{"name":"data","type":"bytes"}]}
   ],"outputs":[]},
  {"type":"function","name":"proofMaturityDelaySeconds","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]}
]"""
)
DGF_ABI = json.loads(
    """[
  {"type":"function","name":"gameCount","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"type":"uint256"}],
   "outputs":[{"name":"gameType","type":"uint32"},{"name":"timestamp","type":"uint64"},{"name":"proxy","type":"address"}]}
]"""
)
GAME_ABI = json.loads(
    """[
  {"type":"function","name":"l2BlockNumber","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]},
  {"type":"function","name":"resolvedAt","stateMutability":"view","inputs":[],"outputs":[{"type":"uint64"}]},
  {"type":"function","name":"resolveClaim","stateMutability":"nonpayable","inputs":[{"type":"uint256"},{"type":"uint256"}],"outputs":[]},
  {"type":"function","name":"resolve","stateMutability":"nonpayable","inputs":[],"outputs":[{"type":"uint8"}]}
]"""
)

portal = w3_l1.eth.contract(address=PORTAL, abi=PORTAL_ABI)
dgf = w3_l1.eth.contract(address=DGF, abi=DGF_ABI)


def send(tx_func, value=0, gas=2_000_000):
    tx = tx_func.build_transaction(
        {
            "from": acct.address,
            "nonce": w3_l1.eth.get_transaction_count(acct.address),
            "value": value,
            "gas": gas,
            "maxFeePerGas": w3_l1.to_wei(3, "gwei"),
            "maxPriorityFeePerGas": w3_l1.to_wei(0.1, "gwei"),
        }
    )
    signed = acct.sign_transaction(tx)
    h = w3_l1.eth.send_raw_transaction(signed.raw_transaction)
    rcpt = w3_l1.eth.wait_for_transaction_receipt(h, timeout=120)
    return rcpt


def parse_withdrawal():
    rcpt = w3_l2.eth.get_transaction_receipt(WITHDRAW_TX)
    wd_block = rcpt["blockNumber"]
    log = None
    for lg in rcpt["logs"]:
        if lg["address"].lower() == MP_ADDR.lower() and lg["topics"][0].hex().lower().lstrip(
            "0x"
        ) == MESSAGE_PASSED_TOPIC.lower().lstrip("0x"):
            log = lg
            break
    if log is None:
        raise RuntimeError("MessagePassed log not found")
    nonce = int(log["topics"][1].hex(), 16)
    sender = Web3.to_checksum_address("0x" + log["topics"][2].hex()[-40:])
    target = Web3.to_checksum_address("0x" + log["topics"][3].hex()[-40:])
    data = bytes(log["data"])
    # MessagePassed non-indexed ABI head: value, gasLimit, offset(data), withdrawalHash
    # tail: data length + data bytes.
    value = int.from_bytes(data[0:32], "big")
    gas_limit = int.from_bytes(data[32:64], "big")
    data_offset = int.from_bytes(data[64:96], "big")
    wd_hash = data[96:128]
    msg_len = int.from_bytes(data[data_offset : data_offset + 32], "big")
    msg_data = data[data_offset + 32 : data_offset + 32 + msg_len]
    return {
        "nonce": nonce,
        "sender": sender,
        "target": target,
        "value": value,
        "gasLimit": gas_limit,
        "data": msg_data,
    }, wd_hash, wd_block


def find_game(wd_block):
    count = dgf.functions.gameCount().call()
    # find oldest game with l2BlockNumber >= wd_block (scan from newest backwards, keep last match)
    chosen = None
    for i in range(count - 1, max(-1, count - 400), -1):
        gt, ts, proxy = dgf.functions.gameAtIndex(i).call()
        game = w3_l1.eth.contract(address=proxy, abi=GAME_ABI)
        l2b = game.functions.l2BlockNumber().call()
        if l2b >= wd_block:
            chosen = (i, proxy, l2b, game)
        else:
            break
    return chosen, count


def main():
    wtx, wd_hash, wd_block = parse_withdrawal()
    print(f"Withdrawal L2 block={wd_block}, hash=0x{wd_hash.hex()}")
    print(f"  tx struct: {wtx}")

    # 1) wait for a game covering wd_block
    print("Waiting for a game with l2BlockNumber >= withdrawal block...")
    chosen = None
    for _ in range(120):
        chosen, count = find_game(wd_block)
        if chosen:
            break
        time.sleep(10)
        print("  ... still waiting (gameCount=%d)" % count)
    if not chosen:
        sys.exit("No game covering the withdrawal block appeared in time.")
    idx, proxy, l2b, game = chosen
    print(f"Using game[{idx}] proxy={proxy} l2Block={l2b}")

    # 2) get output root proof at the game's l2 block
    out = op_node_call("optimism_outputAtBlock", [hex(l2b)])
    state_root = out["stateRoot"]
    block_hash = out["blockRef"]["hash"]
    # messagePasserStorageRoot: from withdrawalStorageRoot field
    mp_storage_root = out["withdrawalStorageRoot"]
    version = "0x" + "00" * 32
    output_root_proof = (
        Web3.to_bytes(hexstr=version),
        Web3.to_bytes(hexstr=state_root),
        Web3.to_bytes(hexstr=mp_storage_root),
        Web3.to_bytes(hexstr=block_hash),
    )
    print(f"  outputRootProof: stateRoot={state_root} mpRoot={mp_storage_root} blockHash={block_hash}")

    # 3) storage proof for the withdrawal hash slot in MessagePasser
    # slot = keccak256(abi.encode(wd_hash, uint256(0)))  -> sentMessages mapping at slot 0
    slot = Web3.keccak(wd_hash + (0).to_bytes(32, "big"))
    proof = op_node_call(
        "eth_getProof", [MP_ADDR, ["0x" + slot.hex()], hex(l2b)]
    ) if False else w3_l2.eth.get_proof(MP_ADDR, [int.from_bytes(slot, "big")], l2b)
    withdrawal_proof = [bytes(p) for p in proof["storageProof"][0]["proof"]]
    print(f"  storage proof nodes: {len(withdrawal_proof)}")

    tx_tuple = (
        wtx["nonce"],
        wtx["sender"],
        wtx["target"],
        wtx["value"],
        wtx["gasLimit"],
        wtx["data"],
    )

    # 4) prove
    print("Submitting proveWithdrawalTransaction...")
    rcpt = send(
        portal.functions.proveWithdrawalTransaction(
            tx_tuple, idx, output_root_proof, withdrawal_proof
        )
    )
    print(f"  prove status={rcpt['status']} gasUsed={rcpt['gasUsed']}")
    if rcpt["status"] != 1:
        sys.exit("prove failed")

    # 5) ensure the game is resolved (DEFENDER_WINS=2)
    st = game.functions.status().call()
    if st == 0:
        print("Game still IN_PROGRESS; resolving...")
        try:
            send(game.functions.resolveClaim(0, 0))
        except Exception as e:
            print("  resolveClaim:", e)
        send(game.functions.resolve())
        st = game.functions.status().call()
    print(f"  game status={st} (2=DEFENDER_WINS)")

    # 6) wait proofMaturity + game finality, then finalize
    delay = portal.functions.proofMaturityDelaySeconds().call()
    print(f"Waiting proofMaturity={delay}s (+ buffer)...")
    time.sleep(delay + 6)

    bal_before = w3_l1.eth.get_balance(wtx["target"])
    print("Submitting finalizeWithdrawalTransaction...")
    for attempt in range(20):
        try:
            rcpt = send(portal.functions.finalizeWithdrawalTransaction(tx_tuple))
            if rcpt["status"] == 1:
                break
            print(f"  finalize reverted (attempt {attempt}), retrying in 10s...")
        except Exception as e:
            print(f"  finalize attempt {attempt} err: {str(e)[:120]}; retry in 10s")
        time.sleep(10)
    else:
        sys.exit("finalize did not succeed in time")
    bal_after = w3_l1.eth.get_balance(wtx["target"])
    print(f"  finalize status={rcpt['status']} gasUsed={rcpt['gasUsed']}")
    print(f"  L1 target balance: {bal_before} -> {bal_after} (delta={bal_after - bal_before})")
    print("WITHDRAWAL COMPLETE ✅" if bal_after > bal_before else "WITHDRAWAL finalized but balance unchanged?")


if __name__ == "__main__":
    main()
