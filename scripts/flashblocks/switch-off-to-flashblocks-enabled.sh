#!/bin/bash
#
# Safely switch a running chain from off to the complete enabled Flashblocks topology.
# Reuse the existing synchronization flow instead of skipping the dry_run transition.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

bash "$SCRIPT_DIR/switch-to-flashblocks-dryrun.sh" "$@"
bash "$SCRIPT_DIR/switch-dryrun-to-flashblocks-enabled.sh"

echo "Complete: switched off → dry_run → enabled"
