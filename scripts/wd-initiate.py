#!/usr/bin/env python3
"""只发起 L2->L1 提款（initiateWithdrawal），打印 tx/block/wdHash，便于之后单独 prove+finalize。"""
import json, os, sys
from web3 import Web3

L2 = os.environ.get("L2_RPC", "https://qa-cgt.hashkeychain.net")
PRIV = os.environ["WITHDRAW_PRIVATE_KEY"]
AMOUNT_WEI = int(os.environ.get("AMOUNT_WEI", str(int(0.0666 * 10**18))))

w2 = Web3(Web3.HTTPProvider(L2))
acct = w2.eth.account.from_key(PRIV)
TARGET = Web3.to_checksum_address(os.environ.get("TARGET", acct.address))
MP = Web3.to_checksum_address("0x4200000000000000000000000000000000000016")
MP_ABI = json.loads('[{"type":"function","name":"initiateWithdrawal","stateMutability":"payable","inputs":[{"name":"_target","type":"address"},{"name":"_gasLimit","type":"uint256"},{"name":"_data","type":"bytes"}],"outputs":[]}]')
TOPIC = "0x" + Web3.keccak(text="MessagePassed(uint256,address,address,uint256,uint256,bytes,bytes32)").hex().lstrip("0x")

mp = w2.eth.contract(address=MP, abi=MP_ABI)
# 允许通过环境变量指定 nonce（用于 replace-by-fee）和 gas 价格
nonce_env = os.environ.get("NONCE")
nonce = int(nonce_env) if nonce_env is not None else w2.eth.get_transaction_count(acct.address)
max_fee_gwei = float(os.environ.get("MAX_FEE_GWEI", "5"))
prio_gwei = float(os.environ.get("PRIO_GWEI", "0.1"))
tx = mp.functions.initiateWithdrawal(TARGET, 200000, b"").build_transaction({
    "from": acct.address,
    "nonce": nonce,
    "value": AMOUNT_WEI,
    "gas": 300000,
    "maxFeePerGas": w2.to_wei(max_fee_gwei, "gwei"),
    "maxPriorityFeePerGas": w2.to_wei(prio_gwei, "gwei"),
})
print(f"using nonce={nonce} maxFee={max_fee_gwei}gwei prio={prio_gwei}gwei")
signed = acct.sign_transaction(tx)
h = w2.eth.send_raw_transaction(signed.raw_transaction)
print("sent:", h.hex())
rcpt = w2.eth.wait_for_transaction_receipt(h, timeout=120)
if rcpt["status"] != 1:
    sys.exit(f"REVERTED tx={rcpt['transactionHash'].hex()}")

wd_hash = None
for lg in rcpt["logs"]:
    if lg["address"].lower() == MP.lower() and lg["topics"][0].hex().lower().lstrip("0x") == TOPIC.lower().lstrip("0x"):
        wd_hash = bytes(lg["data"])[96:128]
        break
print("=" * 60)
print("WITHDRAWAL INITIATED")
print("  L2 tx   :", rcpt["transactionHash"].hex())
print("  L2 block:", rcpt["blockNumber"])
print("  amount  :", AMOUNT_WEI / 1e18, "HSK")
print("  target  :", TARGET)
print("  wdHash  : 0x" + (wd_hash.hex() if wd_hash else "?"))
print("=" * 60)
print("之后 prove+finalize 用:")
print(f"  WITHDRAW_TX={rcpt['transactionHash'].hex()}")
