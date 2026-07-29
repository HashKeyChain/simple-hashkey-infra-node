# 本地接入 Flashblocks 实现方案（simple 项目）

> 范围：只覆盖**本地私网验证**。基于 `scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y`
> 部署好的 Jovian 链（复用其 `config/local-mainnet/`，**不重新部署链**），用 `scripts/chain-ops/chain-start.sh`
> 启动服务，在本机把 rollup-boost + op-rbuilder + flashblocks-websocket-proxy + flashblocks-aware RPC 接进去并验证。
> 不改现有 op-node / op-geth / 合约代码。
>
> **flashblocks 不重新部署链**：它只改变"起哪些服务 + op-node 的 `--l2` 指向"。启动流程 =
> `build-flashblocks.sh`（编译）→ 设 `.envrc` 的 `FLASHBLOCKS_MODE` → `chain-ops/chain-stop.sh && chain-ops/chain-start.sh local`。
>
> **本地=生产同构原则**：本地验证的组件、拓扑、数据流、启用顺序（off→dry_run→enabled）
> 与将来生产上线**完全一致**，只在规模上不同（单机、单 Sequencer、无 op-conductor/HA）。
> 因此 **flashblocks-websocket-proxy 不省略**——即使本地只有一个 RPC 消费者，也保留
> `op-rbuilder → rollup-boost → ws-proxy → flashblocks-aware RPC` 这条完整链路，
> 保证本地跑通的就是生产要跑的。op-conductor 是生产 HA 才需要，本地不引入，但它不改变这条数据流。

---

## 1. 目标

在保持现有链不变（Legacy CGT、Jovian 分叉、2s 正式块、单 Sequencer、Fault Proof）的前提下：

1. 用 rollup-boost 作为 op-node 与执行层之间的 Engine API 代理。
2. 用 op-rbuilder（reth 系）作为 flashblocks 区块构建器，产出 ~200ms 预确认。
3. 保留现有 **op-geth 作为 canonical fallback + payload 校验基准**。
4. 通过 `off → dry_run → enabled` 三档，逐步验证到用户可见 `pending` 预确认。

最终本地目标架构：

```text
序列器侧                                        用户面（RPC 副本，与生产同构）
                  ┌─ op-geth(8651) canonical fallback + VALID 校验
op-node ─Engine─> rollup-boost(8551)
                  └─ op-rbuilder(8661) builder + 200ms flashblocks
                         │ flashblocks 出口 ws(1111)
                         ▼
                  rollup-boost 广播(1112) ─> ws-proxy(1113) ─> op-reth(8745, --flashblocks-url)
                                                                    ▲ Engine(8751)
                                                                    │
                                                          verifier op-node(9555, 不出块)
                                                                    │
                                                              用户查 pending
```

---

## 2. 现状：现有端口与链路（不要动）

| 组件 | 端口 | 说明 |
|---|---|---|
| anvil (L1) | 8545 | 本地 L1 |
| op-geth HTTP | 8645 | `L2_RPC_URL` |
| op-geth WS | 8646 | |
| op-geth Engine (authrpc) | 8651 | op-node 当前 `--l2` 指向这里 |
| op-node rollup RPC | 9545 | `OP_ROLLUP_PORT` |
| op-batcher RPC | 9645 | |
| op-proposer RPC | 8560 | |

现有关键接线（`scripts/chain-ops/run-op-node.sh` 第 22 行）：

```text
op-node --l2=http://localhost:8651  --l2.jwt-secret=$JWT_FILE
```

**接入 flashblocks 只改这一根线**：把 op-node 的 `--l2` 从 op-geth(8651) 改指到 rollup-boost(8551)，其余组件不动。

---

## 3. 目标：新增组件与端口分配

新增端口（本地可自定，避开已用端口即可）：

| 新组件 | 端口 | 说明 |
|---|---|---|
| rollup-boost Engine（op-node 连这里） | 8551 | 对上游 op-node 暴露 Engine API |
| rollup-boost flashblocks 广播 WS | 1112 | 对外 flashblocks 流 |
| op-rbuilder Engine (authrpc) | 8661 | rollup-boost 的 builder-url |
| op-rbuilder HTTP | 8663 | reth RPC（同步/调试/对照用） |
| op-rbuilder WS | 8664 | |
| op-rbuilder flashblocks 出口 WS | 1111 | op-rbuilder → rollup-boost |
| flashblocks-websocket-proxy 对外 | 1113 | 用户/RPC 订阅入口 |
| flashblocks-aware RPC (op-reth) HTTP | 8745 | 对用户提供 `pending` 预确认 |
| flashblocks-aware RPC (op-reth) Engine authrpc | 8751 | 被其 verifier op-node 驱动 |
| RPC 副本 verifier op-node RPC | 9555 | 驱动上面的 op-reth（不出块，仅同步）|

**JWT 全链路复用同一个** `data/op-geth/jwt.txt`：op-node ↔ rollup-boost ↔ (op-geth, op-rbuilder)，
以及 RPC 副本的 verifier op-node ↔ op-reth 都用它。

