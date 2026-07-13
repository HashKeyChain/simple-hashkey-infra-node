#!/usr/bin/env python3
"""
生成 L2OO -> Fault Proofs 升级的 Safe 多签 batch（Safe Tx Builder JSON）。

包含 3 笔交易（全部由 SystemOwnerSafe = DGF.owner = ProxyAdmin.owner 发起）：
  Tx1: DisputeGameFactory.setImplementation(gameType=1, newPermissionedDG)
  Tx2: ProxyAdmin.upgradeAndCall(OptimismPortalProxy, newPortalImpl, portal.reinitialize(...))
  Tx3: ProxyAdmin.upgradeAndCall(AnchorStateRegistryProxy, newAsrImpl, asr.reinitialize(...))

纯离线生成 calldata，不广播、不签名。生成后在 Safe Web UI (app.safe.global) 的
Tx Builder 里 import，收集 3/6 签名后执行。

用法:
  python3 scripts/upgrade-l2oo-to-fp/gen-safe-batch.py
所有地址/参数从下方 CONFIG 读取，可按需修改或用环境变量覆盖。
"""
import json
import os
import time

from eth_abi import encode
from eth_utils import keccak, to_checksum_address

# ----------------------------------------------------------------------------
# CONFIG —— 这套是「新贴的那套 Sepolia 部署」+ 本次新部署的 3 个 impl
# ----------------------------------------------------------------------------
CHAIN_ID = int(os.environ.get("L1_CHAIN_ID", "11155111"))  # L1(Sepolia); 不要用会被 .envrc 污染的 CHAIN_ID

# 多签 / 权限
SYSTEM_OWNER_SAFE = to_checksum_address(os.environ.get("SYSTEM_OWNER_SAFE", "0xe9a1a112965B4e00577d6028c5116B388581a81e"))
PROXY_ADMIN       = to_checksum_address(os.environ.get("PROXY_ADMIN",       "0x659c166D3f4DD2e4F6E218B0eD0C6321Dc68619f"))

# Proxy（被升级对象）
DGF_PROXY    = to_checksum_address(os.environ.get("DGF_PROXY",    "0x799E013e33d05E48c8b774bFD83aaA82E92049b2"))
PORTAL_PROXY = to_checksum_address(os.environ.get("PORTAL_PROXY", "0x8dc71d4d25c415C0a9F11EF57Bd64ca208531645"))
ASR_PROXY    = to_checksum_address(os.environ.get("ASR_PROXY",    "0x04281Ef5FE221834dc3b6d0b0C87Ef360909C0C3"))

# 依赖 proxy（reinit 入参）
SYSTEM_CONFIG_PROXY     = to_checksum_address(os.environ.get("SYSTEM_CONFIG_PROXY",     "0x62163c0C9479b4b202eFa52bF8bd9cBBEdd9042F"))
SUPERCHAIN_CONFIG_PROXY = to_checksum_address(os.environ.get("SUPERCHAIN_CONFIG_PROXY", "0x8C40a3847301926eC17de95602216758eEe25a71"))

# 本次新部署并已 verify 的 impl
NEW_PORTAL_IMPL = to_checksum_address(os.environ.get("NEW_PORTAL_IMPL", "0xa1Cf656889Eb0A9Ee9C8500b6Ea1F6D385B29F01"))
NEW_ASR_IMPL    = to_checksum_address(os.environ.get("NEW_ASR_IMPL",    "0xda8E4105Dd3e094FA5514410F1CfB96fe9426a1D"))
NEW_PDG_IMPL    = to_checksum_address(os.environ.get("NEW_PDG_IMPL",    "0xA6d7B116527dD65b607327ABAE2977aA8Cd3E277"))

# 升级参数
RESPECTED_GAME_TYPE = int(os.environ.get("RESPECTED_GAME_TYPE", "1"))  # 1 = PERMISSIONED_CANNON
GAME_TYPE_CANNON    = 0
GAME_TYPE_PERM      = 1

# ASR 起始 anchor —— 从 L2OO -> FP 无缝迁移：取旧 L2OutputOracle
# (proxy 0x8650B8deED202306b475986974E2C3749bcFC7dE) 最新一条 output 作为起点。
#   L2OO.getL2Output(latestOutputIndex=16606):
#     outputRoot    = 0xee215931c2235a18a46c48a3968259b624ec331d62e9f4f5b05b8b9d9ca44e7a
#     l2BlockNumber = 29892600
# 若要重取更新的值，导出 FAULT_GAME_GENESIS_OUTPUT_ROOT / FAULT_GAME_GENESIS_BLOCK 覆盖。
ANCHOR_ROOT     = os.environ.get(
    "FAULT_GAME_GENESIS_OUTPUT_ROOT",
    "0xee215931c2235a18a46c48a3968259b624ec331d62e9f4f5b05b8b9d9ca44e7a",
)
ANCHOR_L2_BLOCK = int(os.environ.get("FAULT_GAME_GENESIS_BLOCK", "29892600"))

OUT_FILE = os.environ.get("BATCH_OUT", os.path.join(os.path.dirname(__file__), "safe-batch.json"))


