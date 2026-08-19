# 远程验证 flashblocks

两个脚本，验的是两条不同的链路。日志类检查项全部在
`doc/flashblocks_production_runbook.md` 步骤 5/6，看日志和查 RPC 就够，不需要脚本。

下面所有命令都**在仓库根目录执行**。env 文件只写文件名不写路径：脚本会先按当前目录找，
找不到再按自己所在目录找一次。

| 脚本 | 验什么 | 要私钥 | 会发交易 |
|---|---|---|---|
| `verify.sh` | 用户发交易能不能拿到预确认 | 要 | 会 |
| `ws-verify.sh` | 对外暴露的 wss 入口能不能给外部 op-reth 用 | 不要 | 不会 |

两个都要跑，因为覆盖的路径不重叠：`verify.sh` 打的 op-reth 订阅的是**集群内网**地址
（`hsk-fullnode-reth-0` 连 `ws://hsk-flashblocks-ws-proxy-0:1113/ws`），对外那个 wss
入口多走一层 ingress，`verify.sh` 碰不到。

## verify.sh — 用户侧预确认

```bash
export FB_TEST_KEY=0x…          # 有少量余额即可

bash scripts/flashblocks/remote-verify/verify.sh env.qa       # 默认 3 笔
bash scripts/flashblocks/remote-verify/verify.sh env.qa 10
```

```
op-reth=https://qa-reth.hashkeychain.net  canonical=https://qa-cgt.hashkeychain.net  from=0x75Bf…
pending=2247948 latest=2247947
  PASS  第 1 笔预确认 1140ms，上链 2251ms，提前 1111ms（块 2247950）
```

第二行是前置检查：op-reth 收不到 flashblocks 时它的 `pending` 会**退回 `latest`**
（`reth/crates/optimism/rpc/src/eth/pending_block.rs:66`），两者相等。所以
`pending == latest + 1` 说明流正在到用户侧。这一条不通就直接退出，不浪费几十秒发交易。

单独查这个不用跑脚本：

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '[{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["pending",false]},{"jsonrpc":"2.0","id":2,"method":"eth_blockNumber","params":[]}]' \
  https://qa-reth.hashkeychain.net \
| jq -r 'map(select(.id==1))[0].result.number, map(select(.id==2))[0].result' | xargs printf 'pending=%d latest=%d\n'
```

### 阈值为什么是一个出块周期

`PRECONF_MAX_MS` 必须 ≥ 出块周期。交易随机落在出块周期的某个相位上，落在周期头部的等一片
flashblock 就到（~800ms），落在尾部的要等下一轮（~1700ms），**健康的链天生就有接近一个周期
的抖动**。设成 1000ms 会把一半正常样本判成失败。这个数还含本机到 RPC 的往返，跨区域跑要再放宽。

`GETH_RPC` 填不认 flashblocks 的客户端才能多一个判据：

| | 判据 | 能抓住 |
|---|---|---|
| 填 op-geth | `pre_ms < final_ms` 且 `pre_ms < 阈值` | flashblocks 不工作；预确认只比上链早一点点 |
| 留空／同一端点 | 只有 `pre_ms < 阈值` | flashblocks 不工作 |

同一端点时 `final_ms` 只比 `pre_ms` 大几十毫秒——那是两次 HTTP 往返，不是"比上链早多少"，
所以脚本会跳过这个对比，也不打那个误导性的"提前 Xms"。

## ws-verify.sh — 对外 wss 入口

```bash
bash scripts/flashblocks/remote-verify/ws-verify.sh env.qa        # 默认观测 10s
bash scripts/flashblocks/remote-verify/ws-verify.sh env.qa 8 -v   # -v 打每块的切片明细
```

```
ws=wss://qa-flashblocks-ws.hashkeychain.net/ws  观测 10s  出块周期 2000ms
  握手结果  HTTP 101
  数据总量  55 片 / 25226 字节，解析失败 0 片
  块号推进  5 个（2248928..2248933），期望 ≥ 4
  切片完整  0 个块序号不连续（完整观测 4 个块）
  切片间隔  p50 196ms，最大 279ms，须 < 2000ms
  单块跨度  最大 1733ms，须 < 2000ms