> **RPC 副本为什么是 op-node + op-reth 一对**：op-reth 是纯执行层，自己不能从 L1 派生链，
> 必须由一个 op-node（verifier 模式、不出块）通过 Engine API 驱动它同步 canonical 链；
> op-reth 再叠加 flashblocks 流算出 `pending`。生产的 flashblocks RPC 节点就是这个结构，
> 本地照搬，保证同构。

---

## 4. 组件与版本（已锁定 Jovian 世代）

Rust 组件需另行拉源码 + 编译（当前 `bin/` 只有 Go 组件）。

**交付策略：全部 fork 到 `HSKChain` 后从源码自编**（供应链自主可控 / 可审计）。
**三个 fork 已作为 git submodule 加入本仓库根目录**：`rollup-boost` / `op-rbuilder` / `reth`
（与 `optimism` / `op-geth` 两个既有 submodule 并列）。下表"上游源"是 fork 的来源，
编译一律进对应 submodule 目录、`fetch_and_checkout $REF` 后 `cargo build`（与 `build-binaries.sh` 同风格），不再 `git clone`。

**版本世代必须与本链对齐**：本链是 **Jovian 世代、未上 Karst**（op-node `cgt-jovian/v1.16.5`、
op-geth `v1.101605.0`）。所有新组件**锁在 Jovian 世代**，不能追最新——最新版都已进入
Karst / Engine API V5（`getPayloadV5`）世代，要求 op-node ≥ v1.19.1，与本链不兼容。

| 组件 | 上游源 → fork 仓库 | 版本(tag) | 为什么是这个版本 |
|---|---|---|---|
| rollup-boost | `flashbots/rollup-boost` → `HSKChain/rollup-boost` | **v0.7.11** | 官方 Jovian（Upgrade 17）钉的版本；内部 reth 依赖升 1.9.3，修正 Jovian 下 payload id 计算。不用 v0.7.16（Karst/PayloadVersion V5）。 |
| op-rbuilder | `flashbots/op-rbuilder` → `HSKChain/op-rbuilder`（reth 系） | **v0.2.13** | 官方 Jovian 钉的版本；v0.2.11 不兼容 Jovian（flashblocks payload 缺 blob gas used），v0.2.12 起 Jovian ready，v0.2.13 推荐。不用 0.4.x（reth 2.3.x/Karst）。 |
| flashblocks-aware RPC（op-reth） | `paradigmxyz/reth` → `HSKChain/reth` | **v1.9.3** | 官方 Jovian 表：普通节点 v1.9.2，**跑 flashblocks 用 v1.9.3**。flashblocks 为 op-reth **原生内置**（`--flashblocks-url`），**不需要 base 的 fork**。op-reth 是 reth 的 bin target（`--bin op-reth`）。不用 v2.3.x（Karst/getPayloadV5）。 |
| flashblocks-websocket-proxy | 同 `HSKChain/rollup-boost`（仓库内 `crates/websocket-proxy`） | **v0.7.11**（与 rollup-boost 同仓库同 tag） | ⚠️ **不要用 `base/flashblocks-websocket-proxy`**：该独立仓库 2025-05 已归档，代码并入 base/node monorepo。用 rollup-boost 自带的 websocket-proxy crate，同仓库同版本、Flashbots 活跃维护、天然对齐。 |

> 说明：
> - **fork 清单（共 3 个源仓库）**：`flashbots/rollup-boost@v0.7.11`、`flashbots/op-rbuilder@v0.2.13`、
>   `paradigmxyz/reth@v1.9.3`，分别 fork 为 `HSKChain/rollup-boost`、`HSKChain/op-rbuilder`、`HSKChain/reth`。
>   websocket-proxy 在 rollup-boost 仓库内（`crates/websocket-proxy`），**不单独 fork**。
> - **op-reth 从源码自编**：op-reth 的真正源码在 **`paradigmxyz/reth`**，`cargo build --release --bin op-reth`。
>   ⚠️ **不要去 `ethereum-optimism/optimism` monorepo 找 v1.9.3** —— 该 monorepo 里根本没有 v1.9.3 这个 tag
>   （op-reth 搬进 monorepo 是 Karst 世代之后的事，monorepo 里那套是 Karst 代 v2.3.x，本链不能用）。
> - flashblocks 是 op-reth 原生特性（上游 reth PR #18094），一个 `--flashblocks-url` flag 即可，无需 base/node 封装。
>   编完先 `op-reth node --help | grep flashblocks` 确认 flag 存在。
> - websocket-proxy：`v0.7.11` tag 里就含 `crates/websocket-proxy`（还含 `flashblocks-rpc`），
>   与 rollup-boost 同源同版本，**优先用它**（用 tag，别用 main —— main 已是 Karst 代）。
>   备选是 base/base（BaseHub）monorepo 的 `crates/infra/websocket-proxy`（带 Brotli 压缩 / API key 鉴权 / 限流等
>   生产特性，活跃维护，协议一致可平替），需单独拉 monorepo。归档的独立 base 仓库不再采用。
> - **版权**：rollup-boost = MIT，op-rbuilder / reth = MIT OR Apache-2.0，均允许 fork/改/编镜像/对外提供；
>   fork 后保留 LICENSE 与版权声明（Apache 另保留 NOTICE 并标注修改），对外提供用自有品牌名，勿暗示官方背书。
> - **本次决策**：走 v1.16.5 + flashbots 仓库路线，**不 rebase 到最新版**；OP monorepo（Karst 代）与整套 Karst
>   追赶为后续独立事项。版本一旦选定，私网/生产固定不变并记录 commit。

