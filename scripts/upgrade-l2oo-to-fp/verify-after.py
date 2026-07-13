#!/usr/bin/env python3
"""
升级后验证：确认 3 笔生效。纯只读。

用法:
  L1_RPC=http://qa-proxy.hashkeychain.net:8545 \
  python3 scripts/upgrade-l2oo-to-fp/verify-after.py
"""
import json
import os
import urllib.request

from eth_utils import keccak, to_checksum_address

L1_RPC = os.environ.get("L1_RPC", "http://qa-proxy.hashkeychain.net:8545")

PROXY_ADMIN  = to_checksum_address("0x659c166D3f4DD2e4F6E218B0eD0C6321Dc68619f")
DGF_PROXY    = to_checksum_address("0x799E013e33d05E48c8b774bFD83aaA82E92049b2")
PORTAL_PROXY = to_checksum_address("0x8dc71d4d25c415C0a9F11EF57Bd64ca208531645")
ASR_PROXY    = to_checksum_address("0x04281Ef5FE221834dc3b6d0b0C87Ef360909C0C3")
DGFPROXY_L   = DGF_PROXY.lower()
SUPERCFG     = "0x8C40a3847301926eC17de95602216758eEe25a71".lower()
NEW_PORTAL   = "0xa1Cf656889Eb0A9Ee9C8500b6Ea1F6D385B29F01".lower()
NEW_ASR      = "0xda8E4105Dd3e094FA5514410F1CfB96fe9426a1D".lower()
NEW_PDG      = "0xA6d7B116527dD65b607327ABAE2977aA8Cd3E277".lower()


def sel(sig):
    return "0x" + keccak(text=sig).hex()[:8]


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(L1_RPC, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r).get("result")


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def addr(r):
    return "0x" + r[-40:] if r and len(r) >= 42 else r


def check(label, got, want):
    ok = got is not None and got.lower() == want.lower()
    print(f"  [{'OK ' if ok else 'XX '}] {label}: {got}" + ("" if ok else f"  (want {want})"))
    return ok


def main():
    print(f"RPC: {L1_RPC}\n")
    results = []

    # DGF.gameImpls(1)
    g = call(DGF_PROXY, sel("gameImpls(uint32)") + "00" * 31 + "01")
    results.append(check("DGF.gameImpls(1)", addr(g), NEW_PDG))

    # Portal impl
    p_impl = call(PROXY_ADMIN, sel("getProxyImplementation(address)") + "0" * 24 + PORTAL_PROXY[2:].lower())
    results.append(check("Portal impl", addr(p_impl), NEW_PORTAL))
    # Portal.respectedGameType()
    rgt = call(PORTAL_PROXY, sel("respectedGameType()"))
    print(f"  [   ] Portal.respectedGameType() = {int(rgt,16) if rgt and rgt!='0x' else rgt}")
    # Portal.disputeGameFactory()
    dgf = call(PORTAL_PROXY, sel("disputeGameFactory()"))
    results.append(check("Portal.disputeGameFactory()", addr(dgf), DGF_PROXY))

    # ASR impl
    a_impl = call(PROXY_ADMIN, sel("getProxyImplementation(address)") + "0" * 24 + ASR_PROXY[2:].lower())
    results.append(check("ASR impl", addr(a_impl), NEW_ASR))
    # ASR.superchainConfig()
    sc = call(ASR_PROXY, sel("superchainConfig()"))
    results.append(check("ASR.superchainConfig()", addr(sc), SUPERCFG))
    # ASR.anchors(1) / anchors(0)
    for gt in (1, 0):
        a = call(ASR_PROXY, sel("anchors(uint32)") + "00" * 31 + f"{gt:02x}")
        if a and len(a) >= 130:
            root = "0x" + a[2:66]
            blk = int(a[66:130], 16)
            print(f"  [   ] ASR.anchors({gt}) root={root} l2Block={blk}")

    # _initialized == 2
    for name, pr in (("Portal", PORTAL_PROXY), ("ASR", ASR_PROXY)):
        s0 = rpc("eth_getStorageAt", [pr, "0x0", "latest"])
        v = int(s0, 16) & 0xFF if s0 else None
        print(f"  [{'OK ' if v==2 else '?? '}] {name} _initialized (slot0 low byte) = {v}")

    print(f"\nRESULT: {'ALL KEY CHECKS PASS' if all(results) else 'SOME CHECKS FAILED'}")


if __name__ == "__main__":
    main()
