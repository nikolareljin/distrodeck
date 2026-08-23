#!/usr/bin/env bash
# SCRIPT: test_install_tools_args.sh
# DESCRIPTION: Tests for install-tools-tui.sh argument handling and helpers.
# USAGE: bash tests/test_install_tools_args.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/test_install_tools_args.sh
# ----------------------------------------------------
# These tests never install anything: they exercise validation paths that exit
# before any package manager runs, plus helpers sourced directly from the
# script.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-tools-tui.sh"

if [[ ! -d "$REPO_ROOT/scripts/script-helpers" ]]; then
  git -C "$REPO_ROOT" submodule update --init --depth 1 scripts/script-helpers >/dev/null 2>&1 || true
fi
if [[ ! -f "$REPO_ROOT/scripts/script-helpers/helpers.sh" ]]; then
  echo "SKIP: scripts/script-helpers is not available; cannot exercise the installer."
  exit 0
fi

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

assert_exit() {
  local expected="$1" description="$2"
  shift 2
  local output actual
  output="$("$@" 2>&1)"
  actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    pass "$description"
  else
    fail "$description" "expected exit ${expected}, got ${actual}: ${output}"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$description"
  else
    fail "$description" "missing '${needle}'"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" description="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$description"
  else
    fail "$description" "unexpectedly found '${needle}'"
  fi
}

# ── CLI validation ───────────────────────────────────────────────────────────

assert_exit 0 "--list-tools exits 0" "$INSTALLER" --list-tools
assert_exit 0 "--help exits 0" "$INSTALLER" --help
# These modes only parse local data and must stay available on unsupported
# systems, where package-manager detection would otherwise fail first.
assert_exit 0 "--help works without a package manager" bash -c '
  source "$1"
  detect_pkg_mgr() { echo unknown; }
  main --help
' _ "$INSTALLER"
assert_exit 0 "--list-tools works without a package manager" bash -c '
  source "$1"
  detect_pkg_mgr() { echo unknown; }
  main --list-tools
' _ "$INSTALLER"

assert_exit 2 "unknown tool is rejected" "$INSTALLER" --tools bat,definitely-not-a-tool
assert_exit 2 "--all with --tools is rejected" "$INSTALLER" --all --tools bat
assert_exit 2 "--reconcile without --tools is rejected" "$INSTALLER" --reconcile
assert_exit 2 "unknown option is rejected" "$INSTALLER" --frobnicate
assert_exit 2 "--tools without a value is rejected" "$INSTALLER" --tools
assert_exit 2 "unreadable tools file is rejected" "$INSTALLER" --tools-file /nonexistent/tools.txt

catalog_output="$("$INSTALLER" --list-tools 2>&1)"
assert_contains "$catalog_output" "rustdesk" "catalog lists rustdesk"
assert_contains "$catalog_output" "node" "catalog lists node"

unknown_output="$("$INSTALLER" --tools definitely-not-a-tool 2>&1)"
assert_contains "$unknown_output" "definitely-not-a-tool" "rejection names the unknown tool"

# A tools file whose entries are invalid must be rejected before any install,
# which also proves comment and blank-line stripping fed the validator.
tools_file="$(mktemp)"
cat > "$tools_file" <<'EOF'
# a comment
bat

definitely-not-a-tool
EOF
assert_exit 2 "tools file with an unknown entry is rejected" "$INSTALLER" --tools-file "$tools_file"
file_output="$("$INSTALLER" --tools-file "$tools_file" 2>&1)"
assert_contains "$file_output" "definitely-not-a-tool" "tools file rejection names the entry"
assert_not_contains "$file_output" "a comment" "comments are stripped from tools files"
rm -f "$tools_file"

# ── Helper functions (sourced, installer not run) ────────────────────────────

# shellcheck source=/dev/null
source "$INSTALLER"

all_selection="$(default_all_selection)"
assert_contains " $all_selection " " rustdesk " "--all selection includes rustdesk"
assert_contains " $all_selection " " node " "--all selection includes node"
assert_not_contains " $all_selection " " aider " "--all selection holds out opt-in tools"
assert_not_contains " $all_selection " " ollama " "--all selection holds out ollama"

