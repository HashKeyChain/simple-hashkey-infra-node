#!/usr/bin/env python3
import json, os
from web3 import Web3

L1 = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")
L2 = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
ART = os.environ.get("ARTIFACT", "config/test/artifact.json")
DEPLOY = "0xA5EA057879A5a97E67e3392c595bb735292aE307"

w1 = Web3(Web3.HTTPProvider(L1))
w2 = Web3(Web3.HTTPProvider(L2))
art = json.load(open(ART))
DGF = Web3.to_checksum_address(art["DisputeGameFactoryProxy"])
PORTAL = Web3.to_checksum_address(art["OptimismPortalProxy"])
MP = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")

print("L2 head:", w2.eth.block_number)
print("DGF:", DGF, " PORTAL:", PORTAL)

DGF_ABI = json.loads('[{"type":"function","name":"gameCount","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},{"type":"function","name":"gameAtIndex","stateMutability":"view","inputs":[{"type":"uint256"}],"outputs":[{"name":"gameType","type":"uint32"},{"name":"timestamp","type":"uint64"},{"name":"proxy","type":"address"}]}]')
GAME_ABI = json.loads('[{"type":"function","name":"l2BlockNumber","stateMutability":"view","inputs":[],"outputs":[{"type":"uint256"}]},{"type":"function","name":"status","stateMutability":"view","inputs":[],"outputs":[{"type":"uint8"}]},{"type":"function","name":"createdAt","stateMutability":"view","inputs":[],"outputs":[{"type":"uint64"}]},{"type":"function","name":"resolvedAt","stateMutability":"view","inputs":[],"outputs":[{"type":"uint64"}]},{"type":"function","name":"maxClockDuration","stateMutability":"view","inputs":[],"outputs":[{"type":"uint64"}]}]')
d = w1.eth.contract(address=DGF, abi=DGF_ABI)
cnt = d.functions.gameCount().call()
now = w1.eth.get_block("latest")["timestamp"]
print(f"gameCount={cnt}  L1 now={now}")
print("idx | l2Block | status | createdAt | age(s) | maxClock | resolvedAt | proxy")
# 打印最后 10 个 game
for i in range(max(0, cnt-10), cnt):
    _, _, proxy = d.functions.gameAtIndex(i).call()
    g = w1.eth.contract(address=proxy, abi=GAME_ABI)
    l2b = g.functions.l2BlockNumber().call()
    st = g.functions.status().call()
    try: created = g.functions.createdAt().call()
    except Exception: created = 0
    try: mcd = g.functions.maxClockDuration().call()
    except Exception: mcd = 0
    try: resolved = g.functions.resolvedAt().call()
    except Exception: resolved = 0
    age = now - created if created else 0
    ready = " <READY to resolve" if (st==0 and mcd and age>=mcd) else ""
    print(f"{i} | {l2b} | {st} | {created} | {age} | {mcd} | {resolved} | {proxy}{ready}")
