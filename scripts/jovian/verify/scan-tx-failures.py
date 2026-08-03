#!/usr/bin/env python3
"""Calculate transaction failure rates over block ranges to detect fork regressions.

Usage:
  python3 scan-tx-failures.py <rpc> <start_block> <end_block> [range_label]
"""
import json
import sys
import urllib.request
from collections import Counter, defaultdict

BATCH = 40


def rpc_batch(url, calls):
    req = urllib.request.Request(
        url,
        data=json.dumps(calls).encode(),
        # Public RPC endpoints may reject requests based on User-Agent; the
        # default python-urllib User-Agent receives a 403 response.
        headers={"Content-Type": "application/json", "User-Agent": "curl/8.7.1"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        out = json.loads(resp.read())
    return out if isinstance(out, list) else [out]


def scan(url, lo, hi):
    total = 0
    failed = 0
    fail_by_to = Counter()
    fail_by_from = Counter()
    fail_txs = []
    seen_to = Counter()
    blocks = 0

    n = lo
    while n <= hi:
        chunk = list(range(n, min(n + BATCH, hi + 1)))
        calls = [
            {
                "jsonrpc": "2.0",
                "id": b,
                "method": "eth_getBlockReceipts",
                "params": [hex(b)],
            }
            for b in chunk
        ]
        for resp in rpc_batch(url, calls):
            rcpts = resp.get("result")
            if rcpts is None:
                continue
            blocks += 1
            for r in rcpts:
                # Exclude system deposit transactions (type 0x7e); count only
                # user transactions.
                if r.get("type") == "0x7e":
                    continue
                total += 1
                to = (r.get("to") or "CREATE").lower()
                seen_to[to] += 1
                if r.get("status") != "0x1":
                    failed += 1
                    fail_by_to[to] += 1
                    fail_by_from[(r.get("from") or "").lower()] += 1
                    fail_txs.append(
                        (int(r["blockNumber"], 16), r["transactionHash"], to)
                    )
        n += BATCH

    return {
        "blocks": blocks,
        "total": total,
        "failed": failed,
        "fail_by_to": fail_by_to,
        "fail_by_from": fail_by_from,
        "fail_txs": fail_txs,
        "seen_to": seen_to,
    }


def main():
    url, lo, hi = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    label = sys.argv[4] if len(sys.argv) > 4 else f"{lo}-{hi}"

    s = scan(url, lo, hi)
    rate = (100.0 * s["failed"] / s["total"]) if s["total"] else 0.0
    print(f"=== {label}  Blocks {lo}-{hi} ===")
    print(f"  Blocks scanned         : {s['blocks']}")
    print(f"  Total user transactions: {s['total']}  (type=0x7e system deposits excluded)")
    print(f"  Failed transactions    : {s['failed']}   failure rate {rate:.2f}%")
    if s["fail_by_to"]:
        print("  Failed transactions by destination contract:")
        for to, c in s["fail_by_to"].most_common(10):
            seen = s["seen_to"][to]
            print(f"    {to}  failed {c}/{seen}")
        print("  Failed transactions by sender:")
        for f, c in s["fail_by_from"].most_common(10):
            print(f"    {f}  {c}")
    print()


if __name__ == "__main__":
    main()
