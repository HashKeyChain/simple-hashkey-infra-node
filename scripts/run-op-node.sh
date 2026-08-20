#!/bin/bash
#
# 纯组件启动器：仅负责用正确 flags 启动 op-node（本组件 flags 的唯一真源）。
# 由 chain-start.sh 编排调用，也可单独运行用于调试/重启。
#
# 单独运行前提：op-geth 已在 :8651 提供 engine RPC、JWT 已生成、rollup.json 已生成。
#

source .envrc

# 允许被 chain-start 编排层通过 _CALLER_* 覆盖；单独运行时回落到 .envrc / 默认值。
L1_RPC_URL="${_CALLER_L1_RPC_URL:-$L1_RPC_URL}"
OP_GETH_DATA_PATH="${_CALLER_OP_GETH_DATA_PATH:-${OP_GETH_DATA_PATH:-$BASE_PATH/data/op-geth}}"
JWT_FILE="${_CALLER_JWT_FILE:-$OP_GETH_DATA_PATH/jwt.txt}"
# rollup.json 统一取 config/<context>/（git 跟踪、经 runbook patch 的规范配置），
# 而非 .envrc 默认指向的 optimism/.../deployments/（构建原始产物）。
OP_NODE_ROLLUP_FILE="${_CALLER_OP_NODE_ROLLUP_FILE:-${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/$DEPLOYMENT_CONTEXT}/rollup.json}"
SAFEDB_PATH="${_CALLER_SAFEDB_PATH:-${SAFEDB_PATH:-$BASE_PATH/data/op-node/safedb}}"

mkdir -p "$(dirname "$SAFEDB_PATH")"

# Engine 端点：默认直连本机 op-geth 的 authrpc(8651)，与未设置该变量时的历史行为逐字节一致。
# 设置 L2_ENGINE_URL 可把 Engine 流量改指到中间件（如 engine-api-proxy），
# 由中间件透明转发给 op-geth，用于拦截 engine_getPayload* 计算并登记区块哈希。
# 注意：不能靠导出 op-node 自带的 OP_NODE_L2_ENGINE_RPC 来改 —— urfave/cli 的命令行
# 优先级高于 EnvVars，只要这里仍然拼出 --l2=，环境变量就会被忽略；故必须在此处组装。
L2_ENGINE_URL="${L2_ENGINE_URL:-http://localhost:${OP_GETH_AUTHRPC_PORT:-8651}}"

