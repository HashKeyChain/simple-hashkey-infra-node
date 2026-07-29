# Flashblocks 本地接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use hsk-superpowers:subagent-driven-development (recommended) or hsk-superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在已部署的本地 Jovian 链（`local-mainnet`）上，以 off→dry_run→enabled 三档、可回退地接入 flashblocks（rollup-boost + op-rbuilder + ws-proxy + op-reth RPC 副本），并跑通本地验证门。

**Architecture:** 复用现有链与 `config/local-mainnet/`，**不重新部署**。新增 1 个构建脚本 + 5 个纯组件启动器（放 `scripts/chain-ops/`），并给 `chain-start.sh`/`chain-stop.sh`/`run-op-node.sh`/`build-binaries.sh`/`chain-reset.sh`/`.envrc` 打补丁。三个 Rust 组件（rollup-boost / op-rbuilder / reth）已是根目录 submodule，从源码自编到 `bin/`。模式切换用 `.envrc` 的 `FLASHBLOCKS_MODE` 作启动初值 + rollup-boost `debug set-execution-mode` 运行时热切。

**Tech Stack:** Bash + direnv(`.envrc`)、git submodule、Rust/cargo（rollup-boost@v0.7.11 / op-rbuilder@v0.2.13 / op-reth from reth@v1.9.3）、OP Stack（op-node cgt-jovian/v1.16.5、op-geth v1.101605.0）、Foundry `cast`（验证）。Target：本地 anvil L1 + `local-mainnet` L2（Jovian 世代、CGT、Fault Proof）。

**权威设计来源：** `doc/flashblocks_local_impl.md`（组件/端口/拓扑/验证门的唯一真源）。本计划把它拆成可执行的 bite-sized 任务。

**重要约束（落地前必读）：**
- **版本世代锁 Jovian**：submodule 分别钉 `v0.7.11 / v0.2.13 / v1.9.3`，切勿用 main（已 Karst 代，Engine API V5，与 op-node v1.16.5 不兼容）。
- **flag 名以各 submodule 对应 tag 的 `--help` 为准**——本计划给的 flag 是代表值，每个启动器落地时先 `--help` 校准（尤其 reth 系 `--flashblocks*`、rollup-boost `--flashblocks*`/`--debug-server-port`）。
- **无单元测试框架**：本计划的"测试"= 脚本语法检查（`bash -n`）+ 二进制 `--help` 冒烟 + 运行期验证门（P0–P5 的 `cast`/日志断言）。
- **JWT 全链路复用** `data/op-geth/jwt.txt`。
- **commit 全部人工**：本计划所有 `git add`/`git commit` 步骤仅供参考，**执行代理禁止自动提交**，改完停下由用户自行 commit。

---

## 前置条件：Jovian 链已就绪（不由本计划部署）

本计划**复用**一条已按 Jovian 起好的本地链，不负责部署。起链入口（一键脚本，`8d36a55` 加入、`0395bf3` "style" 提交误删、现已从 git 恢复）：

```bash
bash scripts/build-binaries.sh                                    # 编译（bin/ 已有可跳过）
FLASHBLOCKS_MODE=off bash scripts/deploy-chain/deploy-jovian-chain.sh local --reset -y
```

该脚本内部：`chain-reset → 归零到纯 fjord → chain-setup → chain-start → 按 L2 墙钟计算 granite..jovian 激活时间写回 .envrc → activate-fork → 等待并断言 isJovian()==true`。支持 `--target=`（默认 jovian）/`--pace=`/`--lead=`。

> 等价手动流程（若不用一键脚本；权威见 `doc/chain-lifecycle.md`）：`chain-reset.sh` → `chain-setup.sh` → `chain-ops/chain-start.sh`。注意一键脚本采用"纯 fjord 部署 + 时间激活"路径，而非直接烘焙全部 fork 时间。

**就绪判据**（进入 Task 1 前必须全绿）：
- `config/local-mainnet/{genesis.json,rollup.json,artifact.json}` 均存在。
- `cast bn --rpc-url http://localhost:8645` 区块号在增长（off 态链在出块）。
- 链已是 Jovian：`cast call 0x420000000000000000000000000000000000000F "isJovian()(bool)" --rpc-url http://localhost:8645` 返回 `true`；且 FP（proposer/challenger）无异常。

