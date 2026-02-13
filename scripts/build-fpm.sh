#!/usr/bin/env bash
# SCRIPT: build-fpm.sh
# DESCRIPTION: Build package artifacts using make man + make fpm.
# USAGE: ./scripts/build-fpm.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./scripts/build-fpm.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$repo_root"
make man
make fpm
