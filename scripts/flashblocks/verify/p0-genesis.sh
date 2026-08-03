#!/bin/bash
#
# P0 verification: build artifacts, version generation, genesis alignment, and JWT consistency.
#
# Corresponds to the P0 gate in doc/flashblocks_local_impl.md section 7:
#   "reth-based components load genesis successfully; op-rbuilder genesis hash equals
#   the op-geth genesis hash."
# It also adds two high-risk items identified by that document but omitted as explicit
# checks from the original gate:
#   - Pin the version generation to Jovian (section 10, risk 1): mixing in Karst introduces
#     Engine API V5, which is incompatible with op-node v1.16.x.
#   - Ensure JWT consistency (section 10, risk 4): every component must share jwt.txt.
#
# Usage: bash scripts/flashblocks/verify/p0-genesis.sh
# Prerequisites: none. Binaries only need to be in bin/. Genesis comparison requires
# op-geth and op-rbuilder to be running; otherwise it is automatically skipped.

set -uo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

banner "P0 · Build artifacts / version generation / genesis alignment / JWT"

# ---------- Dependencies ----------
section "Tool dependencies"
if require_cmd cast rg curl; then
  pass "cast / rg / curl are available"
else
  fail "required commands are missing; subsequent checks are unreliable"
  summary; exit 1
fi

# ---------- Rust binaries ----------
section "Rust component binaries"
for b in rollup-boost op-rbuilder op-reth flashblocks-websocket-proxy; do
  if [ -x "$BASE_PATH/bin/$b" ]; then
    pass "bin/${b} exists and is executable"
  else
    fail "bin/${b} is missing; first run bash scripts/flashblocks/build-flashblocks.sh"
  fi
done

# ---------- Version generation ----------
# Only op-rbuilder/op-reth report the actual tag through --version. rollup-boost and
# ws-proxy always report an internal version of 0.1.0, so verify them with git describe
# in their source directories.
section "Version generation pin (must be Jovian; do not mix in Karst)"

check_git_ref() {
  local dir="$1" want="$2" name="$3"
  if [ ! -e "$BASE_PATH/$dir/.git" ]; then
    skip "${name} source directory is not a Git repository; cannot verify the tag"
    return
  fi
  local got; got=$(git -C "$BASE_PATH/$dir" describe --tags --always 2>/dev/null)
  case "$got" in
    *"$want") pass "${name} = ${got}  (expected to contain ${want})" ;;
    *)        fail "${name} = ${got}  expected to contain ${want}" ;;
  esac
}

check_bin_version() {
  local bin="$1" want="$2" name="$3"
  [ -x "$BASE_PATH/bin/$bin" ] || { skip "${name} binary is missing; skipping version verification"; return; }
  local got; got=$("$BASE_PATH/bin/$bin" --version 2>&1 | head -1)
  case "$got" in
    *"$want"*) pass "${name} → ${got}" ;;
    *)         fail "${name} → ${got}  expected to contain ${want}" ;;
  esac
}

check_git_ref rollup-boost "${ROLLUP_BOOST_REF:-v0.7.11}" "rollup-boost source tag"
check_git_ref op-rbuilder "${OP_RBUILDER_REF:-op-rbuilder/v0.2.13}" "op-rbuilder source tag"
check_bin_version op-rbuilder "$(echo "${OP_RBUILDER_REF:-v0.2.13}" | sed 's#.*/v##')" "op-rbuilder binary version"
check_bin_version op-reth "$(echo "${OP_RETH_REF:-v1.9.3}" | sed 's#^v##')" "op-reth binary version"

# ---------- Configuration files ----------
section "Chain configuration files"
for f in genesis.json rollup.json; do
  if [ -s "$CFG_DIR/$f" ]; then
    pass "${CFG_DIR}/${f} exists"
  else
    fail "${CFG_DIR}/${f} is missing or empty"
  fi
done

