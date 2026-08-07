#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

OFF_SWITCH="$ROOT/scripts/flashblocks/switch-off-to-flashblocks-enabled.sh"
DRYRUN_SWITCH="$ROOT/scripts/flashblocks/switch-dryrun-to-flashblocks-enabled.sh"

[ -f "$OFF_SWITCH" ] || fail "missing switch-off-to-flashblocks-enabled.sh"
[ -f "$DRYRUN_SWITCH" ] || fail "missing switch-dryrun-to-flashblocks-enabled.sh"

# Both dry_run startup paths must prepare the user-facing topology before a live switch.
grep -Fq '[ "${FLASHBLOCKS_MODE:-off}" != "off" ]' \
  "$ROOT/scripts/chain-ops/chain-start.sh" \
  || fail "chain-start does not start the user side in dry_run"
grep -Fq 'source "$FB_DIR/start-user-side.sh"' \
  "$ROOT/scripts/flashblocks/switch-to-flashblocks-dryrun.sh" \
  || fail "the surgical dry_run switch does not start the user side"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/scripts/flashblocks" "$TMP/bin"

cp "$DRYRUN_SWITCH" "$ROOT/scripts/flashblocks/envrc-mode.sh" "$TMP/repo/scripts/flashblocks/"
cat > "$TMP/repo/.envrc" <<EOF
export BASE_PATH="$TMP/repo"
export FLASHBLOCKS_MODE=dry_run
export RB_DEBUG_PORT=5555
EOF

cat > "$TMP/bin/curl" <<'EOF'
#!/bin/bash
case "$*" in
  *debug_getExecutionMode*)
    printf '{"jsonrpc":"2.0","id":1,"result":{"execution_mode":"%s"}}\n' "$(cat "$CURL_STATE")"
    ;;
  *debug_setExecutionMode*)
    printf '%s\n' enabled > "$CURL_STATE"
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"execution_mode":"enabled"}}'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$TMP/bin/curl"
printf '%s\n' dry_run > "$TMP/curl-state"

(
  cd "$TMP/repo"
  CURL_STATE="$TMP/curl-state" PATH="$TMP/bin:$PATH" \
    bash scripts/flashblocks/switch-dryrun-to-flashblocks-enabled.sh
)
grep -Fqx 'export FLASHBLOCKS_MODE=enabled' "$TMP/repo/.envrc" \
  || fail "dry_run switch did not persist enabled mode"

# The off wrapper must reuse the existing off→dry_run switch and forward its arguments.
cp "$OFF_SWITCH" "$TMP/repo/scripts/flashblocks/"
cat > "$TMP/repo/scripts/flashblocks/switch-to-flashblocks-dryrun.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" > "$TMP/off-args"
EOF
chmod +x "$TMP/repo/scripts/flashblocks/switch-to-flashblocks-dryrun.sh"
sed -i.bak 's/FLASHBLOCKS_MODE=enabled/FLASHBLOCKS_MODE=dry_run/' "$TMP/repo/.envrc"
rm -f "$TMP/repo/.envrc.bak"

(
  cd "$TMP/repo"
  printf '%s\n' dry_run > "$TMP/curl-state"
  CURL_STATE="$TMP/curl-state" PATH="$TMP/bin:$PATH" \
    bash scripts/flashblocks/switch-off-to-flashblocks-enabled.sh local --lag=4
)
[ "$(cat "$TMP/off-args")" = "local --lag=4" ] \
  || fail "off switch did not forward arguments to the dry_run switch"
grep -Fqx 'export FLASHBLOCKS_MODE=enabled' "$TMP/repo/.envrc" \
  || fail "off switch did not finish in enabled mode"

# An .envrc that never declared the mode must gain the line rather than be left untouched:
# a bare substitution reports success while writing nothing, so the caller would go on to
# start the wrong topology.
printf '%s\n' 'export BASE_PATH=/tmp/nowhere' > "$TMP/bare-envrc"
bash "$ROOT/scripts/flashblocks/envrc-mode.sh" dry_run "$TMP/bare-envrc"
grep -Fqx 'export FLASHBLOCKS_MODE=dry_run' "$TMP/bare-envrc" \
  || fail "envrc-mode did not append the mode to an .envrc that lacked it"

bash "$ROOT/scripts/flashblocks/envrc-mode.sh" enabled "$TMP/bare-envrc"
[ "$(grep -c '^export FLASHBLOCKS_MODE=' "$TMP/bare-envrc")" = "1" ] \
  || fail "envrc-mode appended a duplicate instead of replacing"
grep -Fqx 'export FLASHBLOCKS_MODE=enabled' "$TMP/bare-envrc" \
  || fail "envrc-mode did not replace an existing mode line"

bash "$ROOT/scripts/flashblocks/envrc-mode.sh" bogus "$TMP/bare-envrc" 2>/dev/null \
  && fail "envrc-mode accepted an invalid mode"

echo "PASS: Flashblocks enabled switch scripts"
