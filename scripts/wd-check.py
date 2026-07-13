#!/usr/bin/env python3
import json, os
from web3 import Web3

L1 = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")
L2 = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
ART = os.environ.get("ARTIFACT", "config/test/artifact.json")
WTX = os.environ.get("WITHDRAW_TX", "0x1b0bb4bbac7a69fc8de7e1d1a0aa746d097c6a94eab5ce530bd8237145a6b5e6")
WD_HASH = "0x78bb638fd3d3bd6c10011761bd9eecbc45cdc906f51254fec04702fda83e2f67"

w1 = Web3(Web3.HTTPProvider(L1))
w2 = Web3(Web3.HTTPProvider(L2))
art = json.load(open(ART))
PORTAL = Web3.to_checksum_address(art["OptimismPortalProxy"])
DGF = Web3.to_checksum_address(art["DisputeGameFactoryProxy"])
print("L1 connected:", w1.is_connected(), "chainId:", w1.eth.chain_id)
print("L2 connected:", w2.is_connected(), "chainId:", w2.eth.chain_id, "head:", w2.eth.block_number)
print("PORTAL:", PORTAL, "DGF:", DGF)

# L2 tx receipt
try:
    r = w2.eth.get_transaction_receipt(WTX)
    print("WITHDRAW_TX block:", r["blockNumber"], "status:", r["status"])
    WD_BLOCK = r["blockNumber"]
except Exception as e:
    print("WITHDRAW_TX receipt err:", e)
    WD_BLOCK = 3789

PORTAL_ABI = json.loads('''[
 {"type":"function","name":"finalizedWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"}],"outputs":[{"type":"bool"}]},
 {"type":"function","name":"provenWithdrawals","stateMutability":"view","inputs":[{"type":"bytes32"},{"type":"address"}],"outputs":[{"name":"disputeGameProxy","type":"address"},{"name":"timestamp","type":"uint64"}]},
 {"type":"function","name":"proofMaturityDelaySeconds","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]}
]''')
p = w1.eth.contract(address=PORTAL, abi=PORTAL_ABI)
fin = p.functions.finalizedWithdrawals(Web3.to_bytes(hexstr=WD_HASH)).call()
print("finalizedWithdrawals:", fin)
try:
    delay = p.functions.proofMaturityDelaySeconds().call()
    print("proofMaturityDelaySeconds:", delay)
except Exception as e:
    print("proofMaturity err:", e)

DGF_ABI = json.loads('''[
 {"type":"function","name":"gameCount","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
 {"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"type":"uint256"}],"outputs":[{"name":"gameType","type":"uint32"},{"name":"timestamp","type":"uint64"},{"name":"proxy","type":"address"}]}
]''')
GAME_ABI = json.loads('''[
 {"type":"function","name":"l2BlockNumber","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},
 {"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]}
]''')
d = w1.eth.contract(address=DGF, abi=DGF_ABI)
cnt = d.functions.gameCount().call()
print("gameCount:", cnt)
print("idx | l2Block | status | proxy")
for i in range(cnt):
    gt, ts, proxy = d.functions.gameAtIndex(i).call()
    g = w1.eth.contract(address=proxy, abi=GAME_ABI)
    l2b = g.functions.l2BlockNumber().call()
    st = g.functions.status().call()
    flag = " <== covers 3789, resolved" if (l2b >= WD_BLOCK and st == 2) else (" <== covers 3789" if l2b >= WD_BLOCK else "")
    print(f"{i} | {l2b} | {st} | {proxy}{flag}")
