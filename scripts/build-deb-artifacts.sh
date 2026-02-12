#!/usr/bin/env bash
# SCRIPT: build-deb-artifacts.sh
# DESCRIPTION: Build Debian artifacts via script-helpers build_deb_artifacts helper.
# USAGE: ./scripts/build-deb-artifacts.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./scripts/build-deb-artifacts.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/script-helpers/scripts/build_deb_artifacts.sh"
if [[ -x "$helper" ]]; then
  exec "$helper" --repo "$repo_root"
fi

echo "script-helpers not initialized. Run: git submodule update --init --recursive" >&2
exit 2