---

## 文件结构（先锁定边界）

| 动作 | 路径 | 职责 |
|---|---|---|
| Modify | `.envrc` | 追加 flashblocks 端口/模式/REF 变量 |
| Create | `scripts/flashblocks/build-flashblocks.sh` | 从 3 个 submodule 源码自编 Rust 组件到 `bin/` |
| Modify | `scripts/build-binaries.sh` | 末尾在 `FLASHBLOCKS_MODE != off` 时可选调 build-flashblocks |
| Create | `scripts/flashblocks/run-op-rbuilder.sh` | 纯启动器：op-rbuilder（builder） |
| Create | `scripts/flashblocks/run-rollup-boost.sh` | 纯启动器：rollup-boost（含 debug server） |
| Create | `scripts/flashblocks/run-flashblocks-proxy.sh` | 纯启动器：ws-proxy |
| Create | `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh` | 纯启动器：op-reth（flashblocks RPC） |
| Create | `scripts/flashblocks/run-flashblocks-rpc-op-node.sh` | 纯启动器：verifier op-node（驱动 op-reth） |
| Modify | `scripts/chain-ops/run-op-node.sh:22` | `--l2` 按 `FLASHBLOCKS_MODE` 切 8651↔8551 |
| Modify | `scripts/chain-ops/chain-start.sh` | 按模式拉起新组件 |
| Modify | `scripts/chain-ops/chain-stop.sh` | 停列表补 5 个新组件 |
| Modify | `scripts/deploy-chain/chain-reset.sh` | `--reset` 清 `data/op-rbuilder`、`data/op-reth` |

**启动器统一模板**（照抄现有 `run-op-node.sh`）：`source .envrc` → `_CALLER_*` 覆盖回落 `.envrc`/默认 → `exec <bin> ...`，不自算 `BASE_PATH`。

---

## Task 1: `.envrc` 追加 flashblocks 变量

**Files:**
- Modify: `.envrc`（在末尾追加）

- [ ] **Step 1: 追加变量块**

在 `.envrc` 末尾追加：

```bash
# ===== Flashblocks（本地验证）=====
# off / dry_run / enabled —— 启动初值（决定起哪些组件 + rollup-boost 初始 execution-mode）
export FLASHBLOCKS_MODE=off

export RB_ENGINE_PORT=8551          # rollup-boost Engine（op-node 连这里）
export RB_FLASHBLOCKS_WS_PORT=1112  # rollup-boost 对外 flashblocks 广播
export RB_DEBUG_PORT=5555           # rollup-boost debug server（set-execution-mode 热切）
export RBUILDER_AUTHRPC_PORT=8661
export RBUILDER_HTTP_PORT=8663
export RBUILDER_WS_PORT=8664
export RBUILDER_FB_WS_PORT=1111     # op-rbuilder → rollup-boost 的 flashblocks 出口
export FB_PROXY_PORT=1113           # ws-proxy 对外
export FB_RPC_HTTP_PORT=8745        # op-reth 对用户
export FB_RPC_AUTHRPC_PORT=8751     # op-reth Engine（被 verifier op-node 驱动）
export FB_RPC_OPNODE_PORT=9555      # verifier op-node RPC

# Rust 组件（submodule，锁 tag）
export ROLLUP_BOOST_REF=v0.7.11
export OP_RBUILDER_REF=v0.2.13
export OP_RETH_REF=v1.9.3
```

- [ ] **Step 2: 校验 direnv 加载**

Run: `cd /Users/zhuangqianwei/github.com/HashKeyChain/simple-hashkey-infra-node && source .envrc && echo "$FLASHBLOCKS_MODE $RB_ENGINE_PORT $RB_DEBUG_PORT $OP_RETH_REF"`
Expected: `off 8551 5555 v1.9.3`

- [ ] **Step 3: 端口冲突自检**