# 区块签名方式。**签名方式与 p2p 开关必须一起决定，不能分开配**，理由见下面第 3 条。
#   - 默认（OP_SIGNER_ENDPOINT 留空）：用本地 sequencer 私钥签名 + --p2p.disable，
#     与历史行为逐字节一致。
#   - 设置 OP_SIGNER_ENDPOINT：改用远端签名器（op-signer）。此时：
#     1. 必须去掉 --p2p.sequencer.key，否则 op-node 会以 "cannot specify both a private
#        key and a remote signer for sequencer p2p" 拒绝启动
#        （op-node/p2p/cli/load_signer.go:20）。
#     2. 远端签名器只有 endpoint 与 address 同时非空才算启用（op-service/signer 的
#        CLIConfig.Enabled()），故两者一起下发；address 默认取本链的 sequencer 地址。
#     3. **p2p 必须处于启用状态**。op-node/node/node.go:803 SignAndPublishL2Payload：
#            if p2pNode := n.getP2PNodeIfEnabled(); p2pNode != nil { ...签名并发布... }
#            // if p2p is not enabled then we just don't publish the payload
#            return nil
#        p2p 关着时这个函数直接返回 nil，**一次都不会去调签名器**；而 initP2PSigner
#        （node.go:264）是无条件执行的，op-node 照样会连上 op-signer 并打印
#        "Connected to op-signer server"。于是链正常出块、签名器连着、错误计数恒为 0，
#        看哪儿都是绿的，但签名链路一次没走过 —— 假绿比报错危险得多，故这里显式下发
#        --p2p.disable=false（命令行优先于 EnvVars，连 OP_NODE_P2P_DISABLE 一起压掉）。
#     4. --signer.tls.enabled 必须为 true：op-signer 是**无条件 mTLS**，它的
#        service/auth.go 在 tls.enabled=false 时同样要求客户端叶证书，没有明文模式。
#        因此 =false 这个组合永远连不上（连启动时的 health_status 都过不去）。
if [ -n "${OP_SIGNER_ENDPOINT:-}" ]; then
  # 端点 scheme 必须是 https：go-ethereum 的 rpc 传输层**按 URL scheme** 决定要不要
  # TLS（op-service/signer/client.go 把带 mTLS 的 http.Client 交给 rpc.DialOptions，
  # scheme 写 http 时那份 TLSClientConfig 根本不会被用到），明文请求撞上 op-signer 的
  # TLS 监听只会握手失败。这个坑踩过一次，故在这里直接拦掉。
  case "$OP_SIGNER_ENDPOINT" in
    https://*) ;;
    *)
      echo "Error: OP_SIGNER_ENDPOINT 必须是 https:// —— 当前是 '$OP_SIGNER_ENDPOINT'。" >&2
      echo "       op-signer 只有 mTLS 端口，且 go-ethereum 的 rpc 按 scheme 判断是否启用 TLS；" >&2
      echo "       写 http:// 时客户端证书配了也不会生效，发出去的是明文请求。" >&2
      exit 1
      ;;
  esac

  # 主机名要能匹配签名器证书的 **DNS SAN**。签名器证书通常只签 DNS SAN（localhost），
  # 没有 IP SAN，写 https://127.0.0.1:... 会在校验主机名这一步失败 —— 实测踩过。
  # localhost 同样解析到回环，"只绑回环" 的约束不受影响。
  signer_host="${OP_SIGNER_ENDPOINT#https://}"; signer_host="${signer_host%%/*}"; signer_host="${signer_host%%:*}"
  case "$signer_host" in
    *[0-9].[0-9]*)
      echo "WARN: OP_SIGNER_ENDPOINT 的主机是 IP（$signer_host）。签名器证书一般只有 DNS SAN，" >&2
      echo "      客户端校验主机名会失败；请改用证书里的域名（本地通常是 localhost）。" >&2
      ;;
  esac

  # mTLS 凭据。三项必须成套给：只给一部分时 op-node 会用它自己的默认相对路径
  # （tls/ca.crt、tls/tls.crt、tls/tls.key，相对当前工作目录），那是另一种难查的失败。
  signer_tls_flags=""
  if [ -n "${OP_SIGNER_TLS_CA:-}${OP_SIGNER_TLS_CERT:-}${OP_SIGNER_TLS_KEY:-}" ]; then
    for v in OP_SIGNER_TLS_CA OP_SIGNER_TLS_CERT OP_SIGNER_TLS_KEY; do
      p="${!v:-}"
      if [ -z "$p" ]; then
        echo "Error: $v 未设置。OP_SIGNER_TLS_CA / _CERT / _KEY 必须成套提供。" >&2
        exit 1
      fi
      if [ ! -f "$p" ]; then
        echo "Error: $v 指向的文件不存在: $p" >&2
        exit 1
      fi
    done
    signer_tls_flags="--signer.tls.ca=$OP_SIGNER_TLS_CA --signer.tls.cert=$OP_SIGNER_TLS_CERT --signer.tls.key=$OP_SIGNER_TLS_KEY"
  else
    echo "WARN: 未提供 OP_SIGNER_TLS_CA / _CERT / _KEY，op-node 将使用其默认相对路径" >&2
    echo "      （tls/ca.crt、tls/tls.crt、tls/tls.key，相对 $PWD）。op-signer 无条件要求" >&2
    echo "      客户端证书，路径不对就是每次调用 401。" >&2
  fi

  signer_flags="--signer.endpoint=$OP_SIGNER_ENDPOINT --signer.address=${OP_SIGNER_ADDRESS:-$GS_SEQUENCER_ADDRESS} --signer.tls.enabled=true $signer_tls_flags"

  # p2p 栈开着，但不去连外面：不做发现、只绑回环、不给 bootnode。
  # 签名发生在发布之前（op-node/p2p/gossip.go 先 SignBlockV1 再 publish），
  # 所以一个 peer 都没有时签名链路照样被完整走一遍。
  # 三个持久化路径显式指到 data/op-node/：op-node 的默认值是相对当前目录的
  # opnode_p2p_priv.txt / opnode_peerstore_db / opnode_discovery_db，
  # 不指定就会把这些文件拉在仓库根目录（且 peerstore 里带一份 p2p 私钥副本）。
  P2P_DATA_DIR="${P2P_DATA_DIR:-$(dirname "$SAFEDB_PATH")}"
  mkdir -p "$P2P_DATA_DIR"
  p2p_flags="--p2p.disable=false --p2p.no-discovery --p2p.listen.ip=127.0.0.1 --p2p.priv.path=$P2P_DATA_DIR/p2p_priv.txt --p2p.peerstore.path=$P2P_DATA_DIR/peerstore_db --p2p.discovery.path=$P2P_DATA_DIR/discovery_db"

  # 打开 metrics：签名失败**只**体现在这个计数器上。区块签名跑在独立 goroutine 里
  # （op-node/rollup/async/asyncgossiper.go 的 gossip：失败只打一条 Warn +
  # RecordPublishingError 就返回），出块循环既不等它也不看它，所以不开 metrics 时
  # "签名全红" 与 "签名全绿" 在外部看起来完全一样。
  metrics_flags="--metrics.enabled --metrics.addr=127.0.0.1 --metrics.port=${OP_NODE_METRICS_PORT:-7300}"

  if [ -n "${OP_NODE_P2P_DISABLE:-}" ]; then
    echo "WARN: 检测到 OP_NODE_P2P_DISABLE=$OP_NODE_P2P_DISABLE，已被命令行 --p2p.disable=false 覆盖。" >&2
    echo "      配了远端签名器就不能禁用 p2p，否则签名链路一次都不会被走到。" >&2
  fi
