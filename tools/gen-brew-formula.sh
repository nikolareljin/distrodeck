#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$REPO_ROOT/scripts/script-helpers}"
# shellcheck source=/dev/null
source "$SCRIPT_HELPERS_DIR/helpers.sh"
shlib_import logging

helper="$REPO_ROOT/scripts/script-helpers/scripts/gen_brew_formula.sh"
if [[ -x "$helper" ]]; then
  version="$(cat "$REPO_ROOT/VERSION")"
  tarball="${TARBALL_PATH:-$REPO_ROOT/dist/distrodeck-$version.tar.gz}"
  if [[ ! -f "$tarball" ]]; then
    log_error "Tarball not found: $tarball"
    exit 2
  fi

  url="${TARBALL_URL:-https://github.com/nikolareljin/distrodeck/releases/download/v$version/distrodeck-$version.tar.gz}"
  exec "$helper" \
    --name "distrodeck" \
    --desc "Export and restore packages before distro upgrades" \
    --homepage "https://github.com/nikolareljin/distrodeck" \
    --license "MIT" \
    --tarball "$tarball" \
    --url "$url" \
    --dep "python@3.12" \
    --man-path "docs/man/distrodeck.1" \
    --formula-path "$REPO_ROOT/packaging/homebrew/distrodeck.rb"
fi

log_error "script-helpers not initialized. Run: git submodule update --init --recursive"
exit 2