PASS  外部 wss 入口可订阅，流连续完整，外部 op-reth 可以直接接这个地址
```

每项都把量到的数和门槛并排打出来，通过的项也打——只在失败时打数字的话，`PASS` 就成了一句
没有证据的断言，看不出是贴着门槛过的还是富余很多。失败时这份概要照打，另外追加 `FAIL` 行。

「完整观测 N 个块」是切片完整性和单块跨度实际检查的块数，比覆盖的块数少 2：观测窗口两端的
块天然残缺（开始时那个已经播了一半，结束时那个还没播完），不排除掉每次都会报 2 个假阳性。

### 在终端上盯实时流

想一条条看报文而不是看总账，直接用底层工具的 `-stream`。每收到一片打一行，`index=0` 前空一行，
所以终端上一段就是一个块：

```bash
scripts/flashblocks/remote-verify/bin/fbwatch \
  -url wss://qa-flashblocks-ws.hashkeychain.net/ws -timeout 0 -stream
```

```
已连上 wss://qa-flashblocks-ws.hashkeychain.net/ws（HTTP 101），Ctrl-C 停止

17:02:09.635  块 2249250  切片 0     902 字节  距上片 272ms
17:02:09.635  块 2249250  切片 1     414 字节  距上片 0ms
17:02:09.754  块 2249250  切片 2     414 字节  距上片 118ms
17:02:09.955  块 2249250  切片 3     414 字节  距上片 201ms
…
17:02:11.362  块 2249250  切片 10    413 字节  距上片 203ms

17:02:11.633  块 2249251  切片 0     900 字节  距上片 270ms
```

`-timeout 0` 是一直收到 `Ctrl-C`；给个秒数就是收满即停。二进制不存在时先跑一次
`ws-verify.sh` 让它编译出来。

肉眼要看的是三件事：块号每 2 秒 +1、每块切片 0..10 齐全、`距上片` 稳定在 200ms 上下。
切片 0 和 1 之间是 0ms、切片 0 前面那个间隔偏大（~270ms）都是正常的：新块的头两片
（`base` + 第一个 diff）是连着发出来的，而块与块之间有一次封口的空档。

`-timeout 0` 下 30 秒收不到新切片会主动报错退出，不会无声挂死——挂死会让人误以为「流很安静」，
而实际是连接已经断了。

### 判据

五个判据：

| 判据 | 不通说明 |
|---|---|
| 握手拿到 101 | 连不上 → TLS/DNS/ingress；拿到其他 HTTP 码 → 404 查路径，否则查 ingress 有没有转发 `Upgrade`/`Connection` 头 |
| 每片都能解开 | ws-proxy 的压缩开关变了，外部 reth 也会解不开 |
| 块在推进 | builder 掉队了：端口和连接都正常，流却在原地打转 |
| 切片序号从 0 起连续 | 外部 reth 拼不出 pending 块会整块丢弃，预确认直接没了 |
| 切片间隔和单块跨度都小于出块周期 | 间隔超周期 = 中间断过流；跨度超周期 = 拿到完整块内容的时刻和上链没差别，没有提前量 |

### 纯 shell 能做到哪一步

curl 自己就能完成 WebSocket 的 HTTP Upgrade，之后连接不关，服务端推的字节直接进 stdout：

```bash
KEY=$(head -c16 /dev/urandom | base64)
curl -s -N --http1.1 --max-time 6 -D /tmp/fb.hdr -o /tmp/fb.bin \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Key: $KEY" -H "Sec-WebSocket-Version: 13" \
  https://qa-flashblocks-ws.hashkeychain.net/ws 2>/dev/null
