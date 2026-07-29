# Flashblocks 验证脚本

把 Flashblocks 的验收检查固化成可重复执行的脚本。每个脚本只做一类检查，输出
`PASS / FAIL / WARN / SKIP` 四种结果，退出码 0 表示全部通过，便于串进 CI 或反复自查。

验证门的定义见 `doc/flashblocks_local_impl.md` §7，运维流程见 `doc/chain-lifecycle.md`。

## 快速开始

```bash
# 按当前链的实际状态自动挑选该跑的验证门
bash scripts/flashblocks/verify/run-all.sh

# 只想快速过一遍，不发交易
bash scripts/flashblocks/verify/run-all.sh --quick
```

## 各脚本职责

| 脚本 | 验证什么 | 前提 |
|---|---|---|
| `p0-genesis.sh` | 四个 Rust 二进制齐备、版本锁在 Jovian 世代、分叉时间已烘入 genesis、op-rbuilder 与 op-geth 创世 hash 一致、每块分片数配置正确、所有组件共用同一份 JWT | 无（创世对比需两侧在跑，否则自动 SKIP） |
| `p1-shadow.sh` | op-rbuilder 追平链头、采样区块的 blockHash 与 op-geth 完全一致、无 invalid block、两侧同步推进 | op-geth + op-rbuilder 在跑 |
| `p2-dryrun.sh` | 六件事：dry_run 模式 → op-node 走 rollup-boost → builder op-node 已停 → 出块未受影响 → **没有 builder 块被判 INVALID** → builder 确实在交付候选块 | `dry_run` 模式 |
| `p2-txs.sh` | 五类交易（CGT 存款 / 转账 / 部署 / 调用 / revert）在两侧产出一致的区块与状态 | `dry_run`，账户需有 L2 余额 |
| `p3-enabled.sh` | builder 块真正用于 canonical 链、flashblock 持续产出、对外广播流 (:1112) 握手成功且有数据、builder 失败时自动回退 op-geth | `enabled` 模式，或加 `--switch` 自动切换 |
| `run-all.sh` | 按当前模式编排上述脚本并汇总 | 无 |

## 常用参数

```bash
# 放宽追平判定、多采样几个块
bash scripts/flashblocks/verify/p1-shadow.sh --lag=3 --samples=20

# 拉长观测窗口，让低频问题有机会暴露
bash scripts/flashblocks/verify/p2-dryrun.sh --watch=120

# 交易覆盖，但跳过较慢的 L1 存款
bash scripts/flashblocks/verify/p2-txs.sh --skip-deposit

# 从 dry_run 临时切到 enabled 验证，结束后自动切回
bash scripts/flashblocks/verify/p3-enabled.sh --switch
```

## 怎么实现的

查链一律用 `cast`，数日志一律用 `rg`，`lib.sh` 里只有环境装载、输出与断言，没有别的机关。
唯一的例外是 `wscheck/`（一个 Go 文件）：要判断 flashblocks 广播端口是不是真在推数据，
得完成 WebSocket 的 HTTP Upgrade 握手、校验 `Sec-WebSocket-Accept`、再按 RFC 6455 解帧，
shell 做不到。它零外部依赖，`lib.sh` 在源码比二进制新时会自动 `go build` 到 `bin/wscheck`；
没有 Go 工具链时该项自动 SKIP，不影响其余检查。

## 判定方法上的两个约定

**日志看全量。** 这些脚本是给新起的链用的 —— 日志从创世开始，全量条数就是这条链的真实
情况，「有没有出过一次 `InvalidPayload`」直接数总数即可。只有需要和窗口内出块数相比的项
（builder 交付率、flashblock 片数、enabled 下的 builder 占比）才在观测前后各数一次相减，
那几处在脚本里就是两行 `log_count` 加一个减法。

反过来说，如果在跑了很久、反复切换过模式的链上复用这些脚本，历史记录会一起算进来：
比如这条链曾切到 enabled 跑过，`p2` 的「没有 builder 块被采纳上链」就会数到那段历史而报
FAIL。遇到这种情况清掉 `data/logs` 重新起链再验最省事，脚本也会在那一项下面提示。

**认 `context` 字段。** rollup-boost 每次 getPayload 都会打一行
`returning block hash=… number=… context=<l2|builder>`，`context` 就是最终上链的 payload
来源，上游集成测试也靠这行判定。dry_run 下它必须恒为 `l2`（builder 块只比对不上链），
enabled 下应绝大多数为 `builder`。

## P2 查哪六件事

P2 刻意只留六项，每项都能独立抓到真问题，顺序即依赖顺序——前一项不成立，后一项的结论就没意义：

1. rollup-boost 处于 `dry_run`（前提）
2. op-node 的 Engine 指向 rollup-boost，否则 builder 压根没参与出块
3. builder op-node 已停，否则它会和 rollup-boost 抢 op-rbuilder 的 auth RPC
4. 出块速度未受影响，且没有 builder 块被采纳上链（dry_run 语义）
5. **没有 builder 块被判 INVALID** ← 硬门槛，P2 真正要证明的事
6. builder 确实在交付候选块，否则第 5 项的 0 是「零样本」而非「零缺陷」

