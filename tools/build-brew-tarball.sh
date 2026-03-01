#!/usr/bin/env bash
# SCRIPT: build-brew-tarball.sh
# DESCRIPTION: Build Homebrew release tarball via script-helpers helper.
# USAGE: ./tools/build-brew-tarball.sh
# PARAMETERS: No required parameters. Optional env: SCRIPT_HELPERS_DIR.
# EXAMPLE: ./tools/build-brew-tarball.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

helper="$REPO_ROOT/scripts/script-helpers/scripts/build_brew_tarball.sh"
if [[ -f "$helper" ]]; then
  exec bash "$helper" \
    --name "distrodeck" \
    --repo "$REPO_ROOT" \
    --dist-dir "$REPO_ROOT/dist" \
    --exclude ".git" \
    --exclude ".github" \
    --exclude "dist" \
    --exclude ".venv" \
    --exclude "__pycache__"
fi

log_error "script-helpers not initialized. Run: git submodule update --init --recursive"
exit 2