统一放到 `bin/`（与现有 Go 二进制一致）：`bin/rollup-boost`、`bin/op-rbuilder`、`bin/flashblocks-ws-proxy`、`bin/op-reth`（flashblocks RPC 用）。

---

## 5. 前置：chain-spec / genesis 一致性（最关键的一步）

op-rbuilder（reth）与 flashblocks RPC（op-reth）**必须用与 op-geth 完全相同的创世**，否则一切对照无意义。

- 现有 op-geth 用 `$DEPLOYMENT_CONFIG_PATH/genesis.json`（即 `config/$DEPLOYMENT_CONTEXT/genesis.json`，
  当前 `DEPLOYMENT_CONTEXT=local-mainnet`；`chain-ops/chain-start.sh` 导出为 `OP_GETH_GENESIS_FILE`）初始化。
- op-reth / op-rbuilder 直接 `--chain <该 genesis.json>` 加载 OP genesis。

> ⚠️ **chain spec 加载兼容性（P0 首要子门）**：reth 系（op-reth/op-rbuilder）的 `--chain` 需要 OP genesis。
> **先验证它能直接解析本链 `genesis.json`**——若报格式/字段错，需确认是否要转换（op genesis dump 格式差异），
> 这一步不过，后面创世 hash 对照无从谈起。

验收点（P0 的门）：

```bash
# op-geth 创世 hash
cast block 0 --rpc-url http://localhost:8645 -f hash
# op-rbuilder 创世 hash（起 op-rbuilder 后）
cast block 0 --rpc-url http://localhost:8663 -f hash
# 两者必须完全一致
```

若创世 hash 不一致 → 停止，先解决 genesis 解析差异（常见于 CGT / 预置合约 alloc、extraData）。

---

## 6. 脚本改造清单（贴合现有编排）

现有编排风格：`scripts/chain-ops/chain-start.sh` 用 `_CALLER_*` 下传变量，各 `scripts/chain-ops/run-op-*.sh` 是"纯组件启动器"。沿用这个风格：

- **5 个新启动器放 `scripts/chain-ops/`**（与 `run-op-geth.sh` 等并列）：`run-op-rbuilder.sh` / `run-rollup-boost.sh` / `run-flashblocks-proxy.sh` / `run-flashblocks-rpc-op-reth.sh` / `run-flashblocks-rpc-op-node.sh`，都照抄 `run-op-node.sh` 极简模板（`source .envrc` + `_CALLER_*` 覆盖 + `exec`，不自算 `BASE_PATH`）。
- **1 个构建脚本放 `scripts/flashblocks/build-flashblocks.sh`**（与 `build-binaries.sh` 并列，专管 Rust；`build-binaries.sh` 末尾在 `FLASHBLOCKS_MODE != off` 时可选调用它，实现"一键全建"）。
- **`chain-ops/chain-start.sh` 加轻量 `FLASHBLOCKS_MODE` 分支**（只决定"要不要多起几个组件"），**`chain-ops/run-op-node.sh` 按模式切 `--l2`**，`chain-ops/chain-stop.sh` 停列表补齐新组件。
- **模式切换（决策 C）**：`.envrc` 的 `FLASHBLOCKS_MODE` 作**启动初值**（决定起哪些组件 + rollup-boost 初始 execution-mode）；运行中 `dry_run↔enabled` 用 rollup-boost 的 `debug set-execution-mode`（`RB_DEBUG_PORT`）**热切**、不断链；回退硬保证仍是"改 `.envrc` + 重启"。

### 6.1 `.envrc` 追加

