#!/bin/bash
#
# Shared library for Flashblocks verification scripts. It is sourced by the p*.sh
# scripts under verify/ and is not executed independently.
#
# It contains only four categories: environment loading, result output and assertions,
# thin wrappers around cast/rg, and the wscheck build. wscheck/ is the only Go code
# because a shell cannot perform the WebSocket handshake; everything else uses existing
# commands: cast for chain queries and rg for log counts.
#
# Log counts use complete logs rather than baseline-to-window deltas. Verification
# targets a newly started chain whose logs begin empty, so complete counts represent the
# true state of that chain. When reusing these scripts on a long-running chain that has
# restarted many times, historical errors remain included; clear data/logs first.
#
# Conventions:
#   - Failed assertions do not stop the script. All checks run, and summary determines
#     the exit code, so one run reveals every issue.
#   - Use ${VAR} when a variable is immediately followed by non-ASCII punctuation:
#     Bash 3.2 under a UTF-8 locale may absorb the punctuation's first byte into the
#     variable name and exit with "unbound variable" when set -u is active.

# ---------- Paths and environment ----------
VERIFY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(cd "$VERIFY_DIR/../../.." && pwd)
cd "$REPO_ROOT"
# .envrc references some variables before they are defined, so disable set -u while
# loading it.
set +u
# shellcheck disable=SC1091
source .envrc >/dev/null 2>&1
set -u

# .envrc contains `export BASE_PATH=$PWD`, which overwrites the value calculated above
# with the current directory. They match during normal invocation, but sourcing .envrc
# elsewhere can export an incorrect value. Always use the repository root derived from
# this script's location rather than trusting BASE_PATH from the environment.
BASE_PATH="$REPO_ROOT"

DATA_DIR="$BASE_PATH/data"
LOG_DIR="$DATA_DIR/logs"
PID_DIR="$DATA_DIR/pids"
CFG_DIR="${DEPLOYMENT_CONFIG_PATH:-$BASE_PATH/config/${DEPLOYMENT_CONTEXT:-local-mainnet}}"

# External component addresses (always obtain ports from .envrc to avoid hard-coded drift).
L1_RPC="${L1_RPC_URL:-http://localhost:8545}"
L2_RPC="${L2_RPC_URL:-http://localhost:8645}"
RB_RPC="http://localhost:${RBUILDER_HTTP_PORT:-8663}"
OPNODE_RPC="${OP_NODE_RPC_URL:-http://localhost:9545}"
RB_DEBUG="http://localhost:${RB_DEBUG_PORT:-5555}"
RB_PROXY="http://localhost:${RB_ENGINE_PORT:-8551}"
FB_RPC="http://localhost:${FB_RPC_HTTP_PORT:-8745}"
FB_OPNODE_RPC="http://localhost:${FB_RPC_OPNODE_PORT:-9555}"
JWT_FILE="${OP_GETH_DATA_PATH:-$DATA_DIR/op-geth}/jwt.txt"

# Stop immediately if the log directory is missing. Otherwise, log_count returns 0 for
# every absent file, making an incorrect path indistinguishable from no matches and
# causing all count-based checks to pass incorrectly.
if [ ! -d "$LOG_DIR" ]; then
  echo "FATAL: log directory does not exist: $LOG_DIR" >&2
  echo "       resolved repository root: $BASE_PATH" >&2
  echo "       the chain has never started, or this script was moved out of scripts/flashblocks/verify/." >&2
  exit 1
fi

# ---------- Output ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

PASS_N=0; FAIL_N=0; WARN_N=0; SKIP_N=0
FAILED_ITEMS=""

banner() {
  echo ""
  echo "${C_BLU}============================================================${C_OFF}"
  echo "${C_BLU}  $*${C_OFF}"
  echo "${C_BLU}============================================================${C_OFF}"
}

section() { echo ""; echo "${C_BLU}── $* ──${C_OFF}"; }
info()    { echo "   $*"; }
detail()  { echo "${C_DIM}     $*${C_OFF}"; }

pass() { PASS_N=$((PASS_N+1)); echo "  ${C_GRN}PASS${C_OFF}  $*"; }
warn() { WARN_N=$((WARN_N+1)); echo "  ${C_YEL}WARN${C_OFF}  $*"; }
skip() { SKIP_N=$((SKIP_N+1)); echo "  ${C_DIM}SKIP${C_OFF}  $*"; }
fail() {
  FAIL_N=$((FAIL_N+1))
  echo "  ${C_RED}FAIL${C_OFF}  $*"
  FAILED_ITEMS="${FAILED_ITEMS}
    - $*"
}

# assert_eq <expected> <actual> <description>
assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3  ($2)"; else fail "$3  expected=[$1] actual=[$2]"; fi
}

# assert_ne <unexpected> <actual> <description>
assert_ne() {
  if [ "$1" != "$2" ]; then pass "$3  ($2)"; else fail "$3  must not equal [$1]"; fi
}

# assert_num_le <actual> <upper-bound> <description>
assert_num_le() {
  if [ "$1" -le "$2" ] 2>/dev/null; then pass "$3  ($1 <= $2)"; else fail "$3  ($1 > $2)"; fi
}

# assert_num_ge <actual> <lower-bound> <description>
assert_num_ge() {
  if [ "$1" -ge "$2" ] 2>/dev/null; then pass "$3  ($1 >= $2)"; else fail "$3  ($1 < $2)"; fi
}

