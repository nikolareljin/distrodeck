#!/usr/bin/env bash
# SCRIPT: publish-homebrew.sh
# DESCRIPTION: Publish/update Homebrew tap formula via script-helpers publish_homebrew helper.
# USAGE: ./tools/publish-homebrew.sh
# PARAMETERS: Required env: HOMEBREW_TAP_REPO. Optional env: HOMEBREW_FORMULA_PATH, HOMEBREW_TAP_BRANCH, SCRIPT_HELPERS_DIR.
# EXAMPLE: HOMEBREW_TAP_REPO=owner/homebrew-tap ./tools/publish-homebrew.sh
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
