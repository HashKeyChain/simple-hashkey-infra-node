#!/bin/bash
# 编译 flashblocks 相关 Rust 组件到 bin/（需 rust toolchain）。首次较慢（reth 依赖重）。
# 组件与 tag（Jovian 世代锁）：
#   rollup-boost / websocket-proxy  <- rollup-boost submodule @ $ROLLUP_BOOST_REF (v0.7.11)
#   op-rbuilder                     <- op-rbuilder  submodule @ $OP_RBUILDER_REF (v0.2.13)
#   op-reth                         <- reth         submodule @ $OP_RETH_REF     (v1.9.3)
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

# 统一 toolchain：RUSTUP_TOOLCHAIN 优先级高于各仓库自带的 rust-toolchain.toml
# （op-rbuilder pin 1.88.0；rollup-boost / reth 无文件→回落默认 stable），一处生效、cargo 命令不变。
# 选 1.94：本机已装且被 Screen Time/MDM 放行（optimism monorepo rust/ pin 1.94，无弹框编过全套）；
# 默认 stable 的 rustc 未放行会被拦。需要时用 FB_RUST_TOOLCHAIN 覆盖。
export RUSTUP_TOOLCHAIN="${FB_RUST_TOOLCHAIN:-1.94}"
echo "Using rust toolchain (RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN)"

fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy（同 submodule、同 tag）
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin flashblocks-websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/flashblocks-websocket-proxy "$BASE_PATH/bin/flashblocks-websocket-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# op-reth（reth submodule 的 bin target）
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release -p op-reth --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"

# macOS：对新建二进制强制重新 ad-hoc 签名（与 build-binaries.sh 同款；规避首次 exec 卡死）。
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  for b in rollup-boost flashblocks-websocket-proxy op-rbuilder op-reth; do
    [ -f "$BASE_PATH/bin/$b" ] && codesign -f -s - "$BASE_PATH/bin/$b" >/dev/null 2>&1 || true
  done
  echo "Re-signed flashblocks binaries (adhoc) for macOS."
fi

# 冒烟：新编二进制首次 exec 也可能触发 Screen Time 弹框，故设为非致命。
if "$BASE_PATH/bin/op-reth" node --help 2>/dev/null | grep -q flashblocks; then
  echo "op-reth: flashblocks flag OK"
else
  echo "warn: 无法执行 bin/op-reth --help（可能被 Screen Time 拦或 flag 名变化）；二进制已生成，请在自己终端核验"
fi
cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
