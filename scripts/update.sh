#!/usr/bin/env bash
# SCRIPT: update.sh
# DESCRIPTION: Update submodules and pin scripts/script-helpers to production.
# USAGE: ./scripts/update.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./scripts/update.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
submodule_path="scripts/script-helpers"

git -C "$repo_root" submodule sync --recursive
git -C "$repo_root" submodule update --init --recursive "$submodule_path"

# Ensure script-helpers tracks production and update it from origin.
git -C "$repo_root" submodule set-branch --branch production "$submodule_path"
git -C "$repo_root" submodule update --init --recursive --remote "$submodule_path"