Run: `for p in 8551 1112 5555 8661 8663 8664 1111 1113 8745 8751 9555; do lsof -iTCP:$p -sTCP:LISTEN -n -P >/dev/null 2>&1 && echo "PORT $p BUSY" || true; done; echo done`
Expected: `done`（无 BUSY 行；若有，改对应变量避让）

- [ ] **Step 4: 交由用户提交（注意 `.envrc` 已被 gitignore）**

`.envrc` 在 `.gitignore` 中（含私钥），本地改动**不会也不应进版本库**。若需让团队共享这些 flashblocks 变量，把变量块同步写入已跟踪的 `.envrc.local.example` 后由**你自己** commit；`.envrc` 本身仅本地修改。本步骤不执行任何 git 操作。

---

## Task 2: `scripts/flashblocks/build-flashblocks.sh`（submodule 源码自编）

**Files:**
- Create: `scripts/flashblocks/build-flashblocks.sh`

- [ ] **Step 1: 确认 submodule 已就位并钉在 tag**

Run: `git submodule status rollup-boost op-rbuilder reth`
Expected: 三行，每行前带对应 tag（`v0.7.11` / `v0.2.13` / `v1.9.3`）或其 commit。若显示 `-`（未 init），先 `git submodule update --init rollup-boost op-rbuilder reth`。

- [ ] **Step 2: 写脚本**（内容取自 `doc/flashblocks_local_impl.md` §6.2）

```bash
#!/bin/bash
# 编译 flashblocks 相关 Rust 组件到 bin/（需 rust toolchain）。首次较慢（reth 依赖重）。
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy（同 submodule、同 tag）
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/websocket-proxy "$BASE_PATH/bin/flashblocks-ws-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# op-reth（reth submodule 的 bin target）
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"

"$BASE_PATH/bin/op-reth" node --help | grep -q flashblocks && echo "op-reth: flashblocks flag OK"
cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
```

- [ ] **Step 3: 语法检查**

Run: `bash -n scripts/flashblocks/build-flashblocks.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: 执行构建（耗时长，后台跑）**

Run: `chmod +x scripts/flashblocks/build-flashblocks.sh && bash scripts/flashblocks/build-flashblocks.sh`
Expected: 末尾出现 `op-reth: flashblocks flag OK` 与 `Flashblocks binaries built into bin/`；`bin/` 下出现 `rollup-boost`、`flashblocks-ws-proxy`、`op-rbuilder`、`op-reth`。
> 若 `cargo build` 报 flag/依赖错，多为 tag 与本机 rust 版本不匹配——按 submodule 的 `rust-toolchain.toml` 装对应 toolchain。

- [ ] **Step 5: 四个二进制冒烟**

Run: `for b in rollup-boost flashblocks-ws-proxy op-rbuilder op-reth; do echo "== $b =="; bin/$b --help >/dev/null 2>&1 && echo ok || echo FAIL; done`
Expected: 四个都 `ok`。

- [ ] **Step 6: Commit**

```bash
git add scripts/flashblocks/build-flashblocks.sh
git commit -m "feat(flashblocks): add build-flashblocks.sh (submodule source build)"
```

---

## Task 3: `build-binaries.sh` 可选联动

**Files:**
- Modify: `scripts/build-binaries.sh`（末尾 `cd $BASE_PATH` 之前）

- [ ] **Step 1: 追加联动**

在 `scripts/build-binaries.sh` 末尾 `# return base path` 之前插入：

```bash
# ---------- flashblocks Rust 组件（仅 FLASHBLOCKS_MODE != off）----------
if [ "${FLASHBLOCKS_MODE:-off}" != "off" ]; then
  bash "$BASE_PATH/scripts/flashblocks/build-flashblocks.sh"
fi
```

- [ ] **Step 2: 语法检查**