summary() {
  echo ""
  echo "${C_BLU}------------------------------------------------------------${C_OFF}"
  printf "  Results: ${C_GRN}PASS=%d${C_OFF}  ${C_RED}FAIL=%d${C_OFF}  ${C_YEL}WARN=%d${C_OFF}  ${C_DIM}SKIP=%d${C_OFF}\n" \
    "$PASS_N" "$FAIL_N" "$WARN_N" "$SKIP_N"
  if [ "$FAIL_N" -gt 0 ]; then
    echo "  ${C_RED}Failed checks:${C_OFF}${FAILED_ITEMS}"
    echo "${C_BLU}------------------------------------------------------------${C_OFF}"
    return 1
  fi
  echo "${C_BLU}------------------------------------------------------------${C_OFF}"
  return 0
}

require_cmd() {
  local missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  if [ -n "$missing" ]; then
    echo "${C_RED}Error${C_OFF}: missing commands:${missing}" >&2
    return 1
  fi
}

# ---------- Chain queries (all through cast) ----------
# Block height; output -1 when unreachable or non-numeric so callers can compare integers.
rpc_bn() {
  local n; n=$(cast bn --rpc-url "$1" 2>/dev/null || echo "")
  case "$n" in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac
}

rpc_alive() { [ "$(rpc_bn "$1")" -ge 0 ]; }

# Block hash at a given height; output an empty string if unavailable.
# Comparing the hash is sufficient to establish that two chains are identical at that
# height because stateRoot is part of the hashed block header. On mismatch, query
# block_state_root to distinguish different execution results from other header changes.
block_hash()       { cast block "$2" -f hash      --rpc-url "$1" 2>/dev/null; }
block_state_root() { cast block "$2" -f stateRoot --rpc-url "$1" 2>/dev/null; }

# jsonrpc <url> <method> [params-json]
jsonrpc() {
  local url="$1" method="$2" params="${3:-[]}"
  curl -s --max-time 5 -X POST -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" "$url" 2>/dev/null
}

# Current rollup-boost execution mode; output none when it is not running.
boost_mode() {
  local r; r=$(jsonrpc "$RB_DEBUG" debug_getExecutionMode)
  [ -z "$r" ] && { echo none; return; }
  echo "$r" | rg -o '"execution_mode":"([a-z_]+)"' -r '$1'
}

# Switch execution modes live without restarting components. <enabled|dry_run|disabled>
# Output the resulting mode so the caller can confirm it.
set_boost_mode() {
  jsonrpc "$RB_DEBUG" debug_setExecutionMode "[{\"execution_mode\":\"$1\"}]" >/dev/null
  sleep 1
  boost_mode
}

# set_envrc_mode <off|dry_run|enabled> rewrites the *initial* mode, which decides what
# chain-start brings up; use set_boost_mode to switch a chain that is already running.
# shellcheck source=scripts/flashblocks/envrc-mode.sh
source "$BASE_PATH/scripts/flashblocks/envrc-mode.sh"

# Height of one head reported by optimism_syncStatus.
# sync_head <opnode-rpc> <unsafe_l2|safe_l2|finalized_l2>; output -1 when unavailable.
# cast rpc already unwraps the result field, so jq only has to reach one level in.
sync_head() {
  local n
  n=$(cast rpc optimism_syncStatus --rpc-url "$1" 2>/dev/null | jq -r ".${2}.number" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) echo -1 ;; *) echo "$n" ;; esac
}

# ---------- Logs ----------
# Launch scripts pass --color never to reth-based components, so new logs contain no
# ANSI color codes. Keep stripping colors for old logs written before that flag was
# added; rollup-boost logs have always been clean.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null; }

# log_count <log-name-without-.log> <regex> -- total matches; output 0 if absent.
log_count() {
  local f="$LOG_DIR/$1.log"
  [ -f "$f" ] || { echo 0; return; }
  strip_ansi "$f" | rg -c "$2" 2>/dev/null || echo 0
}

# ---------- Go helpers (the two things a shell cannot do) ----------
# wscheck completes the WebSocket handshake; txprobe measures preconfirmation latency on a
# millisecond clock. Everything else in verify/ is cast and rg.
WSCHECK="$VERIFY_DIR/bin/wscheck"
TXPROBE="$VERIFY_DIR/bin/txprobe"

# .envrc prepends a pinned Go toolchain to PATH for building the op-stack, and that binary
# is not always usable: on macOS, Family Controls can deny execution of a downloaded
# toolchain with EPERM. `command -v` cannot see that, because the file is still marked
# executable, so ask each candidate for its version and take the first that answers.
# GOTOOLCHAIN=local is required even for `go version`: .envrc also pins GOTOOLCHAIN, and
# without this a working Go would try to switch to the pinned release and go download it.
find_go() {
  local candidate
  for candidate in go /usr/local/go/bin/go /opt/homebrew/bin/go; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    GOTOOLCHAIN=local "$candidate" version >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  return 1
}

# build_go_tool <source-dir-name> <output-path>
# Rebuild when sources are newer than the binary: the build takes a couple of seconds and
# needs no network, so nobody should have to remember a separate build step.
#   -mod=vendor      explicit, so external GOFLAGS cannot send Go to the network
#   GOTOOLCHAIN=local  build with whatever toolchain we found instead of switching to the
#                      version .envrc pins, which is the one that may be unusable
build_go_tool() {
  local src="$VERIFY_DIR/$1" out="$2" go_bin
  [ -x "$out" ] && [ -z "$(find "$src" -name '*.go' -newer "$out" 2>/dev/null)" ] && return 0
  if ! go_bin=$(find_go); then
    echo "WARN: no usable Go toolchain; checks that need $1 will be skipped" >&2
    return 1
  fi
  echo "Building $1 ..." >&2
  (cd "$src" && GOTOOLCHAIN=local "$go_bin" build -mod=vendor -o "$out" .) \
    || { echo "WARN: $1 build failed; checks that need it will be skipped" >&2; return 1; }
}

build_go_tool wscheck "$WSCHECK"
build_go_tool txprobe "$TXPROBE"
