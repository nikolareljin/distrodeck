#!/usr/bin/env bash
# Verify packaging metadata cannot reintroduce CI build recursion.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

grep -q '^override_dh_auto_build override_dh_auto_install:$' debian/rules \
    || fail "Debian rules must bypass implicit Makefile build/install targets"
awk '
    $0 == "override_dh_auto_build override_dh_auto_install:" {
        found = 1
        getline
        exit ($0 ~ /^[[:blank:]]*@:$/ ? 0 : 1)
    }
    END { if (!found) exit 1 }
' debian/rules || fail "Debian build/install override must directly use a no-op"
grep -Eq '^Version:[[:space:]]+[0-9]+(\.[0-9]+)+$' packaging/distrodeck.spec \
    || fail "RPM Version must be a concrete package version"
grep -Eq '^Source0:[[:space:]]+%\{name\}-%\{version\}\.tar\.gz$' packaging/distrodeck.spec \
    || fail "RPM spec must declare the source archive used by %autosetup"
if grep -q '^Version:.*%{version}' packaging/distrodeck.spec; then
    fail "RPM Version must not recursively expand the version macro"
fi
grep -Eq '^/usr/share/man/man1/distrodeck\.1\*$' packaging/distrodeck.spec \
    || fail "RPM %files must allow debuginfo compression of the man page"
grep -q '^install -m 0644 distrodeck.py ' packaging/distrodeck.spec \
    || fail "RPM build must install every file declared in %files"
if ! grep -Fq "build_command: >-" .github/workflows/main.yml; then fail "Debian CI must explicitly stage build artifacts"; fi
if ! grep -Fq "dpkg-buildpackage -us -uc && mkdir -p dist && cp ../*.deb dist/" .github/workflows/main.yml; then fail "Debian CI must stage .deb artifacts inside the workspace"; fi
if ! grep -Eq 'artifact_glob:.*dist.*deb' .github/workflows/main.yml; then fail "Debian CI artifact upload must not use a parent-relative path"; fi
if ! grep -Fq 'github.workspace' .github/workflows/main.yml; then fail "RPM CI must use an absolute workspace path"; fi