else
  signer_flags="--p2p.sequencer.key=$GS_SEQUENCER_PRIVATE_KEY"
  p2p_flags="--p2p.disable"
  metrics_flags=""
fi

# --rpc.addr 绑回环：rollup RPC(9545) 的消费方（batcher/proposer/challenger）都在本机。
base_flags="--log.level=info --rpc.addr=127.0.0.1 --l1=$L1_RPC_URL --l1.rpckind=$L1_RPC_KIND --l2=$L2_ENGINE_URL --l2.jwt-secret=$JWT_FILE"
misc_flags="--sequencer.enabled --l1.epoch-poll-interval=${L1_BLOCK_TIME}s $p2p_flags --rpc.enable-admin $signer_flags $metrics_flags --sequencer.l1-confs=5 --verifier.l1-confs=4"
node_flags="--rollup.config=$OP_NODE_ROLLUP_FILE --l1.beacon.ignore --safedb.path=$SAFEDB_PATH"
flags="$base_flags $misc_flags $node_flags"

# ---------- 防复发断言：远端签名器 + 禁用 p2p 这个组合绝不允许启动 ----------
# 判据取的是**即将交给 op-node 的这行命令行本身**，不是脚本里某个变量的值：
# 无论 --p2p.disable 是从哪条分支、哪次后续改动混进来的，只要它和 --signer.endpoint
# 同时出现在这里就一定被拦下。命令行是 op-node 唯一的最终输入（urfave/cli 的命令行
# 优先级高于 EnvVars），所以这个判据不会被环境变量绕过。
if printf '%s' "$flags" | grep -q -- '--signer.endpoint=' \
   && printf '%s ' "$flags" | grep -qE -- '(^| )--p2p\.disable(=true)?( |$)'; then
  echo "Error: 命令行同时出现 --signer.endpoint 与 --p2p.disable，拒绝启动。" >&2
  echo "       p2p 被禁用时 SignAndPublishL2Payload（op-node/node/node.go:803）直接 return nil," >&2
  echo "       远端签名器一次都不会被调用，而链照常出块、op-node 照常打印" >&2
  echo "       \"Connected to op-signer server\" —— 这是个只会骗人的假绿灯。" >&2
  exit 1
fi

echo "Starting op-node with rollup config: $OP_NODE_ROLLUP_FILE"
echo "op-node $flags"

exec op-node $flags
