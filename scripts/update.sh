#!/usr/bin/env bash
# SCRIPT: update.sh
# DESCRIPTION: Update repository submodules recursively.
# USAGE: ./scripts/update.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./scripts/update.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git -C "$repo_root" submodule update --init --recursive