if [ -s "$CFG_DIR/genesis.json" ]; then
  forks=$(rg -o '"(canyon|delta|ecotone|fjord|granite|holocene|isthmus|jovian)Time": *([0-9]+)' -r '$1=$2' \
    "$CFG_DIR/genesis.json" | tr '\n' ' ')
  if [ -z "$forks" ]; then
    fail "genesis.json contains no fork times; op-geth will fall back to --override.*, which op-rbuilder cannot read"
  else
    pass "fork times are embedded in genesis.json"
    detail "$forks"
  fi
fi

# ---------- Genesis hash alignment ----------
section "Genesis hash alignment (core P0 gate)"
if rpc_alive "$L2_RPC" && rpc_alive "$RB_RPC"; then
  gh=$(block_hash "$L2_RPC" 0)
  rh=$(block_hash "$RB_RPC" 0)
  info "op-geth     genesis = ${gh}"
  info "op-rbuilder genesis = ${rh}"
  assert_eq "$gh" "$rh" "op-rbuilder and op-geth genesis hashes match"
else
  skip "op-geth or op-rbuilder is not running; cannot compare genesis hashes"
  detail "op-geth(${L2_RPC}) alive=$(rpc_alive "$L2_RPC" && echo yes || echo no)  op-rbuilder(${RB_RPC}) alive=$(rpc_alive "$RB_RPC" && echo yes || echo no)"
fi

# ---------- Slice configuration ----------
section "op-rbuilder slice configuration"
# Expected slices per block = chain_block_time / flashblocks_interval. If
# run-op-rbuilder.sh omits --rollup.chain-block-time, op-rbuilder uses the 1000 ms
# default, halving the slice count and leaving the second half of the block window idle.
# The chain still runs and blocks remain valid, so only this comparison detects the
# problem. This is a one-time configuration check rather than a per-window observation.
per=$(( ${L2_BLOCK_TIME:-2} * 1000 / ${FB_INTERVAL_MS:-250} ))
detail "expected slices = L2_BLOCK_TIME (${L2_BLOCK_TIME:-2}s) / slice interval (${FB_INTERVAL_MS:-250}ms) = ${per}"
target=$(strip_ansi "$LOG_DIR/op-rbuilder.log" | rg -o 'target_flashblocks=([0-9]+)' -r '$1' | tail -1)
if [ -z "$target" ]; then
  skip "op-rbuilder logs contain no target_flashblocks yet (never started or logs were cleared)"
else
  assert_eq "$per" "$target" "actual op-rbuilder slices per block (target_flashblocks)"
  [ "$target" != "$per" ] && detail "a mismatch usually means run-op-rbuilder.sh omitted --rollup.chain-block-time."
fi

# ---------- JWT consistency ----------
section "JWT consistency (all components must use the same jwt.txt)"
if [ -s "$JWT_FILE" ]; then
  pass "JWT file exists: ${JWT_FILE}"
else
  fail "JWT file is missing: ${JWT_FILE}"
fi

# Enumerate exact process names. Do not use `ps | rg jwt`: rg's own command line contains
# the pattern and would be counted.
jwts=""
for name in op-geth op-node op-rbuilder op-reth rollup-boost; do
  for pid in $(pgrep -x "$name" 2>/dev/null); do
    v=$(ps -o args= -p "$pid" 2>/dev/null \
      | rg -o '\-\-[a-z0-9.-]*jwt[a-z-]*[= ]([^ ]+)' -r '$1')
    [ -n "$v" ] && jwts="${jwts}${v}
"
  done
done
jwts=$(echo "$jwts" | rg -v '^$' | sort -u)

if [ -z "$jwts" ]; then
  skip "no components are running; cannot compare their JWT paths"
else
  n=$(echo "$jwts" | wc -l | tr -d ' ')
  info "running components reference ${n} distinct JWT path(s):"
  echo "$jwts" | sed 's/^/       /'
  assert_eq 1 "$n" "all running components share one JWT"
fi

summary