被挪走或删掉的检查项及理由：分片配置是一次性静态检查（→ `p0`）；flashblocks 片数、
拼接错误只影响用户侧预确认流，而 dry_run 阶段这个流没有消费者（→ `p3`）；
safe head / batcher / proposer 健康与 Flashblocks 无关，属基础链健康（→ `p1` 和日常监控）；
端口监听、bad block 计数等则会被上面某项先捕获，自己抓不到新东西。

手动只敲一条命令的话，等价于第 5、6 项加 dry_run 语义：

```bash
sed 's/\x1b\[[0-9;]*m//g' data/logs/rollup-boost.log | tail -3000 | rg -c \
  -e 'InvalidPayload' -e 'returning block.*context=builder' -e 'error getting payload from builder'
```

但 builder 脱链在 rollup-boost 日志里看不出来（只会写「没交货」，不说为什么），
要定位得比块高：`cast bn --rpc-url $L2_RPC` 对 `cast bn --rpc-url $RB_RPC`。

**硬门槛是「有效」，不是「相同」。** op-geth 收到 builder 候选块后会独立重放其中全部交易、
自己复算 stateRoot / receiptsRoot / gasUsed，再与块头声称的值比对，对不上就返回 INVALID。
所以「VALID」一条结论即等价于「builder 的执行语义与 op-geth 一致」，而且是在 builder
自选的任意交易集上成立，比「两个块相同」更强的保证。计划文档 §六「交叉校验的本质」讲的就是这件事。
INVALID 会经 `rpc.rs` 转成 Err、冒到 `error getting payload from builder error=InvalidPayload(...)`
那行日志，所以有痕可查——脚本里这一项就是数 `InvalidPayload` 出现了几次。

**但这个 0 有边界。** Engine API 的状态有 `VALID` / `INVALID` / `SYNCING` / `ACCEPTED` 四种，
rollup-boost 只在 `INVALID` 时留痕（`is_invalid()` 在 alloy 里就是 `matches!(self, Invalid{..})`），
`SYNCING` 和 `ACCEPTED` 都当成功放过。所以「没有 `InvalidPayload`」的准确含义是
**「没有被判定为无效」**，不等于「已被验证通过」——还有一种可能是 op-geth 压根没验成
（候选块父块未知时返回 `SYNCING`）。这种情况几乎都源于 builder 脱链，
会先被第 6 项的交付率和块高差抓到，属间接覆盖而非严格等价。

**次级是交付率。** INVALID=0 也可能因为 builder 压根没交付过块——那是零样本，不是零缺陷。
所以必须同时看有多少块真的拿到了候选块。dry_run 下缺失无害（反正用 op-geth 的块），
enabled 后每次缺失都是一次降级回退：链是安全的，只是那个块没有 flashblocks。

**相同性脚本不查。** builder 有自己的排序和 flashblocks 分片策略，enabled 后它造的块
本就该和 op-geth 不同，否则接它没有意义。所以「两个块不一样」不是缺陷，不值得为它
写对账逻辑。要看差异分布就读下面提到的 Prometheus 指标——那是完整直方图，
比在日志里抽几个样本对账准得多。

顺带一提，rollup-boost 的 Prometheus 指标（`--metrics`，端口见 `RB_METRICS_PORT`）
只有 `block_building_gas_delta` / `block_building_tx_count_delta` 这类 delta 分布，
**没有块无效计数**——第 5 项只能从日志数 `InvalidPayload`。

## 需要留意的地方

**p2-txs.sh 会把同一笔交易投给两个节点。** dry_run 下用户交易走 op-geth 的 HTTP RPC，
不经过 rollup-boost，op-rbuilder 的交易池收不到，它造出来的会是空块，对账就假失败了。
真实 enabled 拓扑里这一步由 op-reth → rollup-boost 的 fan-out 完成；dry_run 下没起 op-reth，
所以脚本手动复现 fan-out。副作用是两侧打包时机可能差一个块，那一个块会出现
`tx_count_delta=±1`，属正常；空载时应恒为 0。

**p3 的 `--fallback-drill` 是破坏性的，默认关闭。** disabled 模式下 rollup-boost 停止向
builder 发送所有请求（含 FCU 和 newPayload），op-rbuilder 会彻底脱离链；而它在本拓扑里
没有 P2P 回填，恢复后拿不到缺失区块，链头会永久卡住。实测 12 秒演练就让它落后 30+ 块且
无法自愈，只能走一遍完整的 `off → switch-to-flashblocks-dryrun.sh` 重建。
默认的降级验证改为翻既有日志，核对每次 builder 失败是否都对应一个 `context=l2` 的出块，
不需要人为制造故障。

**fixtures/ 下是 p2-txs.sh 用的测试合约**，一个独立的最小 foundry 工程，
首次运行会由 `forge build` 生成 `out/`（已 gitignore）。
