#!/usr/bin/env python3
"""
一站式 L2->L1 提款（Fault-Proofs / PermissionedDisputeGame），不依赖 op-node。

流程:
  1) 在 L2 调 L2ToL1MessagePasser.initiateWithdrawal{value}(target, gasLimit, data)
  2) 轮询 DGF, 等到一个 l2BlockNumber >= 提款区块 且 status==DEFENDER_WINS(2) 的 game
  3) proveWithdrawalTransaction (outputRootProof 全部从 eth_* 组装)
  4) 等 proofMaturityDelaySeconds 后 finalizeWithdrawalTransaction
  5) 校验 finalizedWithdrawals + L1 HSK 到账

环境变量:
  L1_RPC, L2_RPC, ARTIFACT, WITHDRAW_PRIVATE_KEY,
  AMOUNT_WEI (默认 0.0666 HSK), TARGET (默认 = 私钥地址),
  CGT_TOKEN (L1 上的 HSK ERC20, 用于到账校验)
依赖: web3
"""
import json
import os
import sys
import time

from web3 import Web3

L1_RPC = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")
L2_RPC = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
ARTIFACT = os.environ.get("ARTIFACT", "config/test/artifact.json")
PRIV = os.environ["WITHDRAW_PRIVATE_KEY"]
AMOUNT_WEI = int(os.environ.get("AMOUNT_WEI", str(int(0.0666 * 10**18))))
CGT_TOKEN = os.environ.get("CGT_TOKEN", "0x31BdaC8E4B897E470B70eBe286F94245baa793C2")

MP_ADDR = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")
MESSAGE_PASSED_TOPIC = Web3.keccak(
    text="MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)"
).hex()

w3_l1 = Web3(Web3.HTTPProvider(L1_RPC))
w3_l2 = Web3(Web3.HTTPProvider(L2_RPC))
acct = w3_l1.eth.account.from_key(PRIV)
acct_l2 = w3_l2.eth.account.from_key(PRIV)
TARGET = Web3.to_checksum_address(os.environ.get("TARGET", acct.address))

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
  {"type":"function","name":"proofMaturityDelaySeconds","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
  {"type":"function","name":"finalizedWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bool"}]}
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
MP_ABI = json.loads(
    """[
  {"type":"function","name":"initiateWithdrawal","stateMutability":"payable",
   "inputs":[{"name":"_target","type":"address"},{"name":"_gasLimit","type":"uint256"},{"name":"_data","type":"bytes"}],
   "outputs":[]}
]"""
)
ERC20_ABI = json.loads('[{"type":"function","name":"balanceOf","stateMutability":"view","inputs":[{"type":"address"}],"outputs":[{"type":"uint256"}]}]')

portal = w3_l1.eth.contract(address=PORTAL, abi=PORTAL_ABI)
dgf = w3_l1.eth.contract(address=DGF, abi=DGF_ABI)
mp = w3_l2.eth.contract(address=MP_ADDR, abi=MP_ABI)


def send_l1(tx_func, value=0, gas=2_000_000):
    tx = tx_func.build_transaction({
        "from": acct.address,
        "nonce": w3_l1.eth.get_transaction_count(acct.address),
        "value": value,
        "gas": gas,
        "maxFeePerGas": w3_l1.to_wei(5, "gwei"),
        "maxPriorityFeePerGas": w3_l1.to_wei(0.1, "gwei"),
    })
    signed = acct.sign_transaction(tx)
    h = w3_l1.eth.send_raw_transaction(signed.raw_transaction)
    return w3_l1.eth.wait_for_transaction_receipt(h, timeout=180)


def initiate():
    tx = mp.functions.initiateWithdrawal(TARGET, 200000, b"").build_transaction({
        "from": acct_l2.address,
        "nonce": w3_l2.eth.get_transaction_count(acct_l2.address),
        "value": AMOUNT_WEI,
        "gas": 300000,
        "maxFeePerGas": w3_l2.to_wei(2, "gwei"),
        "maxPriorityFeePerGas": w3_l2.to_wei(0.1, "gwei"),
    })
    signed = acct_l2.sign_transaction(tx)
    h = w3_l2.eth.send_raw_transaction(signed.raw_transaction)
    rcpt = w3_l2.eth.wait_for_transaction_receipt(h, timeout=120)
    if rcpt["status"] != 1:
        sys.exit(f"initiateWithdrawal reverted: {rcpt['transactionHash'].hex()}")
    return rcpt


def parse_withdrawal(rcpt):
    wd_block = rcpt["blockNumber"]
    log = None
    for lg in rcpt["logs"]:
        if lg["address"].lower() == MP_ADDR.lower() and lg["topics"][0].hex().lower().lstrip("0x") == MESSAGE_PASSED_TOPIC.lower().lstrip("0x"):
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
    msg_len = int.from_bytes(data[data_offset:data_offset + 32], "big")
    msg_data = data[data_offset + 32:data_offset + 32 + msg_len]
    return {"nonce": nonce, "sender": sender, "target": target, "value": value, "gasLimit": gas_limit, "data": msg_data}, wd_hash, wd_block