Run: `bash -n scripts/build-binaries.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: off 态不触发**

Run: `FLASHBLOCKS_MODE=off bash -c 'source .envrc; grep -q flashblocks scripts/build-binaries.sh && echo hooked'`
Expected: `hooked`（仅确认代码在；off 时不会调用）

- [ ] **Step 4: Commit**

```bash
git add scripts/build-binaries.sh
git commit -m "feat(flashblocks): optionally build rust comps from build-binaries"
```

---

## Task 4: `scripts/flashblocks/run-op-rbuilder.sh`

**Files:**
- Create: `scripts/flashblocks/run-op-rbuilder.sh`

- [ ] **Step 1: 写启动器**（内容取自 impl §6.3；flag 以 `bin/op-rbuilder node --help` 校准）

```bash
#!/bin/bash
# op-rbuilder：reth 系 flashblocks builder。用与 op-geth 相同 genesis。
# 不需要单独 builder op-node —— 由 rollup-boost 转发主 op-node 的 Engine 调用驱动。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/genesis.json}"
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

- [ ] **Step 2: 语法检查 + flag 校准**

Run: `bash -n scripts/flashblocks/run-op-rbuilder.sh && echo OK && bin/op-rbuilder node --help | grep -E 'flashblocks|sequencer-http' | head`
Expected: `OK`，且能看到脚本用到的 flashblocks/sequencer flag（名字不符则按 `--help` 改脚本）。

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-op-rbuilder.sh
git commit -m "feat(flashblocks): add run-op-rbuilder launcher"
```

---

## Task 5: `scripts/flashblocks/run-rollup-boost.sh`

**Files:**
- Create: `scripts/flashblocks/run-rollup-boost.sh`

- [ ] **Step 1: 写启动器**（impl §6.4；含 debug server）

```bash
#!/bin/bash
# rollup-boost：op-node ↔ (op-geth fallback + op-rbuilder builder) 的 Engine 代理。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"

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

- [ ] **Step 2: 语法检查 + flag 校准**

Run: `bash -n scripts/flashblocks/run-rollup-boost.sh && echo OK && bin/rollup-boost --help | grep -E 'flashblocks|execution-mode|debug-server-port|builder-url' | head`
Expected: `OK`，flag 名一致（不一致按 `--help` 改）。

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-rollup-boost.sh
git commit -m "feat(flashblocks): add run-rollup-boost launcher"
```

---

## Task 6: `scripts/flashblocks/run-flashblocks-proxy.sh`

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-proxy.sh`

- [ ] **Step 1: 写启动器**（impl §6.5）

```bash
#!/bin/bash
# 订阅 rollup-boost 的 flashblocks 广播，对用户侧扇出。
source .envrc
exec flashblocks-ws-proxy \
  --upstream-ws ws://localhost:"$RB_FLASHBLOCKS_WS_PORT" \
  --listen-addr 0.0.0.0:"$FB_PROXY_PORT"
```

- [ ] **Step 2: 语法检查 + flag 校准**

Run: `bash -n scripts/flashblocks/run-flashblocks-proxy.sh && echo OK && bin/flashblocks-ws-proxy --help | grep -E 'upstream|listen' | head`
Expected: `OK`，flag 名一致。

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-proxy.sh
git commit -m "feat(flashblocks): add run-flashblocks-proxy launcher"
```

---

## Task 7: `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh`（op-reth）

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-rpc-op-reth.sh`

- [ ] **Step 1: 写启动器**（impl §6.6；`--flashblocks-url` 订阅 ws-proxy，本地用 `ws://`）

```bash
#!/bin/bash
# flashblocks-aware RPC：op-reth 订阅 ws-proxy 的 flashblocks，对外提供 pending。
# 由 run-flashblocks-rpc-op-node.sh 通过 Engine API 驱动同步 canonical 链。
source .envrc
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
GENESIS="${_CALLER_OP_GETH_GENESIS_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/genesis.json}"
DATADIR="$BASE_PATH/data/op-reth"
mkdir -p "$DATADIR"

exec op-reth node \
  --chain "$GENESIS" --datadir "$DATADIR" \
  --authrpc.addr 0.0.0.0 --authrpc.port "$FB_RPC_AUTHRPC_PORT" --authrpc.jwtsecret "$JWT_FILE" \
  --http --http.addr 0.0.0.0 --http.port "$FB_RPC_HTTP_PORT" --http.api eth,web3,net,debug \
  --rollup.sequencer-http "$L2_RPC_URL" \
  --flashblocks-url ws://localhost:"$FB_PROXY_PORT"
```

