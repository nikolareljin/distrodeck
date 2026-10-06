#!/usr/bin/env bash
# SCRIPT: test_install_script.sh
# DESCRIPTION: Tests for the source ./install and ./uninstall prefix handling.
# USAGE: bash tests/test_install_script.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/test_install_script.sh
# ----------------------------------------------------
# Installs into temporary prefixes only. uname and sudo are replaced by stubs,
# so nothing is written outside the temp directory and sudo never runs.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

FAILURES=0
PASSES=0

pass() {
  PASSES=$((PASSES + 1))
  echo "ok   - $1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  echo "FAIL - $1"
  [[ $# -gt 1 ]] && echo "       $2"
}

# Stub uname to report the given OS, and sudo to record its arguments.
make_stubs() {
  local dir="$1" os="$2"
  mkdir -p "$dir"
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$os" > "$dir/uname"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "%s/sudo.args"\n' "$dir" > "$dir/sudo"
  chmod +x "$dir/uname" "$dir/sudo"
}

# Build once as the current user so every case below reuses dist/.
if ! "$REPO_ROOT/build" >/dev/null 2>&1; then
  echo "FAIL - ./build failed; cannot exercise ./install"
  exit 1
fi

# 1. macOS defaults to a per-user prefix and needs no sudo.
stubs="$TMP_ROOT/darwin-bin"
make_stubs "$stubs" Darwin
home="$TMP_ROOT/home"
mkdir -p "$home"
output="$(env -u PREFIX HOME="$home" PATH="$stubs:$PATH" "$REPO_ROOT/install" 2>&1)"
if [[ -x "$home/.local/bin/distrodeck" && -f "$home/.local/share/distrodeck/SOURCE_ROOT" ]]; then
  pass "macOS install defaults to \$HOME/.local"
else
  fail "macOS install defaults to \$HOME/.local" "$output"
fi
if [[ ! -e "$stubs/sudo.args" ]]; then
  pass "per-user macOS install does not use sudo"
else
  fail "per-user macOS install does not use sudo" "$(cat "$stubs/sudo.args")"
fi
if [[ "$output" == *"is not on PATH"* ]]; then
  pass "install warns when the prefix bin directory is not on PATH"
else
  fail "install warns when the prefix bin directory is not on PATH" "$output"
fi

output="$(env -u PREFIX HOME="$home" PATH="$stubs:$PATH" "$REPO_ROOT/uninstall" 2>&1)"
if [[ ! -e "$home/.local/bin/distrodeck" && ! -e "$home/.local/share/distrodeck" ]]; then
  pass "macOS uninstall uses the same per-user default"
else
  fail "macOS uninstall uses the same per-user default" "$output"
fi

# 2. A non-writable prefix re-runs the copy step through sudo, keeping PREFIX.
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "skip - sudo re-exec cases (running as root)"
else
  stubs="$TMP_ROOT/linux-bin"
  make_stubs "$stubs" Linux
  locked="$TMP_ROOT/locked"
  mkdir -p "$locked/bin" "$locked/share/man/man1"
  chmod 555 "$locked/bin" "$locked/share" "$locked"
  output="$(PREFIX="$locked" PATH="$stubs:$PATH" "$REPO_ROOT/install" 2>&1)"
  expected="env PREFIX=$locked $REPO_ROOT/install"
  if [[ "$(cat "$stubs/sudo.args" 2>/dev/null)" == "$expected" ]]; then
    pass "install re-runs with sudo when the prefix is not writable"
  else
    fail "install re-runs with sudo when the prefix is not writable" "$output"
  fi
  if [[ ! -e "$locked/bin/distrodeck" && "$output" != *"Permission denied"* ]]; then
    pass "install does not attempt the copy without permission"
  else
    fail "install does not attempt the copy without permission" "$output"
  fi

  rm -f "$stubs/sudo.args"
  output="$(PREFIX="$locked" PATH="$stubs:$PATH" "$REPO_ROOT/uninstall" 2>&1)"
  expected="env PREFIX=$locked $REPO_ROOT/uninstall"
  if [[ "$(cat "$stubs/sudo.args" 2>/dev/null)" == "$expected" ]]; then
    pass "uninstall re-runs with sudo when the prefix is not writable"
  else
    fail "uninstall re-runs with sudo when the prefix is not writable" "$output"
  fi
fi

echo
echo "${PASSES} passed, ${FAILURES} failed"
[[ "$FAILURES" -eq 0 ]]