```bash
# ===== Flashblocks（本地验证）=====
# off      : 不接入，链路与现在完全一致（默认）
# dry_run  : op-node 走 rollup-boost；正式块仍由 op-geth 出，builder payload 只做校验对照
# enabled  : 正式采用 op-rbuilder 块，产出 200ms flashblocks
export FLASHBLOCKS_MODE=off

export RB_ENGINE_PORT=8551          # rollup-boost Engine（op-node 连这里）
export RB_FLASHBLOCKS_WS_PORT=1112  # rollup-boost 对外 flashblocks 广播
export RB_DEBUG_PORT=5555           # rollup-boost debug server（debug set-execution-mode 热切）
export RBUILDER_AUTHRPC_PORT=8661   # op-rbuilder Engine
export RBUILDER_HTTP_PORT=8663
export RBUILDER_WS_PORT=8664
export RBUILDER_FB_WS_PORT=1111     # op-rbuilder → rollup-boost 的 flashblocks 出口
export FB_PROXY_PORT=1113           # ws-proxy 对外
export FB_RPC_HTTP_PORT=8745        # flashblocks-aware RPC(op-reth) 对用户
export FB_RPC_AUTHRPC_PORT=8751     # op-reth Engine（被 verifier op-node 驱动）
export FB_RPC_OPNODE_PORT=9555      # RPC 副本 verifier op-node RPC

# Rust 组件：已作为 submodule 加入（rollup-boost / op-rbuilder / reth），从 submodule 源码自编，锁 tag
export ROLLUP_BOOST_REF=v0.7.11    # rollup-boost submodule（含 crates/websocket-proxy，一起编）
export OP_RBUILDER_REF=v0.2.13     # op-rbuilder submodule；Jovian ready（v0.2.11 不兼容 Jovian）
export OP_RETH_REF=v1.9.3          # reth submodule 的 --bin op-reth；flashblocks 内置，必须 v1.9.3
# 注：websocket-proxy 不单独 fork —— 直接用 rollup-boost submodule(ROLLUP_BOOST_REF)里的 crates/websocket-proxy
# 注：submodule 指针已钉在上述 tag；REF 仅用于 build 时 fetch_and_checkout 兜底校验
```

### 6.2 新增 `scripts/flashblocks/build-flashblocks.sh`

```bash
#!/bin/bash
# 编译 flashblocks 相关 Rust 组件到 bin/（需 rust toolchain）
# 三个组件已是 submodule，从 submodule 目录源码自编，锁 tag。首次编译较慢（reth 依赖重，建议 ≥16C/32G）。
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

# 与 build-binaries.sh 同款：在浅 submodule 里 fetch 指定 tag 并 checkout
fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

# 确保 submodule 已 checkout（首次可 git submodule update --init）
git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy（同一 submodule、同一 tag，一起编）
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/websocket-proxy "$BASE_PATH/bin/flashblocks-ws-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# （websocket-proxy 已随 rollup-boost 一起编，无需单独仓库；不要用归档的 base/flashblocks-websocket-proxy）

# op-reth（flashblocks-aware RPC）：reth submodule 的一个 bin target，只编它即可。
# ⚠️ 不要从 ethereum-optimism/optimism monorepo 找 v1.9.3 —— 那里没有该 tag（monorepo 是 Karst 代 v2.3.x）。
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"
# 校验 flashblocks flag 已编入
"$BASE_PATH/bin/op-reth" node --help | grep -q flashblocks && echo "op-reth: flashblocks flag OK"

cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
```

> - `build-binaries.sh` 末尾可加：`[ "${FLASHBLOCKS_MODE:-off}" != "off" ] && bash "$BASE_PATH/scripts/flashblocks/build-flashblocks.sh"`，实现"一键全建"；平时单独重编某个 Rust 组件直接跑本脚本即可。
> - flag/子命令名以各 submodule 对应 tag 的 `--help` 为准，本文给的是代表值。

### 6.3 新增 `scripts/flashblocks/run-op-rbuilder.sh`

> **不需要单独的 builder op-node**（已验证假设）：op-rbuilder 由 rollup-boost 转发主 op-node 的
> Engine 调用（FCU/newPayload/getPayload）来驱动，不必再配一个 builder 侧 op-node。
> （只有下游的 op-reth RPC 副本连不到 rollup-boost，才需要自己的 verifier op-node，见 §6.6b。）

```bash
#!/bin/bash
# op-rbuilder：reth 系 flashblocks builder。用与 op-geth 相同 genesis。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT/genesis.json}"
DATADIR="$BASE_PATH/data/op-rbuilder"
mkdir -p "$DATADIR"

exec op-rbuilder node \
  --chain "$GENESIS" \
  --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$RBUILDER_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$RBUILDER_HTTP_PORT" --http.api eth,web3,net,debug,txpool \
  --ws --ws.addr 0.0.0.0 --ws.port "$RBUILDER_WS_PORT" \
  --port "${RBUILDER_P2P_PORT:-30313}" \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks.enabled --flashblocks.addr 0.0.0.0 --flashblocks.port "$RBUILDER_FB_WS_PORT" \
  --flashblocks.block-time 250
```

### 6.4 新增 `scripts/flashblocks/run-rollup-boost.sh`

