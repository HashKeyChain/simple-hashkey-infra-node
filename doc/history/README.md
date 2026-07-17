# 历史 / 归档文档

这里放**已被取代或不再是主线**的文档，仅供追溯，不代表当前推荐流程。

当前主线（新手请看这里）：

- 部署一条新链并推进到 Jovian：仓库根 `README.md`
- 详细手册（生命周期、组件、排障、bridge/验证）：`doc/chain-lifecycle.md`
- 下一步 Flashblocks：`doc/flashblocks_upgrade_plan.md`、`doc/flashblocks_local_impl.md`

## 归档清单

| 文档 | 说明 | 被谁取代 |
|---|---|---|
| `local_cgt_jovian_upgrade_runbook.md` | 早期本地"从零重建 → 逐步激活分叉 → bridge → 验证"的**手动**分步手册 | 一键脚本 `scripts/deploy-chain/deploy-jovian-chain.sh` + `doc/chain-lifecycle.md` |
| `remote_l1_cgt_jovian_deploy_runbook.md` | 远端真实 L1（testnet/mainnet）部署与 Jovian 升级手册 | 需要远端部署时可参考；本地开发不涉及 |

> 这些手册里的手动命令仍可用于排障或远端场景，但脚本路径可能是旧的
> （脚本已迁移到 `scripts/deploy-chain/` 与 `scripts/chain-ops/`）。以当前主线文档为准。
