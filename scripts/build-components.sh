#!/bin/bash
#
# Build op-geth / op-node / op-batcher / op-proposer from source
# using _REF variables defined in .envrc.
# Uses git worktree to avoid disturbing the main checkout (which may have local modifications).
#
# Usage:
#   bash scripts/build-components.sh              # build all components
#   bash scripts/build-components.sh op-node       # build op-node only
#   bash scripts/build-components.sh op-geth       # build op-geth only
#
# Environment variables (from .envrc):
#   OP_GETH_REF      - op-geth repo tag/branch (e.g. v1.101605.0)
#   OP_NODE_REF      - optimism monorepo tag/branch (e.g. op-node/v1.10.0)
#   OP_BATCHER_REF   - optimism monorepo tag/branch (e.g. op-batcher/v1.16.3)
#   OP_PROPOSER_REF  - optimism monorepo tag/branch (e.g. op-proposer/v1.10.0)
#
# Options:
#   FORCE_BUILD=1    - force rebuild even if binary already exists
#   GOPROXY=...      - set Go module proxy (e.g. https://goproxy.cn,direct)
#

set -e

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
BASE_PATH=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$BASE_PATH"

source .envrc

BIN_DIR="$BASE_PATH/bin"
BUILD_DIR="$BASE_PATH/.build"
MONO_REPO="$BASE_PATH/optimism"
OP_GETH_REPO_URL="${OP_GETH_REPO_URL:-https://github.com/ethereum-optimism/op-geth.git}"
OP_GETH_DIR="$BUILD_DIR/op-geth"

mkdir -p "$BIN_DIR" "$BUILD_DIR"

TARGETS="${@:-op-geth op-node op-batcher op-proposer}"

_log()  { echo ""; echo "======== $* ========"; }
_ok()   { echo "  ✓ $*"; }
_skip() { echo "  → $* (already exists, use FORCE_BUILD=1 to rebuild)"; }

# ---------- op-geth (separate repo) ----------
build_op_geth() {
  local ref="$OP_GETH_REF"
  _log "op-geth @ $ref"

  if [ "${FORCE_BUILD:-0}" != "1" ] && [ -f "$BIN_DIR/op-geth" ]; then
    _skip "op-geth"
    return
  fi

  if [ ! -d "$OP_GETH_DIR/.git" ]; then
    echo "  Cloning op-geth..."
    git clone --depth=1 --branch "$ref" "$OP_GETH_REPO_URL" "$OP_GETH_DIR"
  else
    cd "$OP_GETH_DIR"
    git fetch --all --tags --prune 2>/dev/null || git fetch origin "$ref"
  fi

  cd "$OP_GETH_DIR"

  CURRENT=$(git describe --tags --exact-match HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  if [ "$CURRENT" != "$ref" ]; then
    echo "  Checking out $ref..."
    git checkout "$ref" 2>/dev/null || git checkout -b "_build_${ref}" "origin/$ref" 2>/dev/null || git checkout "$ref"
  fi

  echo "  Building op-geth..."
  make geth
  cp build/bin/geth "$BIN_DIR/op-geth"
  _ok "op-geth -> $BIN_DIR/op-geth"
}

# ---------- monorepo components (op-node / op-batcher / op-proposer) ----------
build_monorepo_component() {
  local name="$1"
  local ref="$2"
  _log "$name @ $ref"

  if [ "${FORCE_BUILD:-0}" != "1" ] && [ -f "$BIN_DIR/$name" ]; then
    _skip "$name"
    return
  fi

  if [ ! -d "$MONO_REPO/.git" ]; then
    echo "  Error: optimism monorepo not found at $MONO_REPO"
    exit 1
  fi

  local WORKTREE_DIR="$BUILD_DIR/${name}-worktree"

  cd "$MONO_REPO"

  # Remove stale worktree
  git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"

  # Fetch remote tags/branches
  git fetch --all --tags 2>/dev/null || git fetch origin "$ref" 2>/dev/null || true

  echo "  Creating worktree at $ref..."
  if git rev-parse "$ref" >/dev/null 2>&1; then
    git worktree add --detach "$WORKTREE_DIR" "$ref"
  elif git rev-parse "origin/$ref" >/dev/null 2>&1; then
    git worktree add --detach "$WORKTREE_DIR" "origin/$ref"
  else
    echo "  Error: ref '$ref' not found locally or in origin."
    echo "  Make sure the branch/tag exists: git -C $MONO_REPO fetch origin $ref"
    exit 1
  fi

  cd "$WORKTREE_DIR"
  local GIT_COMMIT=$(git rev-parse --short HEAD)
  local GIT_DATE=$(git log -1 --format=%ct 2>/dev/null || echo "0")

  echo "  Building $name (commit: $GIT_COMMIT)..."
  cd "$WORKTREE_DIR/$name"
  go build \
    -ldflags "-X main.GitCommit=$GIT_COMMIT -X main.GitDate=$GIT_DATE" \
    -o "$BIN_DIR/$name" \
    ./cmd

  # Cleanup worktree
  cd "$MONO_REPO"
  git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true

  _ok "$name -> $BIN_DIR/$name (commit: $GIT_COMMIT)"
}

# ---------- Run builds ----------
echo "=== Building OP Stack Components ==="
echo "BIN_DIR: $BIN_DIR"
echo "Targets: $TARGETS"

for target in $TARGETS; do
  case "$target" in
    op-geth)
      build_op_geth
      ;;
    op-node)
      build_monorepo_component "op-node" "$OP_NODE_REF"
      ;;
    op-batcher)
      build_monorepo_component "op-batcher" "$OP_BATCHER_REF"
      ;;
    op-proposer)
      build_monorepo_component "op-proposer" "$OP_PROPOSER_REF"
      ;;
    *)
      echo "Unknown target: $target"
      echo "Valid targets: op-geth op-node op-batcher op-proposer"
      exit 1
      ;;
  esac
done

# ---------- Print version summary ----------
_log "Build Summary"
for name in op-geth op-node op-batcher op-proposer; do
  if [ -f "$BIN_DIR/$name" ]; then
    case "$name" in
      op-geth)
        ver=$("$BIN_DIR/$name" version 2>&1 | grep -E 'Version:|Geth' | head -2 | tr '\n' ' ')
        ;;
      *)
        ver=$("$BIN_DIR/$name" --version 2>&1 | head -1)
        ;;
    esac
    echo "  $name: $ver"
  else
    echo "  $name: NOT BUILT"
  fi
done
echo ""