```bash
#!/bin/bash
# rollup-boost：op-node ↔ (op-geth fallback + op-rbuilder builder) 的 Engine 代理。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

# FLASHBLOCKS_MODE 作为「启动初值」（决策 C）：dry_run → builder 只校验不采用；enabled → 采用 builder 块。
# 起来后可调 debug server 的 debug_setExecutionMode（连 RB_DEBUG_PORT）热切、不断链。
EXEC_MODE_FLAG=""
[ "$FLASHBLOCKS_MODE" = "dry_run" ] && EXEC_MODE_FLAG="--execution-mode=dry-run"
[ "$FLASHBLOCKS_MODE" = "enabled" ] && EXEC_MODE_FLAG="--execution-mode=enabled"

exec rollup-boost \
  --rpc-addr 0.0.0.0 --rpc-port "$RB_ENGINE_PORT" \
  --jwt-path "$JWT_FILE" \
  --l2-url  http://localhost:8651 \
  --l2-jwt-path "$JWT_FILE" \
  --builder-url http://localhost:"$RBUILDER_AUTHRPC_PORT" \
  --builder-jwt-path "$JWT_FILE" \
  --flashblocks --flashblocks-builder-url ws://localhost:"$RBUILDER_FB_WS_PORT" \
  --flashblocks-addr 0.0.0.0 --flashblocks-port "$RB_FLASHBLOCKS_WS_PORT" \
  --debug-server-port "$RB_DEBUG_PORT" \
  $EXEC_MODE_FLAG
```

> 上面是方案期草稿，**实际 flag 以 `scripts/flashblocks/run-rollup-boost.sh` 为准**（v0.7.11 是
> `--rpc-host` / `--flashblocks-host`，且 `--l2-url` / `--builder-url` 必须带 `http://` scheme）。
>
> 热切（v0.7.11 **没有** `rollup-boost debug` 子命令，只能走 debug server 的 JSON-RPC）：
>
> ```bash
> curl -s -X POST -H 'Content-Type: application/json' \
>   --data '{"jsonrpc":"2.0","id":1,"method":"debug_setExecutionMode","params":[{"execution_mode":"enabled"}]}' \
>   http://localhost:$RB_DEBUG_PORT
> # 查询：debug_getExecutionMode（params 为 []）
> ```
>
> 注意大小写风格不一致：CLI flag 是 kebab-case（`--execution-mode=dry-run`），JSON-RPC 是
> snake_case（`"dry_run"`）。

### 6.5 新增 `scripts/flashblocks/run-flashblocks-proxy.sh`

```bash
#!/bin/bash
# 订阅 rollup-boost 的 flashblocks 广播，对用户侧扇出。
source .envrc
exec flashblocks-ws-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
```

### 6.6 新增 `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh`（op-reth，订阅 ws-proxy）

flashblocks 是 op-reth **原生特性**，用 `--flashblocks-url` 订阅 ws-proxy（**不是**直连 rollup-boost，
以与生产同构）。本地用 `ws://`（明文），避开 op-reth 某些构建的 `wss://` TLS 未编译问题。

```bash
#!/bin/bash
# flashblocks-aware RPC：op-reth 订阅 ws-proxy 的 flashblocks，对外提供 pending。
# 由 run-flashblocks-rpc-op-node.sh（verifier op-node）通过 Engine API 驱动同步 canonical 链。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="$BASE_PATH/config/$DEPLOYMENT_CONTEXT/genesis.json"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

exec op-reth node \
  --chain "$GENESIS" --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" \
  --http.api eth,web3,net,debug \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
  # 若要让该副本直接用 flashblocks 驱动链前进，可加 --flashblock-consensus（本地默认不加，靠下面的 verifier op-node 驱动）
```

### 6.6b 新增 `scripts/flashblocks/run-flashblocks-rpc-op-node.sh`（驱动上面 op-reth 的 verifier op-node）

```bash
#!/bin/bash
# RPC 副本的 verifier op-node：不出块，只通过 Engine API 驱动 op-reth 同步 canonical 链。
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT/rollup.json}"

exec op-node \
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$FB_RPC_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$FB_RPC_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" --p2p.disable
  # 注意：不加 --sequencer.enabled（这是只读副本，不出块）
```

### 6.7 改 `scripts/chain-ops/run-op-node.sh`：`--l2` 按模式切换

把第 22 行的固定 `--l2=http://localhost:8651` 改成按 `FLASHBLOCKS_MODE` 选择：

```bash
# FLASHBLOCKS_MODE=off → 直连 op-geth(8651)；dry_run/enabled → 走 rollup-boost(RB_ENGINE_PORT)
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:8651"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
```

### 6.8 改 `scripts/chain-ops/chain-start.sh`：按模式拉起新组件

在启动 op-geth 之后、启动 op-node 之前，插入（模式非 off 时）：

```bash
# ---------- Flashblocks 组件（FLASHBLOCKS_MODE != off）----------
export _CALLER_OP_GETH_GENESIS_FILE="$OP_GETH_GENESIS_FILE"
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  echo "Starting op-rbuilder..."
  nohup bash "$SCRIPT_DIR/run-op-rbuilder.sh" >> "$LOG_DIR/op-rbuilder.log" 2>&1 &
  echo $! > "$PID_DIR/op-rbuilder.pid"
  sleep 3
  echo "Starting rollup-boost (mode=$FLASHBLOCKS_MODE)..."
  nohup bash "$SCRIPT_DIR/run-rollup-boost.sh" >> "$LOG_DIR/rollup-boost.log" 2>&1 &
  echo $! > "$PID_DIR/rollup-boost.pid"
  sleep 2
fi
```