def selector(sig: str) -> bytes:
    return keccak(text=sig)[:4]


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def build():
    root_bytes = bytes.fromhex(ANCHOR_ROOT[2:] if ANCHOR_ROOT.startswith("0x") else ANCHOR_ROOT)
    assert len(root_bytes) == 32, "anchor root must be 32 bytes"

    # ------------------------------------------------------------------
    # Tx1: DGF.setImplementation(uint32 gameType, address impl)
    # ------------------------------------------------------------------
    tx1_data = selector("setImplementation(uint32,address)") + encode(
        ["uint32", "address"], [GAME_TYPE_PERM, NEW_PDG_IMPL]
    )

    # ------------------------------------------------------------------
    # Tx2: ProxyAdmin.upgradeAndCall(portalProxy, newPortalImpl, reinitCalldata)
    #   reinitialize(IDisputeGameFactory, ISystemConfig, ISuperchainConfig, GameType)
    #   ABI 底层类型: (address, address, address, uint32)
    # ------------------------------------------------------------------
    portal_reinit = selector(
        "reinitialize(address,address,address,uint32)"
    ) + encode(
        ["address", "address", "address", "uint32"],
        [DGF_PROXY, SYSTEM_CONFIG_PROXY, SUPERCHAIN_CONFIG_PROXY, RESPECTED_GAME_TYPE],
    )
    tx2_data = selector("upgradeAndCall(address,address,bytes)") + encode(
        ["address", "address", "bytes"], [PORTAL_PROXY, NEW_PORTAL_IMPL, portal_reinit]
    )

    # ------------------------------------------------------------------
    # Tx3: ProxyAdmin.upgradeAndCall(asrProxy, newAsrImpl, reinitCalldata)
    #   reinitialize(StartingAnchorRoot[] _roots, ISuperchainConfig _sc)
    #   StartingAnchorRoot { GameType(uint32) gameType; OutputRoot{ bytes32 root; uint256 l2BlockNumber } outputRoot }
    #   ABI 底层类型: ( (uint32,(bytes32,uint256))[] , address )
    # ------------------------------------------------------------------
    # 最终只用 respectedGameType=1(PermissionedCannon)，故 anchor 只初始化 type1；
    # type0(Cannon) 不会被创建，anchors[0] 无需初始化。
    roots = [
        (GAME_TYPE_PERM, (root_bytes, ANCHOR_L2_BLOCK)),
    ]
    asr_reinit = selector(
        "reinitialize((uint32,(bytes32,uint256))[],address)"
    ) + encode(
        ["(uint32,(bytes32,uint256))[]", "address"],
        [roots, SUPERCHAIN_CONFIG_PROXY],
    )
    tx3_data = selector("upgradeAndCall(address,address,bytes)") + encode(
        ["address", "address", "bytes"], [ASR_PROXY, NEW_ASR_IMPL, asr_reinit]
    )

    txs = [
        {
            "label": "Tx1 DGF.setImplementation(1, newPermissionedDG)",
            "to": DGF_PROXY,
            "value": "0",
            "data": hx(tx1_data),
        },
        {
            "label": "Tx2 ProxyAdmin.upgradeAndCall(PortalProxy -> newPortalImpl + reinitialize)",
            "to": PROXY_ADMIN,
            "value": "0",
            "data": hx(tx2_data),
        },
        {
            "label": "Tx3 ProxyAdmin.upgradeAndCall(ASRProxy -> newAsrImpl + reinitialize)",
            "to": PROXY_ADMIN,
            "value": "0",
            "data": hx(tx3_data),
        },
    ]
    return txs


def main():
    txs = build()

    print("=" * 70)
    print(" L2OO -> Fault Proofs 升级 Safe batch")
    print("=" * 70)
    print(f"  SystemOwnerSafe (发起方): {SYSTEM_OWNER_SAFE}")
    print(f"  ProxyAdmin:               {PROXY_ADMIN}")
    print(f"  DGF proxy:                {DGF_PROXY}")
    print(f"  Portal proxy:             {PORTAL_PROXY}  -> impl {NEW_PORTAL_IMPL}")
    print(f"  ASR proxy:                {ASR_PROXY}  -> impl {NEW_ASR_IMPL}")
    print(f"  new PermissionedDG impl:  {NEW_PDG_IMPL} (gameType={GAME_TYPE_PERM})")
    print(f"  respectedGameType:        {RESPECTED_GAME_TYPE}")
    print(f"  ASR anchor:               root={ANCHOR_ROOT} l2Block={ANCHOR_L2_BLOCK}")
    print("=" * 70)
    for t in txs:
        print(f"\n== {t['label']} ==")
        print(f"  to:    {t['to']}")
        print(f"  value: {t['value']}")
        print(f"  data:  {t['data']}")

    batch = {
        "version": "1.0",
        "chainId": str(CHAIN_ID),
        "createdAt": int(time.time() * 1000),
        "meta": {
            "name": "L2OO to Fault Proofs upgrade",
            "description": "setImplementation(PDG) + upgradeAndCall(Portal reinit) + upgradeAndCall(ASR reinit)",
            "txBuilderVersion": "1.16.5",
            "createdFromSafeAddress": SYSTEM_OWNER_SAFE,
            "createdFromOwnerAddress": "",
            "checksum": "",
        },
        "transactions": [
            {
                "to": t["to"],
                "value": t["value"],
                "data": t["data"],
                "contractMethod": None,
                "contractInputsValues": None,
            }
            for t in txs
        ],
    }
    with open(OUT_FILE, "w") as f:
        json.dump(batch, f, indent=2)

    print("\n" + "=" * 70)
    print(f" Safe Tx Builder JSON 已生成: {OUT_FILE}")
    print("=" * 70)
    print("在 https://app.safe.global → 你的 Safe → Apps → Transaction Builder")
    print("拖入该 JSON，加载这 3 笔；收满 3/6 签名后一次性执行。")


if __name__ == "__main__":
    main()