printf '%s / 6 秒收到 %s 字节\n' "$(head -1 /tmp/fb.hdr | tr -d '\r')" "$(wc -c < /tmp/fb.bin | tr -d ' ')"
# HTTP/1.1 101 Switching Protocols / 6 秒收到 14037 字节
```

URL 用 `https://` 不是 `wss://`——手动加 Upgrade 头，走的还是 HTTP 请求。`--max-time` 必须给，
否则连接永不结束、curl 会挂住；到时间退出报的 `curl: (28) Operation timed out` 是**预期行为**，
所以上面把 stderr 丢掉了。

这条命令足以断定：外部可达、TLS 正常、ingress 转发了 Upgrade 头、ws-proxy 接受订阅、流是活的。
做日常巡检够用。

但它给不出任何**和「消息」有关**的信息。流的开头是 `82 7e 01 9f 1b fd…`：`82` 是 FIN+二进制帧，
`7e` 表示长度用后续 2 字节表示，`019f` = 415 字节载荷，`1bfd` 起是 brotli 数据。边界信息确实在
字节流里，但要拿到就得**逐帧读长度字段往前走**，这是个有状态的循环，`wc`/`grep` 这类无状态过一遍
字节的工具做不到。而每片载荷是独立的 brotli 流（ws-proxy 开了 `--enable-compression`，见
`cicd/services/hsk-flashblocks-ws-proxy-0/app-qa.yaml`），不切帧就没法解压，`index` 和
`block_number` 也就拿不到。所以切片序号、每块切片数、到达时序这三样必须靠 Go 工具。

`fbwatch/maybeDecompress` 照抄了 reth 的判定（`optimism/flashblocks/src/ws/decoding.rs:57`）：
跳过前导空白后以 `{` 开头就是明文，否则 brotli。必须一致，否则那个压缩开关一动这里就跟着错。

依赖已 vendor 进仓库，`go build -mod=vendor` 不联网。

### 延迟为什么只报「时间差」

不报"相对某个绝对时刻的滞后"。flashblock 里的 `base.timestamp` 是所属块的时间戳，而块从
`T - 出块周期` 就开始构建、到 `T` 才落地，基准点取 `T` 还是 `T - 出块周期` 是含糊的——同一个
样本按不同基准能算出 `+3s` 或 `-1s`。切片间隔和单块跨度只做本机时刻相减，不受这个含糊性也不受
时钟对齐影响。

## 配置

| 变量 | 用在 | 说明 |
|---|---|---|
| `RETH_RPC` | verify.sh | 用户侧 op-reth，认 flashblocks |
| `GETH_RPC` | verify.sh | canonical 基准，可选 |
| `PRECONF_MAX_MS` | verify.sh | 预确认上限，≥ 出块周期 |
| `FB_TEST_KEY` | verify.sh | 私钥，**只从环境变量读，不写进 env 文件** |
| `WS_URL` | ws-verify.sh | 对外 flashblocks wss 入口 |
| `BLOCK_TIME_MS` | ws-verify.sh | 出块周期，各项阈值的基准 |

## 实现说明

`verify.sh` 的时间测量交给 `../verify/txprobe`（Go），脚本只负责签名和判读。shell 做不了：
BSD `date` 没有毫秒精度，而且每轮 fork 两次 `curl` 加一次 `jq`，几十毫秒的自身开销对着秒级
阈值量的就是脚本自己。签名留在 `cast`，`txprobe` 拿到的是已签名的 raw 交易，碰不到私钥。

nonce 由脚本自己递增，不让 `cast` 每笔重取：`cast` 读的是已确认 nonce 而不是池子，一笔卡住之后
后面每笔都会签在同一个 nonce 上，撞成一串 underpriced 报错，把真正的原因埋掉。

`fbwatch` 不和 `../verify/wscheck` 合并：后者写死 `ws://127.0.0.1:port/`，只能在 pod 内查
本地端口有没有在广播，改它会动到已经跑通的那套本地脚本。
