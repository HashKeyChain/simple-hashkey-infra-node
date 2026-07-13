#!/usr/bin/env python3
import json, os
from web3 import Web3

L2 = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
L1 = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")
ART = os.environ.get("ARTIFACT", "config/test/artifact.json")
w2 = Web3(Web3.HTTPProvider(L2))
w1 = Web3(Web3.HTTPProvider(L1))
art = json.load(open(ART))
PORTAL = Web3.to_checksum_address(art["OptimismPortalProxy"])
MP = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")
TOPIC = "0x" + Web3.keccak(text="MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)").hex().lstrip("0x")

head = w2.eth.block_number
frm = max(0, head - int(os.environ.get("LOOKBACK", "20000")))
print(f"L2 head={head}, scanning MessagePassed in [{frm}, {head}] ...")
# 分段扫，避免单次范围过大
logs = []
step = 5000
a = frm
while a <= head:
    b = min(a + step, head)
    try:
        part = w2.eth.get_logs({"fromBlock": hex(a), "toBlock": hex(b), "address": MP, "topics": [TOPIC]})
        logs.extend(part)
    except Exception as e:
        print(f"  get_logs [{a},{b}] err: {str(e)[:80]}")
    a = b + 1

print(f"found {len(logs)} MessagePassed logs")
PORTAL_ABI = json.loads('[{"type":"function","name":"finalizedWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bool"}]},{"type":"function","name":"provenWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"},{"type":"address"}],"outputs":[{"name":"disputeGameProxy","type":"address"},{"name":"timestamp","type":"uint64"}]}]')
p = w1.eth.contract(address=PORTAL, abi=PORTAL_ABI)
for lg in logs[-15:]:
    data = bytes(lg["data"])
    nonce = int(lg["topics"][1].hex(), 16)
    sender = "0x" + lg["topics"][2].hex()[-40:]
    target = "0x" + lg["topics"][3].hex()[-40:]
    value = int.from_bytes(data[0:32], "big")
    wd_hash = data[96:128]
    fin = p.functions.finalizedWithdrawals(wd_hash).call()
    print(f"block={lg['blockNumber']} tx={lg['transactionHash'].hex()} value={value/1e18} HSK target={target} finalized={fin} wdHash=0x{wd_hash.hex()}")
