#!/usr/bin/env python3
"""
对指定 GAME_INDEX 的 game 先 resolve（若未 resolve），再用它 prove + finalize 指定提款。
outputRootProof 全部从 eth_* 组装，不依赖 op-node。

env: L1_RPC, L2_RPC, ARTIFACT, WITHDRAW_PRIVATE_KEY, WITHDRAW_TX, GAME_INDEX
"""
import json, os, sys, time
from web3 import Web3

L1_RPC = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")
L2_RPC = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
ARTIFACT = os.environ.get("ARTIFACT", "config/test/artifact.json")
PRIV = os.environ["WITHDRAW_PRIVATE_KEY"]
WITHDRAW_TX = os.environ["WITHDRAW_TX"]
GAME_INDEX = int(os.environ["GAME_INDEX"])

w1 = Web3(Web3.HTTPProvider(L1_RPC))
w2 = Web3(Web3.HTTPProvider(L2_RPC))
acct = w1.eth.account.from_key(PRIV)
art = json.load(open(ARTIFACT))
PORTAL = Web3.to_checksum_address(art["OptimismPortalProxy"])
DGF = Web3.to_checksum_address(art["DisputeGameFactoryProxy"])
MP_ADDR = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")
TOPIC = "0x" + Web3.keccak(text="MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)").hex().lstrip("0x")

PORTAL_ABI = json.loads("""[
 {"type":"function","name":"proveWithdrawalTransaction","stateMutability":"nonpayable","inputs":[
   {"name":"_tx","type":"tuple","components":[{"name":"nonce","type":"uint256"},{"name":"sender","type":"address"},{"name":"target","type":"address"},{"name":"value","type":"uint256"},{"name":"gasLimit","type":"uint256"},{"name":"data","type":"bytes"}]},
   {"name":"_disputeGameIndex","type":"uint256"},
   {"name":"_outputRootProof","type":"tuple","components":[{"name":"version","type":"bytes32"},{"name":"stateRoot","type":"bytes32"},{"name":"messagePasserStorageRoot","type":"bytes32"},{"name":"latestBlockhash","type":"bytes32"}]},
   {"name":"_withdrawalProof","type":"bytes[]"}],"outputs":[]},
 {"type":"function","name":"finalizeWithdrawalTransaction","stateMutability":"nonpayable","inputs":[
   {"name":"_tx","type":"tuple","components":[{"name":"nonce","type":"uint256"},{"name":"sender","type":"address"},{"name":"target","type":"address"},{"name":"value","type":"uint256"},{"name":"gasLimit","type":"uint256"},{"name":"data","type":"bytes"}]}],"outputs":[]},
 {"type":"function","name":"proofMaturityDelaySeconds","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
 {"type":"function","name":"finalizedWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bool"}]}
]""")
DGF_ABI = json.loads('[{"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"type":"uint256"}],"outputs":[{"name":"gameType","type":"uint32"},{"name":"timestamp","type":"uint64"},{"name":"proxy","type":"address"}]}]')
GAME_ABI = json.loads("""[
 {"type":"function","name":"l2BlockNumber","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
 {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]},
 {"type":"function","name":"resolveClaim","stateMutability":"nonpayable","inputs":[{"type":"uint256"},{"type":"uint256"}],"outputs":[]},
 {"type":"function","name":"resolve","stateMutability":"nonpayable","inputs":[],"outputs":[{"type":"uint8"}]}
]""")

portal = w1.eth.contract(address=PORTAL, abi=PORTAL_ABI)
dgf = w1.eth.contract(address=DGF, abi=DGF_ABI)


def send(fn, gas=2_000_000):
    tx = fn.build_transaction({"from": acct.address, "nonce": w1.eth.get_transaction_count(acct.address), "value": 0, "gas": gas, "maxFeePerGas": w1.to_wei(5, "gwei"), "maxPriorityFeePerGas": w1.to_wei(0.1, "gwei")})
    s = acct.sign_transaction(tx)
    h = w1.eth.send_raw_transaction(s.raw_transaction)
    return w1.eth.wait_for_transaction_receipt(h, timeout=180)