在最后（用户面，enabled 时）追加完整用户面链路：ws-proxy → op-reth(RPC) → 其 verifier op-node。
**本地=生产同构，proxy 不省略。**

```bash
if [ "${FLASHBLOCKS_MODE:-off}" = "enabled" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  echo "Starting flashblocks ws-proxy..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-proxy.sh" >> "$LOG_DIR/fb-proxy.log" 2>&1 &
  echo $! > "$PID_DIR/fb-proxy.pid"
  sleep 1
  echo "Starting flashblocks-aware RPC (op-reth)..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-reth.sh" >> "$LOG_DIR/fb-rpc-reth.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-reth.pid"
  sleep 2
  echo "Starting flashblocks RPC verifier op-node..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-node.sh" >> "$LOG_DIR/fb-rpc-opnode.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-opnode.pid"
fi
```

### 6.9 改 `scripts/chain-ops/chain-stop.sh`：一并停

在 `for name in ...` 列表和 `stop_matching_processes` 里补上新组件：

```bash
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder op-challenger op-proposer op-batcher op-node op-geth; do
  ...
done
stop_matching_processes "fb-rpc-opnode"    "op-node "      "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "fb-rpc-reth"       "op-reth "      "--datadir=$DATA_DIR/op-reth"
stop_matching_processes "op-rbuilder"  "op-rbuilder "  "--datadir=$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost" "rollup-boost " "--rpc-port=${RB_ENGINE_PORT:-8551}"
```

---

## 7. 分步实施与验证门（本地）

> 每一步是一个"可回退的稳定态"。上一步的验证门不过，不进下一步。

### P0 — 编译 + chain spec 加载 + 创世对齐
1. `bash scripts/flashblocks/build-flashblocks.sh` 生成 4 个 Rust 二进制到 `bin/`。
2. **验证 reth 系能解析本链 genesis**（§5 首要子门）：`op-rbuilder`/`op-reth` 用 `--chain genesis.json` 能正常起、不报格式错。
3. 单独起 op-rbuilder，比对创世 hash（见 §5）。
- **门**：reth 系成功加载 genesis；`op-rbuilder` 创世 hash == `op-geth` 创世 hash。
- **数据目录**：`data/op-rbuilder`、`data/op-reth` 要纳入 `deploy-chain/chain-reset.sh` 的清理范围（`--reset` 时一起删），避免残留旧状态污染对照。

### P1 — op-rbuilder 影子同步（surgical 切换）

**三相生命周期与 op-rbuilder 引擎驱动权**（核心不变量：op-rbuilder 的 Engine=auth RPC `RBUILDER_AUTHRPC_PORT` 同一时刻只能有一个共识驱动者）：

| 相位 | 组件 | op-rbuilder 驱动者 | op-node `--l2` |
|---|---|---|---|
| OFF | op-geth, op-node | —（无 op-rbuilder） | op-geth :8651 |
| SYNC | +op-rbuilder, +builder op-node | **builder op-node**（`--l2=…:8661`） | op-geth :8651 |
| FLASHBLOCKS(dry_run/enabled) | op-geth, op-rbuilder, rollup-boost, op-node | **rollup-boost**（`--builder-url …:8661`） | rollup-boost :8551 |

> builder op-node 与 rollup-boost 都连 op-rbuilder 的同一个 auth RPC，**不可并存**——切换时必须先停 builder op-node，再由 rollup-boost 接管。builder op-node 只用于 off 阶段“专门的同步”。

同步机制：builder op-node（`run-op-rbuilder-opnode.sh`）驱动 op-rbuilder，从 L1(anvil) 派生补历史（创世→safe head），并经 CL p2p 静态连主(sequencer) op-node（`--p2p.static`）收 unsafe gossip 跟到 unsafe head。主 op-node **始终开 CL p2p（含 off 模式）**（固定 priv key→稳定 peerID，`run-op-node.sh` 首启即生成），故 off 阶段就能把 op-rbuilder 预同步到 unsafe head。

**一键 surgical 切换（推荐）**：off 链在跑时执行
`bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local`。**op-rbuilder 只起一次、全程不杀**；切换只做“引擎驱动权交接 + op-node 重路由”，op-geth/op-rbuilder 全程不动。十步：

1. 预检（off 链在跑、op-geth/op-node 可达、主 op-node p2p 开、bin 就绪、`[9]` 重启安全窗口已到）
2. 起同步节点：op-rbuilder + builder op-node
3. 粗追平（`--lag`，默认 2）
4. `admin_stopSequencer` 冻结主 op-node 出块（进程仍在 → 仍 gossip，保存 head hash 供回滚）
5. 精追平到冻结高度 H
6. 停 builder op-node（交出 op-rbuilder 引擎驱动权）
7. 写 `.envrc` `FLASHBLOCKS_MODE=dry_run`（rollup-boost/op-node 据此读模式）
8. 起 rollup-boost（dry-run 执行模式，接管驱动 op-rbuilder）
9. 只重启主 op-node（`--l2`→rollup-boost）
10. 验证出块推进

