#!/usr/bin/env bash
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