- [ ] **Step 2: 语法检查 + flag 校准**

Run: `bash -n scripts/flashblocks/run-flashblocks-rpc-op-reth.sh && echo OK && bin/op-reth node --help | grep -E 'flashblocks-url|sequencer-http|authrpc' | head`
Expected: `OK`，flag 名一致。

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-rpc-op-reth.sh
git commit -m "feat(flashblocks): add run-op-reth launcher (op-reth)"
```

---

## Task 8: `scripts/flashblocks/run-flashblocks-rpc-op-node.sh`（verifier op-node）

**Files:**
- Create: `scripts/flashblocks/run-flashblocks-rpc-op-node.sh`

- [ ] **Step 1: 写启动器**（impl §6.6b；只读副本、不出块、`--l2.enginekind=reth`）

```bash
#!/bin/bash
# RPC 副本的 verifier op-node：不出块，只通过 Engine API 驱动 op-reth 同步 canonical 链。
source .envrc
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"

exec op-node \
  --log.level=info --rpc.addr=0.0.0.0 --rpc.port="$FB_RPC_OPNODE_PORT" \
  --l1="$L1_RPC_URL" --l1.rpckind="$L1_RPC_KIND" --l1.beacon.ignore \
  --l2=http://localhost:"$FB_RPC_AUTHRPC_PORT" --l2.jwt-secret="$JWT_FILE" \
  --l2.enginekind=reth \
  --rollup.config="$ROLLUP_FILE" --p2p.disable
```

- [ ] **Step 2: 语法检查 + flag 校准**

Run: `bash -n scripts/flashblocks/run-flashblocks-rpc-op-node.sh && echo OK && bin/op-node --help 2>&1 | grep -E 'enginekind|beacon.ignore' | head`
Expected: `OK`；确认本地 op-node 版本支持 `--l2.enginekind=reth`（不支持则去掉该 flag）。

- [ ] **Step 3: Commit**

```bash
git add scripts/flashblocks/run-flashblocks-rpc-op-node.sh
git commit -m "feat(flashblocks): add run-flashblocks-rpc-op-node launcher (verifier)"
```

---

## Task 9: 改 `scripts/chain-ops/run-op-node.sh`（`--l2` 按模式切换）

**Files:**
- Modify: `scripts/chain-ops/run-op-node.sh:22`

- [ ] **Step 1: 替换第 22 行 base_flags**

把（第 22 行）：
```bash
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=http://localhost:8651 --l2.jwt-secret=$JWT_FILE"
```
改为：
```bash
# FLASHBLOCKS_MODE=off → 直连 op-geth(8651)；否则走 rollup-boost(RB_ENGINE_PORT)
if [ "${FLASHBLOCKS_MODE:-off}" = "off" ]; then
  L2_ENGINE_URL="http://localhost:8651"
else
  L2_ENGINE_URL="http://localhost:${RB_ENGINE_PORT:-8551}"
fi
base_flags="--log.level=info --rpc.addr=0.0.0.0 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
```

- [ ] **Step 2: 语法检查 + 双模式回显**

Run: `bash -n scripts/chain-ops/run-op-node.sh && echo OK && FLASHBLOCKS_MODE=off bash -c 'source .envrc; source <(sed -n "12,25p" scripts/chain-ops/run-op-node.sh); echo off=$L2_ENGINE_URL' 2>/dev/null; FLASHBLOCKS_MODE=dry_run bash -c 'source .envrc; source <(sed -n "12,25p" scripts/chain-ops/run-op-node.sh); echo dry=$L2_ENGINE_URL' 2>/dev/null`
Expected: `OK`、`off=http://localhost:8651`、`dry=http://localhost:8551`。
> 若上面的 `source <(sed …)` 因脚本结构不便，改为人工检视两分支即可。

- [ ] **Step 3: off 态非回归（现链仍正常）**