def find_resolved_game(wd_block):
    count = dgf.functions.gameCount().call()
    chosen = None
    for i in range(count - 1, max(-1, count - 400), -1):
        _, _, proxy = dgf.functions.gameAtIndex(i).call()
        g = w3_l1.eth.contract(address=proxy, abi=GAME_ABI)
        l2b = g.functions.l2BlockNumber().call()
        st = g.functions.status().call()
        if l2b >= wd_block and st == 2:
            chosen = (i, proxy, l2b)
        elif l2b < wd_block:
            break
    return chosen, count


def main():
    print(f"Portal={PORTAL} DGF={DGF}")
    print(f"Initiating withdrawal: {AMOUNT_WEI} wei ({AMOUNT_WEI/1e18} HSK) -> {TARGET}")
    rcpt = initiate()
    wtx, wd_hash, wd_block = parse_withdrawal(rcpt)
    print(f"  L2 tx={rcpt['transactionHash'].hex()} block={wd_block}")
    print(f"  wdHash=0x{wd_hash.hex()}  value={wtx['value']/1e18} HSK")

    print("Waiting for a resolved game (status=2) covering the withdrawal block...")
    chosen = None
    for _ in range(180):  # up to ~30min
        chosen, count = find_resolved_game(wd_block)
        if chosen:
            break
        time.sleep(10)
        print(f"  ... waiting (gameCount={count}, need l2Block>={wd_block} & resolved)")
    if not chosen:
        sys.exit("No resolved game covering the withdrawal block within timeout.")
    idx, proxy, l2b = chosen
    print(f"Using game[{idx}] proxy={proxy} l2Block={l2b}")

    blk = w3_l2.eth.get_block(l2b)
    state_root = bytes(blk["stateRoot"])
    block_hash = bytes(blk["hash"])
    slot = Web3.keccak(wd_hash + (0).to_bytes(32, "big"))
    proof = w3_l2.eth.get_proof(MP_ADDR, [int.from_bytes(slot, "big")], l2b)
    mp_storage_root = bytes(proof["storageHash"])
    withdrawal_proof = [bytes(p) for p in proof["storageProof"][0]["proof"]]
    output_root_proof = (b"\x00" * 32, state_root, mp_storage_root, block_hash)
    print(f"  stateRoot=0x{state_root.hex()} mpRoot=0x{mp_storage_root.hex()} blockHash=0x{block_hash.hex()} proofNodes={len(withdrawal_proof)}")

    tx_tuple = (wtx["nonce"], wtx["sender"], wtx["target"], wtx["value"], wtx["gasLimit"], wtx["data"])

    print("Submitting proveWithdrawalTransaction...")
    r = send_l1(portal.functions.proveWithdrawalTransaction(tx_tuple, idx, output_root_proof, withdrawal_proof))
    print(f"  prove status={r['status']} tx={r['transactionHash'].hex()}")
    if r["status"] != 1:
        sys.exit("prove failed")

    delay = portal.functions.proofMaturityDelaySeconds().call()
    print(f"Waiting proofMaturity={delay}s (+8s buffer)...")
    time.sleep(delay + 8)

    bal_before = w3_l1.eth.contract(address=Web3.to_checksum_address(CGT_TOKEN), abi=ERC20_ABI).functions.balanceOf(TARGET).call()
    print("Submitting finalizeWithdrawalTransaction...")
    for attempt in range(30):
        try:
            r = send_l1(portal.functions.finalizeWithdrawalTransaction(tx_tuple))
            if r["status"] == 1:
                print(f"  finalize status=1 tx={r['transactionHash'].hex()}")
                break
            print(f"  finalize reverted (attempt {attempt}), retry 10s")
        except Exception as e:
            print(f"  finalize attempt {attempt} err: {str(e)[:140]}; retry 10s")
        time.sleep(10)
    else:
        sys.exit("finalize did not succeed in time")

    fin = portal.functions.finalizedWithdrawals(wd_hash).call()
    bal_after = w3_l1.eth.contract(address=Web3.to_checksum_address(CGT_TOKEN), abi=ERC20_ABI).functions.balanceOf(TARGET).call()
    print(f"  finalizedWithdrawals={fin}")
    print(f"  L1 HSK balance: {bal_before/1e18} -> {bal_after/1e18} (delta={(bal_after-bal_before)/1e18})")
    print("WITHDRAWAL COMPLETE" if (fin and bal_after > bal_before) else "Finalized but check balance")


if __name__ == "__main__":
    main()