参数：`--lag=N` / `--timeout=SEC` / `--no-wait`。任一步失败均回滚（`[3]` 停同步进程；`[5]` 起后 `admin_startSequencer` 恢复出块 + 停同步进程），链退回 off、不留半吊子。

**`[9]` 重启安全窗口**：op-node 启动时派生流水线会把 L1 读取起点回退一个 `channel_timeout`（Granite 后 50 个 L1 块，之前 300）。若落点早于 Holocene 激活块，`BatchMux` 装上 pre-Holocene 的 `BatchQueue`，而重放旧 batch 时校验函数按“batch 所在 L1 块已过 Holocene”返回 `BatchPast`——`BatchQueue` 不认识这个值，直接 `crit: unknown batch validity type: 4` 退出，每次重启都复现。新链刚起时必然踩中，需等 safe head 的 L1 origin 走到 `Holocene/Granite 边界 + channel_timeout` 之后。预检 `[1]` 会算出这个点并**自动轮询等待**（上限 `--timeout`，默认 1800s；`--no-wait` 改为直接失败退出）。等待发生在启动任何组件之前，链保持 off 不受影响。`L1_BLOCK_TIME=6` + `MAX_CHANNEL_DURATION=5` 下本地链约需 5~6 分钟。

**手动等价**：`[2]` 手动 `run-op-rbuilder.sh` + `run-op-rbuilder-opnode.sh` 追平 → `[4]` `cast rpc admin_stopSequencer` → 停 builder op-node → `run-rollup-boost.sh` → 改 `.envrc` → 重启 `run-op-node.sh`。

> 另注：完整 `chain-start`（`FLASHBLOCKS_MODE=dry_run`）会经 `start-sequencer-side.sh` 起 op-rbuilder + rollup-boost（**不起** builder op-node），op-rbuilder 由 rollup-boost/op-node 的 Engine 调用驱动同步——用于稳态重启，不是首次切换路径。

逐块对照（重点 Granite/Holocene/Isthmus/Jovian 激活块 + 若干普通块）。
- **门**：op-rbuilder 追平链头；关键块 `blockHash` / `stateRoot` 与 op-geth 一致；无 invalid block。
- 用 §8.1 对照脚本。

### P2 — dry_run
1. 一键 surgical：`bash scripts/flashblocks/switch-to-flashblocks-dryrun.sh local`（含 P1 同步 + 冻结追平 + 驱动交接，op-rbuilder 不杀）；
   或全量重启：`FLASHBLOCKS_MODE=dry_run` + `bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local`（op-rbuilder 从热 datadir 恢复）。
2. op-node 走 rollup-boost；正式块仍由 op-geth 出，builder payload 只做校验。
3. 覆盖：普通转账 / 合约调用 / 失败交易 / CGT gas 支付 / deposit / withdrawal / L1 origin 切换。
- **门**：rollup-boost 日志中 builder payload 全部 `VALID`，`Invalid payload = 0`；2s 出块不中断；batcher/proposer/challenger 无异常。
- 说明：builder 与 op-geth 选择的交易可以不同，block hash/gas 不同**不算**共识错误；只看 VALID 与否。

### P3 — enabled + flashblocks 产出
1. 两种进入方式（决策 C）：
   - **热切（推荐做演练）**：P2 的 dry_run 链在跑时，`rollup-boost debug set-execution-mode enabled`（连 `RB_DEBUG_PORT`），不断链切到采用 builder 块。
   - **重启（可复现基线）**：`FLASHBLOCKS_MODE=enabled` + `chain-ops/chain-stop.sh && chain-ops/chain-start.sh local`。
2. 正式块采用 op-rbuilder；订阅 flashblocks 流验证 ~250ms 产出（§8.2）。
- **门**：builder 块稳定落链；flashblocks 连续；停掉 op-rbuilder 时能自动回退到 op-geth 出块（§8.3 演练）。

### P4 — 用户面（完整链路，与生产同构）
1. enabled 模式已自动拉起完整用户面：`ws-proxy(1113) → op-reth(8745) ← verifier op-node(9555)`。
2. 先确认 op-reth 经其 verifier op-node 追平链头（`cast bn` on 8745 与 8645 一致）。
3. 确认 op-reth 已连上 ws-proxy 收到 flashblocks（日志无 `Error receiving flashblock`）。
4. 向 `L2_RPC_URL` 发交易，从 op-reth(8745) 查 `pending`，确认正式块前可见。
- **门**：亚秒预确认稳定；关掉 ws-proxy/op-reth/verifier op-node 任一，均不影响 Sequencer 出块。

