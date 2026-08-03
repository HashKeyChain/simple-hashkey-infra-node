#!/bin/bash
# Build the Flashblocks-related Rust components into bin/ (requires a Rust toolchain).
# The first build is slow because reth has many dependencies.
# Components and tags (pinned to the Jovian generation):
#   rollup-boost / websocket-proxy  <- rollup-boost submodule @ $ROLLUP_BOOST_REF (v0.7.11)
#   op-rbuilder                     <- op-rbuilder  submodule @ $OP_RBUILDER_REF (v0.2.13)
#   op-reth                         <- reth         submodule @ $OP_RETH_REF     (v1.9.3)
source .envrc
set -e
mkdir -p "$BASE_PATH/bin"

# Use one toolchain throughout: RUSTUP_TOOLCHAIN takes precedence over each repository's
# rust-toolchain.toml (op-rbuilder pins 1.88.0; rollup-boost/reth have no file and fall back
# to stable), so one setting applies without changing the cargo commands.
# Use 1.94 because it is installed locally and permitted by Screen Time/MDM (the optimism
# monorepo rust/ directory also pins 1.94 and builds without a prompt). The default stable
# rustc is not permitted and may be blocked. Override with FB_RUST_TOOLCHAIN when needed.
export RUSTUP_TOOLCHAIN="${FB_RUST_TOOLCHAIN:-1.94}"
echo "Using rust toolchain (RUSTUP_TOOLCHAIN=$RUSTUP_TOOLCHAIN)"

fetch_and_checkout() {
  local ref=$1
  git fetch --depth 1 origin "$ref" 2>/dev/null || git fetch --depth 1 origin tag "$ref" 2>/dev/null || true
  git checkout "$ref"
}

git submodule update --init rollup-boost op-rbuilder reth 2>/dev/null || true

# rollup-boost + websocket-proxy (same submodule and tag)
cd "$BASE_PATH/rollup-boost" && fetch_and_checkout "$ROLLUP_BOOST_REF"
cargo build --release --bin rollup-boost --bin flashblocks-websocket-proxy
cp target/release/rollup-boost "$BASE_PATH/bin/rollup-boost"
cp target/release/flashblocks-websocket-proxy "$BASE_PATH/bin/flashblocks-websocket-proxy"

# op-rbuilder
cd "$BASE_PATH/op-rbuilder" && fetch_and_checkout "$OP_RBUILDER_REF"
cargo build --release --bin op-rbuilder
cp target/release/op-rbuilder "$BASE_PATH/bin/op-rbuilder"

# op-reth (binary target in the reth submodule)
cd "$BASE_PATH/reth" && fetch_and_checkout "$OP_RETH_REF"
cargo build --release -p op-reth --bin op-reth
cp target/release/op-reth "$BASE_PATH/bin/op-reth"

# macOS: force a fresh ad hoc signature on newly built binaries (as in build-binaries.sh)
# to avoid the first execution hanging.
if [ "$(uname)" = "Darwin" ] && command -v codesign >/dev/null 2>&1; then
  for b in rollup-boost flashblocks-websocket-proxy op-rbuilder op-reth; do
    [ -f "$BASE_PATH/bin/$b" ] && codesign -f -s - "$BASE_PATH/bin/$b" >/dev/null 2>&1 || true
  done
  echo "Re-signed flashblocks binaries (adhoc) for macOS."
fi

# Smoke test: the first execution of a newly built binary may trigger a Screen Time prompt,
# so failure is non-fatal.
if "$BASE_PATH/bin/op-reth" node --help 2>/dev/null | grep -q flashblocks; then
  echo "op-reth: flashblocks flag OK"
else
  echo "warn: could not run bin/op-reth --help (Screen Time may have blocked it, or the flag may have changed); the binary was built, so verify it in your terminal"
fi
cd "$BASE_PATH"
echo "Flashblocks binaries built into bin/"