Run: `bash scripts/chain-ops/chain-stop.sh; FLASHBLOCKS_MODE=off bash scripts/chain-ops/chain-start.sh local; sleep 8; cast bn --rpc-url http://localhost:8645`
Expected: 区块号在增长（off 态链路完全没变）。

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/run-op-node.sh
git commit -m "feat(flashblocks): switch op-node --l2 target by FLASHBLOCKS_MODE"
```

---

## Task 10: 改 `scripts/chain-ops/chain-start.sh`（按模式拉起新组件）

**Files:**
- Modify: `scripts/chain-ops/chain-start.sh`

- [ ] **Step 1: 序列器侧组件（op-geth 之后、op-node 之前）**

在"启动 op-node"（`echo "Starting op-node..."`）之前插入：

```bash
# ---------- Flashblocks 序列器侧（FLASHBLOCKS_MODE != off）----------
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

- [ ] **Step 2: 用户面组件（脚本末尾，enabled 时）**

在"All services started"提示之前插入：

```bash
# ---------- Flashblocks 用户面（enabled；本地=生产同构，proxy 不省略）----------
if [ "${FLASHBLOCKS_MODE:-off}" = "enabled" ] && [ "${SKIP_FB_USER:-0}" != "1" ]; then
  echo "Starting flashblocks ws-proxy..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-proxy.sh" >> "$LOG_DIR/fb-proxy.log" 2>&1 &
  echo $! > "$PID_DIR/fb-proxy.pid"; sleep 1
  echo "Starting flashblocks-aware RPC (op-reth)..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-reth.sh" >> "$LOG_DIR/fb-rpc-reth.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-reth.pid"; sleep 2
  echo "Starting flashblocks RPC verifier op-node..."
  nohup bash "$SCRIPT_DIR/run-flashblocks-rpc-op-node.sh" >> "$LOG_DIR/fb-rpc-opnode.log" 2>&1 &
  echo $! > "$PID_DIR/fb-rpc-opnode.pid"
fi
```

- [ ] **Step 3: 语法检查**

Run: `bash -n scripts/chain-ops/chain-start.sh && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/chain-start.sh
git commit -m "feat(flashblocks): start rust comps by FLASHBLOCKS_MODE"
```

---

## Task 11: 改 `scripts/chain-ops/chain-stop.sh`（一并停）

**Files:**
- Modify: `scripts/chain-ops/chain-stop.sh`

- [ ] **Step 1: PID 停止列表加新组件**

把：
```bash
for name in op-challenger op-proposer op-batcher op-node op-geth; do
```
改为：
```bash
for name in fb-rpc-opnode fb-rpc-reth fb-proxy rollup-boost op-rbuilder op-challenger op-proposer op-batcher op-node op-geth; do
```

- [ ] **Step 2: 追加 stop_matching_processes（在 op-geth 那行之前）**

```bash
stop_matching_processes "fb-rpc-opnode"    "op-node "        "--rpc.port=${FB_RPC_OPNODE_PORT:-9555}"
stop_matching_processes "fb-rpc-reth"       "op-reth "        "--datadir=$DATA_DIR/op-reth"
stop_matching_processes "fb-proxy"     "flashblocks-ws-proxy " "0.0.0.0:${FB_PROXY_PORT:-1113}"
stop_matching_processes "op-rbuilder"  "op-rbuilder "    "--datadir=$DATA_DIR/op-rbuilder"
stop_matching_processes "rollup-boost" "rollup-boost "   "--rpc-port ${RB_ENGINE_PORT:-8551}"
```
> 注：`stop_matching_processes` 需 `.envrc` 里的端口变量，脚本已 `source .envrc`（若没有则在文件头补 `source .envrc`）。needle 以实际进程 `ps` 命令行为准，落地时用 `ps axww | grep` 核对。

- [ ] **Step 3: 语法检查 + 冒烟**

Run: `bash -n scripts/chain-ops/chain-stop.sh && echo OK && bash scripts/chain-ops/chain-stop.sh`
Expected: `OK`；随后正常打印 Stopped/Done，无报错。

- [ ] **Step 4: Commit**

```bash
git add scripts/chain-ops/chain-stop.sh
git commit -m "feat(flashblocks): stop rust comps in chain-stop"
```