### P5 — 本地验收
- 跑一轮完整场景（功能 + FP 非回归 + 故障回退）并记录，形成本地验收结论。

---

## 8. 验证方法（具体脚本）

### 8.1 逐块对照（op-geth vs op-rbuilder）
```bash
# 对照指定区块的 hash / stateRoot
for BN in <granite> <holocene> <isthmus> <jovian> $(cast bn --rpc-url http://localhost:8645); do
  A=$(cast block $BN --rpc-url http://localhost:8645 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  B=$(cast block $BN --rpc-url http://localhost:8663 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  [ "$A" = "$B" ] && echo "OK   $BN" || echo "DIFF $BN | geth=$A | rbuilder=$B"
done
```

### 8.2 观察 flashblocks 流
```bash
# 订阅 rollup-boost 广播（或 ws-proxy），应约每 250ms 一条
websocat ws://localhost:1112 | head -20
# 或订阅对外 proxy
websocat ws://localhost:1113 | head -20
```

### 8.3 pending 预确认验证
```bash
TX=$(cast send <to> --value 1 --rpc-url http://localhost:8645 --private-key <k> --async)
# 立刻从 flashblocks RPC 查 pending，应在 2s 正式块前就能看到该 tx
cast rpc eth_getBlockByNumber pending true --rpc-url http://localhost:8745 | jq '.transactions[].hash'
```

### 8.4 diverge 调试思路（dry_run 出现 Invalid payload 时）
1. 从 rollup-boost 日志取出被判 invalid 的 block number。
2. 用 §8.1 对照同高度 op-geth vs op-rbuilder 的 `stateRoot`。
3. 缩小到"哪一笔交易 / 哪个字段"：优先怀疑
   - Jovian `extraData` / `minBaseFee` 编码；
   - CGT 相关预置合约（L1Block / GasPriceOracle）字节码或 gas 调整；
   - Isthmus/Jovian 升级交易（type 0x7e）执行结果。
4. 定位到具体差异后，判断是 op-rbuilder 版本不支持该分叉，还是 genesis/预置状态没对齐。

---

## 9. 回退（本地）

| 层级 | 操作 | 结果 |
|---|---|---|
| builder 热降级（不断链） | `rollup-boost debug set-execution-mode dry-run`（RB_DEBUG_PORT） | 正式块立刻回到 op-geth，不重启 |
| builder 降级（重启） | `FLASHBLOCKS_MODE=dry_run` + `chain-ops` 重启 | 正式块回到 op-geth，停用户面 flashblocks |
| 绕过 sidecar | `FLASHBLOCKS_MODE=off` + `chain-ops` 重启 | op-node 直连 op-geth(8651)，架构回到接入前 |
| 用户面单独关 | `SKIP_FB_USER=1` 或停 fb-proxy/fb-rpc-reth/fb-rpc-opnode | canonical 链与 Sequencer 不受影响 |

回退双保险（决策 C）：运行中用 `debug set-execution-mode` 秒级热降级；硬回退则改 `.envrc` 的
`FLASHBLOCKS_MODE=off` + `chain-ops/chain-stop.sh && chain-ops/chain-start.sh` —— op-node 的 `--l2`
目标由 `FLASHBLOCKS_MODE` 单点决定，回退只改一个变量 + 重启，不动其它组件。

---

## 10. 风险与注意（本地阶段就要盯）

1. **版本世代必须锁 Jovian**——最大风险。已锁定 rollup-boost v0.7.11 / op-rbuilder v0.2.13 / op-reth v1.9.3；
   切勿混入 Karst 世代（0.4.x / 0.7.16 / 2.3.x），否则会引入 Engine API V5，与本链 op-node v1.16.x 不兼容。
2. **CGT 兼容性无官方保证**——你的 CGT 在合约 + op-node，op-geth 是 stock；op-rbuilder(reth) 是否同样"透明兼容"必须靠 dry_run 的 VALID 结果实证，这正是 P2 的意义。
3. **genesis 对齐**是一切对照的前提，P0 不过不要继续。
4. **JWT 一致**：op-node / rollup-boost / op-geth / op-rbuilder / 以及 RPC 副本(op-reth+verifier op-node) 必须同一个 jwt 文件。
5. **op-reth 的 `wss://` TLS**：部分 op-reth 构建未编 TLS，连 `wss://` 会报 `TLS support not compiled in`。
   本地全程用 `ws://` 不受影响；将来生产若连 `wss://` 需用已修该问题的构建。
6. flag/子命令名各仓库版本间会变，落地时以对应版本 `--help` 校准（本文给的是代表值）。

---

## 11. 交付物（本地验证）
- 4 个 Rust 二进制 + 构建 commit 记录。
- 创世/链参数一致性确认记录（P0）。
- 影子对照报告（P1）。
- dry_run VALID / Invalid payload 记录（P2）。
- flashblocks 产出与 pending 预确认记录（P3/P4）。
- 故障回退演练记录（P3）。
- 本地验收结论（P5）。
