#!/usr/bin/env python3
"""Locate the onset of Chainlink CCIP transaction failures and their revert reasons.

Usage: python3 diag-chainlink-failures.py <rpc> <start_block> <end_block>
"""
import json
import sys
import urllib.request
from collections import Counter

BATCH = 40
UA = {"Content-Type": "application/json", "User-Agent": "curl/8.7.1"}

# Known CCIP / Chainlink custom error selectors
KNOWN_ERRORS = {
    "0xf803a2ca": "StaleReport()",
    "0xa0bce24f": "RootAlreadyCommitted()",
    "0x504570e3": "InvalidRoot()",
    "0x53ad11d8": "CursedByRMN()",
    "0x0bfecd63": "InvalidInterval()",
    "0x0f01ce85": "UnauthorizedTransmitter()",
    "0x2b5c74de": "ConfigDigestMismatch()",
    "0x71253a25": "WrongNumberOfSignatures()",
    "0xd0d25976": "SignaturesOutOfRegistration()",
    "0xb1c1f68e": "UnauthorizedSigner()",
    "0x08c379a0": "Error(string)",
    "0x4e487b71": "Panic(uint256)",
}


def rpc(url, calls):
    single = isinstance(calls, dict)
    req = urllib.request.Request(
        url, data=json.dumps(calls).encode(), headers=UA
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        out = json.loads(resp.read())
    return out if not single else out


def collect_failures(url, lo, hi):
    fails, oks = [], []
    n = lo
    while n <= hi:
        chunk = list(range(n, min(n + BATCH, hi + 1)))
        calls = [
            {"jsonrpc": "2.0", "id": b, "method": "eth_getBlockReceipts",
             "params": [hex(b)]}
            for b in chunk
        ]
        for resp in rpc(url, calls):
            for r in resp.get("result") or []:
                if r.get("type") == "0x7e":
                    continue
                rec = (int(r["blockNumber"], 16), r["transactionHash"],
                       (r.get("to") or "").lower(), (r.get("from") or "").lower(),
                       int(r["gasUsed"], 16))
                (fails if r.get("status") != "0x1" else oks).append(rec)
        n += BATCH
    return sorted(fails), sorted(oks)


def revert_reason(url, txhash, block):
    """Replay with eth_call against the parent-block state to obtain revert data."""
    tx = rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionByHash",
                   "params": [txhash]})["result"]
    call = {
        "from": tx["from"], "to": tx["to"], "data": tx["input"],
        "value": tx["value"], "gas": tx["gas"],
    }
    resp = rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                     "params": [call, hex(block - 1)]})
    err = resp.get("error") or {}
    data = err.get("data") or ""
    sel = data[:10] if data.startswith("0x") and len(data) >= 10 else data
    return sel, KNOWN_ERRORS.get(sel, "unknown"), err.get("message", ""), tx["input"][:10]


def main():
    url, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    fails, oks = collect_failures(url, lo, hi)

    print(f"=== Blocks {lo}-{hi} ===")
    print(f"  {len(oks)} successful, {len(fails)} failed")
    if fails:
        print(f"  Earliest failure: block {fails[0][0]}  {fails[0][1]}")
    if oks:
        print(f"  Earliest success: block {oks[0][0]}  {oks[0][1]}")
    print()

    print("  Revert reasons for failed samples (eth_call replayed at parent block):")
    step = max(1, len(fails) // 8)
    for bn, h, to, frm, gas in fails[::step][:8]:
        sel, name, msg, insel = revert_reason(url, h, bn)
        print(f"    block {bn} input selector={insel} gasUsed={gas:<7} -> {sel} {name}")

    print()
    print("  Input selectors for successful samples:")
    step = max(1, len(oks) // 6)
    for bn, h, to, frm, gas in oks[::step][:6]:
        tx = rpc(url, {"jsonrpc": "2.0", "id": 1,
                       "method": "eth_getTransactionByHash", "params": [h]})["result"]
        print(f"    block {bn} selector={tx['input'][:10]} to={to} gasUsed={gas}")


if __name__ == "__main__":
    main()
