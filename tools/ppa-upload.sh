#!/usr/bin/env bash
# SCRIPT: ppa-upload.sh
# DESCRIPTION: Upload source package to Launchpad PPA via distrodeck wrapper and script-helpers.
# USAGE: ./tools/ppa-upload.sh --ppa <ppa:owner/name> --key-id <gpg_key_id> [--series SERIES] [--dry-run]
# PARAMETERS: Required flags: --ppa and --key-id.
# EXAMPLE: ./tools/ppa-upload.sh --ppa ppa:owner/name --key-id ABCDEF12
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

helper="$REPO_ROOT/scripts/ppa-upload.sh"
if [[ -x "$helper" ]]; then
  "$REPO_ROOT/tools/gen-man.sh"
  exec "$helper" "$@"
fi

log_error "PPA helper not found: $helper"
exit 2
