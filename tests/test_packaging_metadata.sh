#!/usr/bin/env bash
# Verify packaging metadata cannot reintroduce CI build recursion.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

rg -q '^override_dh_auto_build override_dh_auto_install:$' debian/rules \
    || fail "Debian rules must bypass implicit Makefile build/install targets"
rg -q '^\t@:$' debian/rules \
    || fail "Debian build/install overrides must be no-ops"
rg -q '^Version:[[:space:]]+[0-9]+(\.[0-9]+)+$' packaging/distrodeck.spec \
    || fail "RPM Version must be a concrete package version"
if rg -q '^Version:.*%\{version\}' packaging/distrodeck.spec; then
    fail "RPM Version must not recursively expand the version macro"
fi
rg -q '^install -m 0644 distrodeck\.py ' packaging/distrodeck.spec \
    || fail "RPM build must install every file declared in %files"
