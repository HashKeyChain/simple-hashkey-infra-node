#!/usr/bin/env python3
"""Compare CCIP CommitStore activity around forks and verify log retrievability.

Usage: python3 diag-commitstore.py <rpc>
"""
import json
import sys
import urllib.request

BATCH = 40
UA = {"Content-Type": "application/json", "User-Agent": "curl/8.7.1"}
COMMIT_STORE = "0xba06f184949ce3779b70cd2548fae42ba7649cfb"


def rpc(url, calls):
    req = urllib.request.Request(url, data=json.dumps(calls).encode(), headers=UA)
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read())


def commitstore_activity(url, lo, hi):
    """Return (successful, failed), with (block, txhash, gasUsed, log count) entries."""
    ok, bad = [], []
    n = lo
    while n <= hi:
        chunk = list(range(n, min(n + BATCH, hi + 1)))
        calls = [{"jsonrpc": "2.0", "id": b, "method": "eth_getBlockReceipts",
                  "params": [hex(b)]} for b in chunk]
        for resp in rpc(url, calls):
            for r in resp.get("result") or []:
                if (r.get("to") or "").lower() != COMMIT_STORE:
                    continue
                rec = (int(r["blockNumber"], 16), r["transactionHash"],
                       int(r["gasUsed"], 16), len(r.get("logs") or []))
                (ok if r.get("status") == "0x1" else bad).append(rec)
        n += BATCH
    return sorted(ok), sorted(bad)


def report(url, label, lo, hi):
    ok, bad = commitstore_activity(url, lo, hi)
    blocks = hi - lo + 1
    total = len(ok) + len(bad)
    print(f"=== {label}  Blocks {lo}-{hi} ({blocks} blocks) ===")
    print(f"  CommitStore transactions: {total} total  {len(ok)} successful  {len(bad)} failed")
    if total:
        print(f"  Submission rate: {100.0*total/blocks:.2f} per 100 blocks")
    if ok:
        print(f"  gasUsed for successful transactions: {[g for _, _, g, _ in ok][:8]}")
        print(f"  Log counts for successful transactions: {[l for _, _, _, l in ok][:8]}")
        # Failures between successful rounds indicate how many oracles submitted
        # duplicate reports in each round.
        marks = sorted([(b, 'OK') for b, _, _, _ in ok] + [(b, 'X') for b, _, _, _ in bad])
        seq = "".join('O' if m == 'OK' else '.' for _, m in marks)
        print(f"  Sequence (O=success .=StaleReport): {seq[:120]}")
    print()
    return ok, bad


def check_log_retrievability(url, ok):
    """Confirm that eth_getLogs can retrieve events from successful transmits."""
    print("=== Log retrievability cross-check (rules out missing events at Chainlink nodes) ===")
    for bn, h, gas, nlogs in ok[-3:]:
        rcpt = rpc(url, {"jsonrpc": "2.0", "id": 1,
                         "method": "eth_getTransactionReceipt", "params": [h]})["result"]
        rlogs = rcpt.get("logs") or []
        got = rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "eth_getLogs",
                        "params": [{"fromBlock": hex(bn), "toBlock": hex(bn),
                                    "address": COMMIT_STORE}]}).get("result") or []
        topics = [l["topics"][0] for l in rlogs]
        match = len(got) >= len(rlogs) and len(rlogs) > 0
        print(f"  Block {bn}: {len(rlogs)} receipt logs, eth_getLogs returned {len(got)} "
              f"-> {'match' if match else 'MISMATCH!'}")
        print(f"    topic0: {topics}")


def main():
    url = sys.argv[1]
    head = int(rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber",
                         "params": []})["result"], 16)
    print(f"head = {head}\n")

    report(url, "Before forks (before batcher pause)", 25474700, 25479374)
    report(url, "After batcher pause / before Isthmus", 25479375, 25479882)
    report(url, "After Isthmus+Prague / before Jovian", 25479883, 25480032)
    ok_d, _ = report(url, "After Jovian", 25480033, head)

    if ok_d:
        check_log_retrievability(url, ok_d)


if __name__ == "__main__":
    main()
