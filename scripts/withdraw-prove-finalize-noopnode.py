#!/usr/bin/env python3
"""
Fault-Proofs (PermissionedDisputeGame) 提款 prove + finalize，不依赖 op-node。

outputRootProof 的三个 root 全部从普通 eth_* 取：
  - stateRoot, latestBlockhash <- eth_getBlockByNumber(l2Block)
  - messagePasserStorageRoot   <- eth_getProof(L2ToL1MessagePasser, [], l2Block).storageHash
withdrawalProof <- eth_getProof 的 storageProof。

需要事先有一个已 resolve 的、l2BlockNumber >= 提款区块 的 game（脚本只挑选它，不创建/不强制 resolve）。

用法:
  L1_RPC=... L2_RPC=... ARTIFACT=config/test/artifact.json \
  WITHDRAW_PRIVATE_KEY=0x... WITHDRAW_TX=0x... \
  GAME_INDEX=2 python3 scripts/withdraw-prove-finalize-noopnode.py

依赖: web3 (pip install web3)
"""
import json
import os
import sys
import time

from web3 import Web3

L1_RPC = os.environ.get("L1_RPC", "http://localhost:8545")
L2_RPC = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
ARTIFACT = os.environ.get("ARTIFACT", "config/test/artifact.json")
PRIV = os.environ["WITHDRAW_PRIVATE_KEY"]
WITHDRAW_TX = os.environ["WITHDRAW_TX"]
GAME_INDEX = os.environ.get("GAME_INDEX")  # 可选，直接指定 DGF game index

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
  {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]}
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
            "maxFeePerGas": w3_l1.to_wei(5, "gwei"),
            "maxPriorityFeePerGas": w3_l1.to_wei(0.1, "gwei"),
        }
    )
    signed = acct.sign_transaction(tx)
    h = w3_l1.eth.send_raw_transaction(signed.raw_transaction)
    rcpt = w3_l1.eth.wait_for_transaction_receipt(h, timeout=180)
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


def pick_game(wd_block):
    if GAME_INDEX is not None:
        idx = int(GAME_INDEX)
        _, _, proxy = dgf.functions.gameAtIndex(idx).call()
        game = w3_l1.eth.contract(address=proxy, abi=GAME_ABI)
        return idx, proxy, game.functions.l2BlockNumber().call(), game.functions.status().call()
    count = dgf.functions.gameCount().call()
    chosen = None
    for i in range(count - 1, max(-1, count - 400), -1):
        _, _, proxy = dgf.functions.gameAtIndex(i).call()
        game = w3_l1.eth.contract(address=proxy, abi=GAME_ABI)
        l2b = game.functions.l2BlockNumber().call()
        st = game.functions.status().call()
        if l2b >= wd_block and st == 2:
            chosen = (i, proxy, l2b, st)
        elif l2b < wd_block:
            break
    return chosen


def main():
    wtx, wd_hash, wd_block = parse_withdrawal()
    print(f"Withdrawal L2 block={wd_block}, hash=0x{wd_hash.hex()}")
    print(f"  tx struct: {wtx}")

    picked = pick_game(wd_block)
    if not picked:
        sys.exit("No resolved (DEFENDER_WINS) game covering the withdrawal block. Resolve one first.")
    idx, proxy, l2b, st = picked
    print(f"Using game[{idx}] proxy={proxy} l2Block={l2b} status={st}")
    if st != 2:
        sys.exit(f"game[{idx}] status={st}, expected 2 (DEFENDER_WINS). Resolve it first.")

    # outputRootProof: 全部从 eth_* 取，不用 op-node
    blk = w3_l2.eth.get_block(l2b)
    state_root = blk["stateRoot"]
    block_hash = blk["hash"]
    # messagePasserStorageRoot + withdrawalProof 来自同一个 eth_getProof
    slot = Web3.keccak(wd_hash + (0).to_bytes(32, "big"))
    proof = w3_l2.eth.get_proof(MP_ADDR, [int.from_bytes(slot, "big")], l2b)
    mp_storage_root = proof["storageHash"]
    withdrawal_proof = [bytes(p) for p in proof["storageProof"][0]["proof"]]

    def to_b(x):
        return bytes(x) if isinstance(x, (bytes, bytearray)) else Web3.to_bytes(hexstr=x)

    output_root_proof = (
        b"\x00" * 32,
        to_b(state_root),
        to_b(mp_storage_root),
        to_b(block_hash),
    )
    print(f"  stateRoot=0x{to_b(state_root).hex()}")
    print(f"  mpStorageRoot=0x{to_b(mp_storage_root).hex()}")
    print(f"  blockHash=0x{to_b(block_hash).hex()}")
    print(f"  storage proof nodes: {len(withdrawal_proof)}")

    tx_tuple = (
        wtx["nonce"],
        wtx["sender"],
        wtx["target"],
        wtx["value"],
        wtx["gasLimit"],
        wtx["data"],
    )

    print("Submitting proveWithdrawalTransaction...")
    rcpt = send(portal.functions.proveWithdrawalTransaction(tx_tuple, idx, output_root_proof, withdrawal_proof))
    print(f"  prove status={rcpt['status']} gasUsed={rcpt['gasUsed']} tx={rcpt['transactionHash'].hex()}")
    if rcpt["status"] != 1:
        sys.exit("prove failed")

    delay = portal.functions.proofMaturityDelaySeconds().call()
    print(f"Waiting proofMaturity={delay}s (+buffer)...")
    time.sleep(delay + 8)

    print("Submitting finalizeWithdrawalTransaction...")
    for attempt in range(30):
        try:
            rcpt = send(portal.functions.finalizeWithdrawalTransaction(tx_tuple))
            if rcpt["status"] == 1:
                print(f"  finalize status=1 gasUsed={rcpt['gasUsed']} tx={rcpt['transactionHash'].hex()}")
                break
            print(f"  finalize reverted (attempt {attempt}), retry in 10s")
        except Exception as e:
            print(f"  finalize attempt {attempt} err: {str(e)[:140]}; retry in 10s")
        time.sleep(10)
    else:
        sys.exit("finalize did not succeed in time")
    print("WITHDRAWAL COMPLETE")


if __name__ == "__main__":
    main()
