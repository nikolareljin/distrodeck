#!/usr/bin/env bash
# SCRIPT: ppa-upload.sh
# DESCRIPTION: Upload source package to Launchpad PPA via script-helpers.
# USAGE: ./scripts/ppa-upload.sh --ppa <ppa:owner/name> --key-id <gpg_key_id> [--series SERIES] [--dry-run]
# PARAMETERS: Required flags: --ppa and --key-id.
# EXAMPLE: ./scripts/ppa-upload.sh --ppa ppa:owner/name --key-id ABCDEF12
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/ppa-upload.sh --ppa <ppa:owner/name> --key-id <gpg_key_id> [--series SERIES] [--dry-run]

Environment:
  PPA_GPG_PASSPHRASE  GPG key passphrase (required for non-interactive signing).

Notes:
  - Delegates to scripts/script-helpers/scripts/ppa_upload.sh when available.
  - Consider using the ci-helpers PPA workflow for CI automation.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$repo_root/scripts/script-helpers/scripts/ppa_upload.sh"
if [[ -x "$helper" ]]; then
  exec "$helper" --repo "$repo_root" "$@"
fi

echo "script-helpers not initialized. Run: git submodule update --init --recursive" >&2
exit 2