---

## Task 12: `chain-reset.sh` —— 无需改动（仅验证）

**结论：不改代码。** `scripts/deploy-chain/chain-reset.sh:109` 是 `rm -rf "$DATA_DIR"`（整个 `data/` 目录），`data/op-rbuilder`、`data/op-reth` 作为其子目录会被**自动清除**，无需加入白名单。

- [ ] **Step 1: 确认 reset 是整目录删除**

Run: `grep -n 'rm -rf' scripts/deploy-chain/chain-reset.sh`
Expected: 命中 `rm -rf "$DATA_DIR"`（`DATA_DIR="$BASE_PATH/data"`）。据此确认新数据目录已覆盖，本任务无改动、无提交。

---

## 验证门（P0–P5，逐门放行；对应 impl §7）

> 这些是本计划的"集成测试"。上一门不过不进下一门。

## Task V0: P0 — 编译 + chain spec 加载 + 创世对齐

- [ ] **Step 1: 二进制齐全**（Task 2 已产出）

Run: `ls -1 bin/{rollup-boost,flashblocks-ws-proxy,op-rbuilder,op-reth}`
Expected: 四个文件都在。

- [ ] **Step 2: reth 系能解析本链 genesis**

Run: `bin/op-rbuilder node --chain config/local-mainnet/genesis.json --datadir /tmp/rb-probe --http --http.port 8663 >/tmp/rb.log 2>&1 & sleep 8; cast block 0 --rpc-url http://localhost:8663 -f hash; kill %1 2>/dev/null; rm -rf /tmp/rb-probe`
Expected: 打印创世区块 hash（能起、能解析 genesis）。若报 genesis 格式错 → 停，先解决解析/转换。

- [ ] **Step 3: 创世 hash 与 op-geth 一致**

Run: `echo geth=$(cast block 0 --rpc-url http://localhost:8645 -f hash); echo rbuilder=<上一步的 hash>`
Expected: 两者完全相等。
- **门（P0）**：reth 系加载 genesis 成功且创世 hash == op-geth。

---

## Task V1: P1 — op-rbuilder 影子同步

- [ ] **Step 1: off 链在跑 + 起 op-rbuilder 追历史**（`--rollup.sequencer-http=$L2_RPC_URL`）
- [ ] **Step 2: 逐块对照**（impl §8.1，重点 Granite/Holocene/Isthmus/Jovian 激活块 + 抽样普通块）

Run:
```bash
for BN in <granite> <holocene> <isthmus> <jovian> $(cast bn --rpc-url http://localhost:8645); do
  A=$(cast block $BN --rpc-url http://localhost:8645 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  B=$(cast block $BN --rpc-url http://localhost:8663 -j | jq -r '.hash,.stateRoot' | tr '\n' ' ')
  [ "$A" = "$B" ] && echo "OK $BN" || echo "DIFF $BN | geth=$A | rbuilder=$B"
done
```
Expected: 关键块与抽样块全 `OK`；追平链头；无 invalid block。
- **门（P1）**：零分歧。有 DIFF → 走 impl §8.4 漏斗定位。

---

## Task V2: P2 — dry_run

- [ ] **Step 1: 切 dry_run 重启**

Run: `sed -i '' 's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=dry_run/' .envrc && source .envrc && bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local`
Expected: op-rbuilder + rollup-boost 起来；op-node `--l2` 指向 8551；2s 正常出块。

- [ ] **Step 2: 覆盖场景**：普通转账 / 合约调用 / 失败交易 / CGT gas / deposit / withdrawal / L1 origin 切换。
- [ ] **Step 3: 断言 VALID**

Run: `grep -iE 'invalid payload|VALID' data/logs/rollup-boost.log | tail -50`
Expected: builder payload 全 `VALID`，`Invalid payload = 0`；batcher/proposer/challenger 无异常。
- **门（P2）**：dry_run 分歧计数为 0。

---

## Task V3: P3 — enabled + flashblocks 产出