parsed=()
collect_tools "bat, eza  fd," parsed
if [[ "${parsed[*]}" == "bat eza fd" ]]; then
  pass "collect_tools splits on commas and whitespace"
else
  fail "collect_tools splits on commas and whitespace" "got '${parsed[*]}'"
fi

parsed_file=()
list_file="$(mktemp)"
printf '# header\nbat\n\n  eza  # trailing comment\n' > "$list_file"
collect_tools_file "$list_file" parsed_file
if [[ "${parsed_file[*]}" == "bat eza" ]]; then
  pass "collect_tools_file ignores comments and blank lines"
else
  fail "collect_tools_file ignores comments and blank lines" "got '${parsed_file[*]}'"
fi
rm -f "$list_file"

# ── nvm profile wiring ───────────────────────────────────────────────────────

profile="$(mktemp)"
echo "# existing profile" > "$profile"
wire_nvm_profile "$profile" >/dev/null 2>&1
wire_nvm_profile "$profile" >/dev/null 2>&1
occurrences="$(grep -c "distrodeck nvm" "$profile" || true)"
if [[ "$occurrences" -eq 2 ]]; then
  # One begin marker plus one end marker: wiring applied exactly once.
  pass "wire_nvm_profile is idempotent"
else
  fail "wire_nvm_profile is idempotent" "expected 2 marker lines, found ${occurrences}"
fi

unwire_nvm_profile "$profile" >/dev/null 2>&1
if grep -q "distrodeck nvm" "$profile"; then
  fail "unwire_nvm_profile removes the block" "markers still present"
else
  pass "unwire_nvm_profile removes the block"
fi
if grep -q "# existing profile" "$profile"; then
  pass "unwire_nvm_profile preserves unrelated profile content"
else
  fail "unwire_nvm_profile preserves unrelated profile content" "original line was removed"
fi
# A malformed profile with an unterminated managed block must be left intact.
profile="$(mktemp)"
printf "before\n%s\nkeep this\n" "$NVM_PROFILE_BEGIN" > "$profile"
original_profile="$(<"$profile")"
unwire_nvm_profile "$profile" >/dev/null 2>&1
if [[ "$(<"$profile")" == "$original_profile" ]]; then
  pass "unwire_nvm_profile preserves an unterminated block"
else
  fail "unwire_nvm_profile preserves an unterminated block"
fi
rm -f "$profile"

# A custom NVM_DIR must be preserved in the profile, and nvm itself must not
# count as Node after distrodeck removes the system Node package.
custom_nvm_dir="$(mktemp -d)"
NVM_INSTALL_DIR="$custom_nvm_dir"
profile="$(mktemp)"
# API tags are retained for the release path while artifact names omit v.
download_file() { printf '{"tag_name":"v1.4.9"}\n' > "$2"; }
rustdesk_release_tag="$(rustdesk_latest_tag)"
rustdesk_release_version="${rustdesk_release_tag#v}"
rustdesk_release_url="https://github.com/rustdesk/rustdesk/releases/download/${rustdesk_release_tag}/rustdesk-${rustdesk_release_version}-x86_64.deb"
assert_contains "$rustdesk_release_url" "/download/v1.4.9/" "RustDesk release URL preserves tag prefix"
assert_contains "$rustdesk_release_url" "rustdesk-1.4.9-x86_64.deb" "RustDesk artifact name omits tag prefix"
download_file() { return 1; }
if [[ "$(rustdesk_latest_tag)" == "v1.4.9" ]]; then
  pass "RustDesk fallback preserves release tag prefix"
else
  fail "RustDesk fallback preserves release tag prefix"
fi


wire_nvm_profile "$profile" >/dev/null 2>&1
profile_contents="$(<"$profile")"
assert_contains "$profile_contents" "export NVM_DIR=$custom_nvm_dir" "wire_nvm_profile preserves custom NVM_DIR"
rm -f "$profile"

touch "$custom_nvm_dir/nvm.sh"
if (PATH=""; is_installed_tool node); then
  fail "nvm checkout alone does not count as Node installed"
else
  pass "nvm checkout alone does not count as Node installed"
fi
rm -rf "$custom_nvm_dir"


# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "${PASSES} passed, ${FAILURES} failed"
[[ "$FAILURES" -eq 0 ]]
