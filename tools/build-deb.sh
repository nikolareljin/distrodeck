#!/usr/bin/env bash
# SCRIPT: build-deb.sh
# DESCRIPTION: Build Debian artifacts using distrodeck build wrapper and generated man page.
# USAGE: ./tools/build-deb.sh
# PARAMETERS: No required parameters. Optional env: SCRIPT_HELPERS_DIR.
# EXAMPLE: ./tools/build-deb.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

helper="$REPO_ROOT/scripts/build-deb.sh"
if [[ -x "$helper" ]]; then
  "$REPO_ROOT/tools/gen-man.sh"
  exec "$helper"
fi

log_error "Build helper not found: $helper"
exit 2