def parse_withdrawal():
    rcpt = w2.eth.get_transaction_receipt(WITHDRAW_TX)
    wd_block = rcpt["blockNumber"]
    log = next((lg for lg in rcpt["logs"] if lg["address"].lower() == MP_ADDR.lower() and lg["topics"][0].hex().lower().lstrip("0x") == TOPIC.lower().lstrip("0x")), None)
    if log is None:
        raise RuntimeError("MessagePassed log not found")
    nonce = int(log["topics"][1].hex(), 16)
    sender = Web3.to_checksum_address("0x" + log["topics"][2].hex()[-40:])
    target = Web3.to_checksum_address("0x" + log["topics"][3].hex()[-40:])
    data = bytes(log["data"])
    value = int.from_bytes(data[0:32], "big"); gas_limit = int.from_bytes(data[32:64], "big")
    data_offset = int.from_bytes(data[64:96], "big"); wd_hash = data[96:128]
    msg_len = int.from_bytes(data[data_offset:data_offset + 32], "big")
    msg_data = data[data_offset + 32:data_offset + 32 + msg_len]
    return {"nonce": nonce, "sender": sender, "target": target, "value": value, "gasLimit": gas_limit, "data": msg_data}, wd_hash, wd_block


def main():
    wtx, wd_hash, wd_block = parse_withdrawal()
    print(f"Withdrawal block={wd_block} value={wtx['value']/1e18} HSK wdHash=0x{wd_hash.hex()}")
    if portal.functions.finalizedWithdrawals(wd_hash).call():
        print("Already finalized. Nothing to do."); return

    _, _, proxy = dgf.functions.gameAtIndex(GAME_INDEX).call()
    game = w1.eth.contract(address=proxy, abi=GAME_ABI)
    l2b = game.functions.l2BlockNumber().call(); st = game.functions.status().call()
    print(f"game[{GAME_INDEX}] proxy={proxy} l2Block={l2b} status={st}")
    if l2b < wd_block:
        sys.exit(f"game l2Block {l2b} < withdrawal block {wd_block}; pick a higher game")

    if st == 0:
        print("Resolving game...")
        try:
            r = send(game.functions.resolveClaim(0, 0)); print(f"  resolveClaim status={r['status']}")
        except Exception as e:
            print(f"  resolveClaim err (may be ok): {str(e)[:120]}")
        try:
            r = send(game.functions.resolve()); print(f"  resolve status={r['status']}")
        except Exception as e:
            print(f"  resolve err: {str(e)[:120]}")
        for _ in range(12):
            st = game.functions.status().call()
            if st == 2: break
            time.sleep(5)
        print(f"  game status now={st}")
    if st != 2:
        sys.exit(f"game status={st}, expected 2 (DEFENDER_WINS).")

    blk = w2.eth.get_block(l2b)
    state_root = bytes(blk["stateRoot"]); block_hash = bytes(blk["hash"])
    slot = Web3.keccak(wd_hash + (0).to_bytes(32, "big"))
    proof = w2.eth.get_proof(MP_ADDR, [int.from_bytes(slot, "big")], l2b)
    mp_root = bytes(proof["storageHash"])
    wproof = [bytes(p) for p in proof["storageProof"][0]["proof"]]
    orp = (b"\x00" * 32, state_root, mp_root, block_hash)
    tx_tuple = (wtx["nonce"], wtx["sender"], wtx["target"], wtx["value"], wtx["gasLimit"], wtx["data"])

    print("proveWithdrawalTransaction...")
    r = send(portal.functions.proveWithdrawalTransaction(tx_tuple, GAME_INDEX, orp, wproof))
    print(f"  prove status={r['status']} tx={r['transactionHash'].hex()}")
    if r["status"] != 1: sys.exit("prove failed")

    delay = portal.functions.proofMaturityDelaySeconds().call()
    print(f"wait proofMaturity={delay}s ...")
    time.sleep(delay + 8)

    print("finalizeWithdrawalTransaction...")
    for i in range(30):
        try:
            r = send(portal.functions.finalizeWithdrawalTransaction(tx_tuple))
            if r["status"] == 1:
                print(f"  finalize status=1 tx={r['transactionHash'].hex()}"); break
            print(f"  finalize reverted attempt {i}, retry 10s")
        except Exception as e:
            print(f"  finalize attempt {i} err: {str(e)[:140]}; retry 10s")
        time.sleep(10)
    else:
        sys.exit("finalize did not succeed")
    print("finalizedWithdrawals =", portal.functions.finalizedWithdrawals(wd_hash).call())
    print("DONE")


if __name__ == "__main__":
    main()
