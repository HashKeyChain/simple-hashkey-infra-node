#!/bin/bash
#
# Single source of truth for rewriting FLASHBLOCKS_MODE in .envrc.
#
# Source it to obtain set_envrc_mode, or run it directly:
#   bash scripts/flashblocks/envrc-mode.sh off
#
# FLASHBLOCKS_MODE is the *initial* mode: it decides which components chain-start.sh
# brings up. It does not affect a chain that is already running — switch that through
# rollup-boost's debug API (debug_setExecutionMode). Note the two vocabularies differ:
# .envrc uses off/dry_run/enabled, while rollup-boost's runtime ExecutionMode is
# enabled/dry_run/disabled and has no "off".

# Resolved from this file's location rather than the working directory: callers source it
# from several depths, and a relative default would write to whichever .envrc happened to
# be under $PWD.
FB_ENVRC_PATH=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/.envrc

# set_envrc_mode <off|dry_run|enabled> [envrc-path]
set_envrc_mode() {
  local mode="$1"
  local file="${2:-$FB_ENVRC_PATH}"

  case "$mode" in
    off|dry_run|enabled) ;;
    *)
      echo "set_envrc_mode: invalid mode '${mode}' (want off, dry_run, or enabled)" >&2
      return 1
      ;;
  esac
  [ -f "$file" ] || { echo "set_envrc_mode: ${file} not found" >&2; return 1; }

  # Replace when the line exists, append when it does not. A bare substitution reports
  # success without writing anything on an .envrc that never declared the mode.
  # The ^ anchor leaves commented-out variants alone.
  if grep -q '^export FLASHBLOCKS_MODE=' "$file"; then
    # -i.bak rather than bare -i: that spelling is accepted by both BSD and GNU sed.
    sed -i.bak "s/^export FLASHBLOCKS_MODE=.*/export FLASHBLOCKS_MODE=${mode}/" "$file"
    rm -f "$file.bak"
  else
    printf 'export FLASHBLOCKS_MODE=%s\n' "$mode" >> "$file"
  fi

  # Read back before reporting success: callers decide topology from this value, so a
  # write that silently did nothing must not look like it worked.
  grep -qxF "export FLASHBLOCKS_MODE=${mode}" "$file" || {
    echo "set_envrc_mode: failed to write FLASHBLOCKS_MODE=${mode} to ${file}" >&2
    return 1
  }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ $# -ge 1 ] || {
    echo "usage: bash ${0##*/} <off|dry_run|enabled> [envrc-path]" >&2
    exit 1
  }
  set_envrc_mode "$@"
fi
