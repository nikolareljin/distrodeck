#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

helper="$REPO_ROOT/scripts/script-helpers/scripts/publish_homebrew.sh"
if [[ -x "$helper" ]]; then
  exec "$helper" \
    --formula "${HOMEBREW_FORMULA_PATH:-$REPO_ROOT/packaging/homebrew/distrodeck.rb}" \
    --tap-repo "${HOMEBREW_TAP_REPO:-}" \
    --tap-branch "${HOMEBREW_TAP_BRANCH:-main}" \
    --commit-message "Update distrodeck formula"
fi

log_error "script-helpers not initialized. Run: git submodule update --init --recursive"
exit 2
