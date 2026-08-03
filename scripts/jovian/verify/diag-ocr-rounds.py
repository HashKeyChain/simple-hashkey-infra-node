#!/usr/bin/env python3
"""Characterize the CCIP failure storm:
  1. Correctly verify log retrievability (no address filter; receipt logs vs all eth_getLogs results).
  2. Count distinct transmitters submitting in each OCR round (before vs after the fork).
  3. Locate the batcher's latest L1 submission to rule out a "finality timeout" hypothesis.

Usage: python3 diag-ocr-rounds.py <l2_rpc> [l1_rpc]
"""
import json
import sys
import urllib.request

BATCH = 40
UA = {"Content-Type": "application/json", "User-Agent": "curl/8.7.1"}
COMMIT_STORE = "0xba06f184949ce3779b70cd2548fae42ba7649cfb"
BATCH_INBOX = "0x0004cb44c80b6fbf8ceb1d80af688c9f7c0b2ab5"


def rpc(url, calls):
    req = urllib.request.Request(url, data=json.dumps(calls).encode(), headers=UA)
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read())


def one(url, method, params):
    return rpc(url, {"jsonrpc": "2.0", "id": 1, "method": method,
                     "params": params}).get("result")


def check_logs(url, blocks):
    print("=== Log retrievability (receipt logs vs all eth_getLogs results, no address filter) ===")
    for bn in blocks:
        rcpts = one(url, "eth_getBlockReceipts", [hex(bn)]) or []
        rcpt_logs = sum(len(r.get("logs") or []) for r in rcpts)
        got = one(url, "eth_getLogs", [{"fromBlock": hex(bn), "toBlock": hex(bn)}]) or []
        blk = one(url, "eth_getBlockByNumber", [hex(bn), False]) or {}
        flag = "match" if rcpt_logs == len(got) else "MISMATCH!"
        print(f"  Block {bn}: {rcpt_logs} receipt logs total, eth_getLogs returned {len(got)} -> {flag}"
              f"   logsBloom length {len(blk.get('logsBloom',''))}")
    print()


def transmitters_per_round(url, lo, hi, label):
    """Treat submissions through the next success as one round; count distinct senders."""
    txs = []
    n = lo
    while n <= hi:
        chunk = list(range(n, min(n + BATCH, hi + 1)))
        calls = [{"jsonrpc": "2.0", "id": b, "method": "eth_getBlockReceipts",
                  "params": [hex(b)]} for b in chunk]
        for resp in rpc(url, calls):
            for r in resp.get("result") or []:
                if (r.get("to") or "").lower() != COMMIT_STORE:
                    continue
                txs.append((int(r["blockNumber"], 16), (r.get("from") or "").lower(),
                            r.get("status") == "0x1"))
        n += BATCH
    txs.sort()

    rounds, cur = [], []
    for bn, frm, ok in txs:
        cur.append((bn, frm, ok))
        if ok:
            rounds.append(cur)
            cur = []
    if cur:
        rounds.append(cur)

    print(f"=== {label}  Blocks {lo}-{hi} ===")
    print(f"  {len(txs)} CommitStore transactions grouped into {len(rounds)} rounds")
    sizes = [len(set(f for _, f, _ in r)) for r in rounds]
    if sizes:
        print(f"  Distinct transmitters per round: {sizes}")
        print(f"  Average transmitters submitting per round: {sum(sizes)/len(sizes):.2f}")
    print()


def find_last_batch(url, lookback_l1_blocks=400):
    print("=== Batcher's latest L1 submission ===")
    head = int(one(url, "eth_blockNumber", []), 16)
    lo = head - lookback_l1_blocks
    found = None
    n = head
    while n >= lo:
        chunk = list(range(max(lo, n - 19), n + 1))
        calls = [{"jsonrpc": "2.0", "id": b, "method": "eth_getBlockByNumber",
                  "params": [hex(b), True]} for b in chunk]
        try:
            resps = rpc(url, calls)
        except Exception as e:
            print(f"  L1 scan failed: {e}")
            return
        for resp in resps:
            blk = resp.get("result") or {}
            for tx in blk.get("transactions") or []:
                if (tx.get("to") or "").lower() == BATCH_INBOX:
                    bn = int(blk["number"], 16)
                    ts = int(blk["timestamp"], 16)
                    if not found or bn > found[0]:
                        found = (bn, ts, tx["hash"])
        if found:
            break
        n -= 20
    if found:
        bn, ts, h = found
        now = int(one(url, "eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
        print(f"  Latest batch: L1 block {bn}  ts={ts}  ({(now-ts)//60} minutes ago)  tx={h}")
    else:
        print(f"  No batchInbox transaction in the latest {lookback_l1_blocks} L1 blocks "
              f"(no submission for >{lookback_l1_blocks*12//60} minutes)")
    print()


def main():
    l2 = sys.argv[1]
    head = int(one(l2, "eth_blockNumber", []), 16)

    check_logs(l2, [25479000, 25479883, 25480033, head - 5])
    transmitters_per_round(l2, 25474700, 25479374, "Before forks")
    transmitters_per_round(l2, 25479883, 25480032, "After Isthmus+Prague / before Jovian")
    transmitters_per_round(l2, 25480033, head, "After Jovian")

    if len(sys.argv) > 2:
        find_last_batch(sys.argv[2])


if __name__ == "__main__":
    main()
