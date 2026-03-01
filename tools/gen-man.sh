#!/usr/bin/env bash
# SCRIPT: gen-man.sh
# DESCRIPTION: Generate the distrodeck man page from argparse metadata.
# USAGE: ./tools/gen-man.sh
# PARAMETERS: No required parameters.
# EXAMPLE: ./tools/gen-man.sh
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$repo_root/tools/gen-man.py"
