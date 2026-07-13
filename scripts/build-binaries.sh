#!/bin/bash

source .envrc

mkdir -p $BASE_PATH/bin

# Helper function to fetch and checkout a ref (works with shallow clones)
fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin $ref 2>/dev/null || git fetch --depth 1 origin tag $ref 2>/dev/null || true
  git checkout $ref
}

# build op-geth
cd $BASE_PATH/op-geth
fetch_and_checkout $OP_GETH_REF
make geth
cp build/bin/geth $BASE_PATH/bin/op-geth

# build op-node
cd $BASE_PATH/optimism
fetch_and_checkout $OP_NODE_REF
make op-node
cp $BASE_PATH/optimism/op-node/bin/op-node $BASE_PATH/bin/op-node

# build op-proposer
cd $BASE_PATH/optimism
fetch_and_checkout $OP_PROPOSER_REF
make op-proposer
cp $BASE_PATH/optimism/op-proposer/bin/op-proposer $BASE_PATH/bin/op-proposer

# build op-batcher
cd $BASE_PATH/optimism
fetch_and_checkout $OP_BATCHER_REF
make op-batcher
cp $BASE_PATH/optimism/op-batcher/bin/op-batcher $BASE_PATH/bin/op-batcher

# build op-challenger
cd $BASE_PATH/optimism
fetch_and_checkout $OP_CHALLENGER_REF
make op-challenger
cp $BASE_PATH/optimism/op-challenger/bin/op-challenger $BASE_PATH/bin/op-challenger

# # build op-deployer
# cd $BASE_PATH/optimism
# fetch_and_checkout $OP_DEPLOYER_REF
# just op-deployer
# cp $BASE_PATH/optimism/op-deployer/bin/op-deployer $BASE_PATH/bin/op-deployer

# ---------- fault-proof 组件（仅 USE_FAULT_PROOFS=true 时构建）----------
# op-challenger 跑 cannon 需要：cannon 二进制、op-program(host oracle server)、absolute prestate。
# prestate 用 reproducible（Docker）构建，保证 .pre 可复现；它必须等于 deploy-config 的
# faultGameAbsolutePrestate，challenger 才能参与已部署的 dispute game。
# CANNON_REF/OP_PROGRAM_REF 跟随 OP_CONTRACTS_REF 同源 commit（见 .envrc）。
if [ "${USE_FAULT_PROOFS:-false}" = "true" ]; then
  # build cannon（--cannon-bin）
  cd $BASE_PATH/optimism
  fetch_and_checkout $CANNON_REF
  make cannon
  cp $BASE_PATH/optimism/cannon/bin/cannon $BASE_PATH/bin/cannon

  # build reproducible prestate（Docker）。产物落在 optimism/op-program/bin/：
  #   op-program(host)、op-program-client.elf、prestate.json、prestate-proof.json
  cd $BASE_PATH/optimism
  fetch_and_checkout $OP_PROGRAM_REF
  make -C op-program reproducible-prestate
  cp $BASE_PATH/optimism/op-program/bin/op-program $BASE_PATH/bin/op-program
  cp $BASE_PATH/optimism/op-program/bin/prestate.json $BASE_PATH/bin/prestate.json
  cp $BASE_PATH/optimism/op-program/bin/prestate-proof.json $BASE_PATH/bin/prestate-proof.json

  echo "Fault-proof binaries built."
  echo "  Absolute prestate (.pre): $(jq -r .pre $BASE_PATH/bin/prestate-proof.json)"
  echo "  必须等于 deploy-config 的 faultGameAbsolutePrestate，否则 challenger 无法参与已部署的 game。"
fi

# macOS：对新建二进制强制重新 ad-hoc 签名。
# Go linker 会给产物打 adhoc(linker-signed) 签名，但在部分 macOS/Apple Silicon 上，首次
# exec 该签名会触发内核页校验卡死（进程 STAT=UNE、连 --version 都不返回、SIGQUIT 也无栈）。
# 用 codesign 重新签名可清除这个问题；对已能运行的二进制是幂等无害操作。Linux 无 codesign，跳过。
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  for b in op-geth op-node op-proposer op-batcher op-challenger cannon op-program; do
    [ -f "$BASE_PATH/bin/$b" ] && codesign -f -s - "$BASE_PATH/bin/$b" >/dev/null 2>&1 || true
  done
  echo "Re-signed binaries (adhoc) for macOS."
fi

# return base path
cd $BASE_PATH
