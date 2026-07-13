#!/usr/bin/env python3
"""
执行前模拟：以 SystemOwnerSafe 身份，用 eth_call 分别模拟升级的 3 笔交易。
命中 revert 会尽量解码原因。纯只读，不广播。

用法:
  L1_RPC=http://qa-proxy.hashkeychain.net:8545 \
  python3 scripts/upgrade-l2oo-to-fp/simulate.py
"""
import json
import os
import urllib.request

from eth_abi import encode
from eth_utils import keccak, to_checksum_address

L1_RPC = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")

SAFE         = to_checksum_address("0xe9a1a112965B4e00577d6028c5116B388581a81e")
PROXY_ADMIN  = to_checksum_address("0x659c166D3f4DD2e4F6E218B0eD0C6321Dc68619f")
DGF_PROXY    = to_checksum_address("0x799E013e33d05E48c8b774bFD83aaA82E92049b2")
PORTAL_PROXY = to_checksum_address("0x8dc71d4d25c415C0a9F11EF57Bd64ca208531645")
ASR_PROXY    = to_checksum_address("0x04281Ef5FE221834dc3b6d0b0C87Ef360909C0C3")
SYSCFG       = to_checksum_address("0x62163c0C9479b4b202eFa52bF8bd9cBBEdd9042F")
SUPERCFG     = to_checksum_address("0x8C40a3847301926eC17de95602216758eEe25a71")
NEW_PORTAL   = to_checksum_address("0xa1Cf656889Eb0A9Ee9C8500b6Ea1F6D385B29F01")
NEW_ASR      = to_checksum_address("0xda8E4105Dd3e094FA5514410F1CfB96fe9426a1D")
NEW_PDG      = to_checksum_address("0xA6d7B116527dD65b607327ABAE2977aA8Cd3E277")

# anchor：从旧 L2OO 最新 output 无缝迁移（与 gen-safe-batch.py 保持一致）
ANCHOR_ROOT = bytes.fromhex("ee215931c2235a18a46c48a3968259b624ec331d62e9f4f5b05b8b9d9ca44e7a")
ANCHOR_BLK = 29892600
RESPECTED = 1


def sel(sig):
    return keccak(text=sig)[:4]


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(L1_RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def decode_revert(data):
    if not data or data == "0x":
        return "(no revert data)"
    b = bytes.fromhex(data[2:])
    if b[:4] == sel("Error(string)"):
        try:
            return "Error: " + b[4:].decode("utf-8", "ignore").split("\x00")[0].strip()
        except Exception:
            return "Error(string) <undecodable>"
    return "custom error selector " + data[:10]


def simulate(name, to, data, frm):
    res = rpc("eth_call", [{"from": frm, "to": to, "data": data}, "latest"])
    if "error" in res:
        err = res["error"]
        d = err.get("data") if isinstance(err.get("data"), str) else None
        print(f"  [{name}] REVERT: {err.get('message')}")
        if d:
            print(f"           -> {decode_revert(d)}")
        return False
    print(f"  [{name}] OK (would not revert)")
    return True


def main():
    print(f"RPC: {L1_RPC}")
    cid = int(rpc("eth_chainId", [])["result"], 16)
    print(f"chainId: {cid}\n")

    # Tx1
    tx1 = sel("setImplementation(uint32,address)") + encode(["uint32", "address"], [1, NEW_PDG])
    # Tx2
    portal_reinit = sel("reinitialize(address,address,address,uint32)") + encode(
        ["address", "address", "address", "uint32"], [DGF_PROXY, SYSCFG, SUPERCFG, RESPECTED]
    )
    tx2 = sel("upgradeAndCall(address,address,bytes)") + encode(
        ["address", "address", "bytes"], [PORTAL_PROXY, NEW_PORTAL, portal_reinit]
    )
    # Tx3
    # 只初始化 type1（respectedGameType=1）；type0 不用
    roots = [(1, (ANCHOR_ROOT, ANCHOR_BLK))]
    asr_reinit = sel("reinitialize((uint32,(bytes32,uint256))[],address)") + encode(
        ["(uint32,(bytes32,uint256))[]", "address"], [roots, SUPERCFG]
    )
    tx3 = sel("upgradeAndCall(address,address,bytes)") + encode(
        ["address", "address", "bytes"], [ASR_PROXY, NEW_ASR, asr_reinit]
    )

    print("Simulating (from = SystemOwnerSafe):")
    ok1 = simulate("Tx1 DGF.setImplementation", DGF_PROXY, "0x" + tx1.hex(), SAFE)
    ok2 = simulate("Tx2 Portal upgradeAndCall", PROXY_ADMIN, "0x" + tx2.hex(), SAFE)
    ok3 = simulate("Tx3 ASR upgradeAndCall", PROXY_ADMIN, "0x" + tx3.hex(), SAFE)

    print("\nNote: 三笔在 Safe 里是顺序执行；单独模拟每笔时其它笔的状态变更未生效，")
    print("      但这三笔之间无相互依赖（Tx1/2/3 改的是不同合约），单独模拟即可代表结果。")
    print(f"\nRESULT: {'ALL OK' if (ok1 and ok2 and ok3) else 'SOME REVERTED - 请勿执行，先排查'}")


if __name__ == "__main__":
    main()