- [ ] **Step 1: 进入 enabled（二选一）**
  - 热切：`bin/rollup-boost debug set-execution-mode enabled`（连 `RB_DEBUG_PORT`），或 `curl` `debug_setExecutionMode`。
  - 重启：`FLASHBLOCKS_MODE=enabled` + `chain-ops` 重启。
- [ ] **Step 2: 观察 flashblocks 流**

Run: `websocat ws://localhost:1112 | head -20`（或 `ws://localhost:1113`）
Expected: 约每 250ms 一条 flashblock。

- [ ] **Step 3: builder 掉线回退演练**

Run: `bash scripts/chain-ops/chain-stop.sh 之外单独 kill op-rbuilder，观察 rollup-boost 回退到 op-geth 出块，链不中断；恢复 op-rbuilder 后 flashblocks 自动恢复`
- **门（P3）**：flashblocks 稳定产出；掉线可回退、链不中断。

---

## Task V4: P4 — 用户面（完整链路，与生产同构）

- [ ] **Step 1: enabled 已自动拉起 ws-proxy(1113) → op-reth(8745) ← verifier op-node(9555)**
- [ ] **Step 2: op-reth 追平链头**

Run: `echo reth=$(cast bn --rpc-url http://localhost:8745); echo geth=$(cast bn --rpc-url http://localhost:8645)`
Expected: 两者一致（或 reth 紧追）。

- [ ] **Step 3: op-reth 收到 flashblocks（日志无 `Error receiving flashblock`）**

Run: `grep -i flashblock data/logs/fb-rpc-reth.log | tail`
Expected: 有接收记录、无持续报错。

- [ ] **Step 4: pending 预确认可见**

Run:
```bash
cast send <to> --value 1 --rpc-url http://localhost:8645 --private-key <k> --async
cast rpc eth_getBlockByNumber pending true --rpc-url http://localhost:8745 | jq '.transactions[].hash'
```
Expected: 2s 正式块前，pending 里已见该 tx hash。
- **门（P4）**：亚秒预确认稳定；关掉 ws-proxy/op-reth/verifier op-node 任一，均不影响 Sequencer 出块。

---

## Task V5: P5 — 本地验收 + 回退演练

- [ ] **Step 1: 完整场景一轮**（功能 + FP 非回归：proposer/challenger 行为不变 + 故障回退）
- [ ] **Step 2: 硬回退验证**

Run: `sed -i '' 's/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=off/' .envrc && source .envrc && bash scripts/chain-ops/chain-stop.sh && bash scripts/chain-ops/chain-start.sh local; sleep 8; cast bn --rpc-url http://localhost:8645`
Expected: op-node 直连 op-geth(8651)，链正常出块，架构回到接入前。
- **门（P5）**：验收清单全过，具备上生产条件。

- [ ] **Step 3: 记录验收结论**（impl §11 交付物）并 Commit 验收记录（如有）。

---

## 回退策略（随时可用）

| 层级 | 操作 |
|---|---|
| 热降级（不断链） | `rollup-boost debug set-execution-mode dry-run`（RB_DEBUG_PORT） |
| 降级（重启） | `FLASHBLOCKS_MODE=dry_run` + `chain-ops` 重启 |
| 绕过 sidecar | `FLASHBLOCKS_MODE=off` + `chain-ops` 重启（op-node 直连 8651） |
| 用户面单独关 | `SKIP_FB_USER=1` 或停 fb-proxy/fb-rpc-reth/fb-rpc-opnode |

---

## Notes / 风险（落地时盯，详见 impl §10）
- **版本世代**：submodule 必须停在 `v0.7.11 / v0.2.13 / v1.9.3`，别 checkout 到 main。
- **CGT 兼容性无官方保证**：靠 P2 dry_run 的 VALID 实证。
- **genesis/JWT 一致**是一切对照前提。
- **op-reth `wss://` TLS**：本地全程 `ws://`。
- **flag 名随版本变**：每个启动器落地先 `--help` 校准。
- **commit 由人工执行**：本计划中所有 `git commit`/`git add` 步骤仅供参考。执行代理（含 subagent）**禁止自动运行任何 git 提交**；每个任务改完做完语法/冒烟检查后停下，由用户自行提交。
