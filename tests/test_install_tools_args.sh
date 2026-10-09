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

assert_exit 2 "--java-version rejects 11" "$INSTALLER" --java-version 11 --tools java
assert_exit 0 "invalid DISTRODECK_JAVA_VERSION does not block a non-java tool" env DISTRODECK_JAVA_VERSION=8 bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  is_installed_tool() { [[ "$1" == bat && -e "$STATE_DIR/bat-done" ]]; }
  install_bat() { touch "$STATE_DIR/bat-done"; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  main --tools bat </dev/null
' _ "$INSTALLER"
assert_exit 1 "invalid DISTRODECK_JAVA_VERSION fails the java tool" env DISTRODECK_JAVA_VERSION=8 bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  is_installed_tool() { return 1; }
  install_pkg() { echo "must not install $*"; return 0; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  main --tools java </dev/null
' _ "$INSTALLER"

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
# shellcheck disable=SC2034  # read by the sourced installer
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
# shellcheck disable=SC2123  # an empty PATH is the point: nothing is on it
if (PATH=""; is_installed_tool node); then
  fail "nvm checkout alone does not count as Node installed"
else
  pass "nvm checkout alone does not count as Node installed"
fi
rm -rf "$custom_nvm_dir"


# ── MongoDB repository setup ─────────────────────────────────────────────────

# Sourcing the installer turned on errexit; these probes expect failures.
set +e
mongo_tmp="$(mktemp -d)"
OS_RELEASE_FILE="$mongo_tmp/os-release"
printf 'ID=ubuntu\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n' > "$OS_RELEASE_FILE"
assert_contains "$(mongodb_apt_target)" "ubuntu noble multiverse" "MongoDB apt target for Ubuntu noble"
printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$OS_RELEASE_FILE"
assert_contains "$(mongodb_apt_target)" "debian bookworm main" "MongoDB apt target for Debian bookworm"
printf 'ID=ubuntu\nVERSION_CODENAME=oracular\n' > "$OS_RELEASE_FILE"
if mongodb_apt_target >/dev/null 2>&1; then
  fail "MongoDB apt target refuses a release without packages"
else
  pass "MongoDB apt target refuses a release without packages"
fi
printf 'ID=rocky\nVERSION_ID="9.4"\n' > "$OS_RELEASE_FILE"
assert_contains "$(mongodb_rpm_release 2>/dev/null)" "9" "MongoDB rpm release uses the RHEL major"

# Stub every privileged command so the apt path writes into the temp dir.
printf 'ID=ubuntu\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n' > "$OS_RELEASE_FILE"
mongo_out="$(
  MONGODB_APT_LIST="$mongo_tmp/mongodb-org.list"
  # shellcheck disable=SC2034  # read by the sourced installer
  MONGODB_KEYRING="$mongo_tmp/mongodb.gpg"
  sudo() { "$@"; }
  gpg() { :; }
  chmod() { :; }
  dpkg() { echo amd64; }
  download_file() { : > "$2"; }
  verify_key_fingerprint() { :; }  # covered with fixture keys below
  mongodb_repo_setup apt && cat "$MONGODB_APT_LIST"
)"
assert_contains "$mongo_out" "deb [arch=amd64 signed-by=$mongo_tmp/mongodb.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/${MONGODB_SERIES} multiverse" "MongoDB apt source is signed-by its keyring"

for mgr in pacman zypper; do
  out="$(install_mongodb "$mgr" 2>&1)"; rc=$?
  if [[ "$rc" -ne 0 && "$out" == *"no official repository for ${mgr}"* ]]; then
    pass "mongodb fails clearly on ${mgr}"
  else
    fail "mongodb fails clearly on ${mgr}" "rc=${rc} out=${out}"
  fi
  out="$(uninstall_atlas "$mgr" 2>&1)"; rc=$?
  [[ "$rc" -ne 0 ]] && pass "atlas uninstall refuses ${mgr}" || fail "atlas uninstall refuses ${mgr}" "$out"
done
uninstall_out="$(
  sudo() { :; }
  command() { return 1; }
  uninstall_pkg() { echo "remove $*"; }
  mongodb_repo_remove_if_unused() { :; }
  uninstall_mongodb apt 2>&1
  uninstall_mongodb dnf 2>&1
)"
assert_contains "$uninstall_out" "remove apt mongodb-org mongodb-org-database" "mongodb apt uninstall names packages explicitly"
assert_not_contains "$uninstall_out" "remove apt mongodb-org*" "mongodb apt uninstall uses no glob"
assert_contains "$uninstall_out" "remove dnf mongodb-org* mongodb-database-tools mongodb-mongosh" "mongodb dnf uninstall uses the glob"
assert_contains "$uninstall_out" "Kept the MongoDB data" "mongodb uninstall says the data is kept"
if (MONGODB_SERIES=9.0; mongodb_repo_setup apt >/dev/null 2>&1); then
  fail "mongodb refuses a series the pinned key does not sign"
else
  pass "mongodb refuses a series the pinned key does not sign"
fi
unset OS_RELEASE_FILE
rm -rf "$mongo_tmp"
all_selection="$(default_all_selection)"
if is_opt_in_tool atlas && is_opt_in_tool mongodb && [[ " $all_selection " != *" mongodb "* && " $all_selection " != *" atlas "* ]]; then
  pass "mongodb and atlas are opt-in and not in --all"
else
  fail "mongodb and atlas are opt-in and not in --all"
fi

# ── Java version choice ──────────────────────────────────────────────────────

assert_contains "$(java_package apt 21)" "openjdk-21-jdk" "java 21 on apt"
assert_contains "$(java_package dnf 25)" "java-25-openjdk-devel" "java 25 on dnf"
assert_contains "$(java_package zypper 17)" "java-17-openjdk-devel" "java 17 on zypper"
assert_contains "$(java_package pacman 21)" "jdk21-openjdk" "java 21 on pacman"
[[ "$JAVA_VERSION" == "21" ]] && pass "java defaults to 21" || fail "java defaults to 21" "$JAVA_VERSION"
java_tmp="$(mktemp -d)"
java_out="$(
  # shellcheck disable=SC2034  # read by the sourced installer
  JAVA_STATE_FILE="$java_tmp/java-version"
  # shellcheck disable=SC2034
  STATE_DIR="$java_tmp"
  JAVA_VERSION=25
  install_pkg() { echo "install $*"; }
  uninstall_pkg() { echo "remove $*"; }
  install_java apt
  JAVA_VERSION=17
  uninstall_java apt
)"
assert_contains "$java_out" "install apt openjdk-25-jdk" "install_java honours JAVA_VERSION"
assert_contains "$java_out" "remove apt openjdk-25-jdk" "uninstall_java removes the JDK it installed"
legacy_out="$(
  # shellcheck disable=SC2034
  JAVA_STATE_FILE="$java_tmp/absent"
  uninstall_pkg() { echo "remove $*"; }
  uninstall_java apt
  uninstall_java dnf
)"
assert_contains "$legacy_out" "remove apt default-jdk" "uninstall_java removes a pre-choice apt install"
assert_contains "$legacy_out" "remove dnf java-17-openjdk-devel" "uninstall_java removes a pre-choice dnf install"
rm -rf "$java_tmp"
if (JAVA_VERSION=11; install_java apt >/dev/null 2>&1); then
  fail "install_java refuses an unsupported version"
else
  pass "install_java refuses an unsupported version"
fi

# ── Managed source checkouts (git-lantern, ai-runner) ────────────────────────

all_selection="$(default_all_selection)"
assert_contains " $all_selection " " git-lantern " "--all selection includes git-lantern"
assert_contains " $all_selection " " ai-runner " "--all selection includes ai-runner"
is_default_selected_tool ai-runner && pass "ai-runner is preselected" || fail "ai-runner is preselected"
checkout_tmp="$(mktemp -d)"
checkout_out="$(
  STATE_DIR="$checkout_tmp"
  git() { echo "git $*"; }
  managed_source_checkout ai-runner https://example.invalid/ai-runner.git
)"
assert_contains "$checkout_out" "git clone https://example.invalid/ai-runner.git $checkout_tmp/tools/ai-runner" "managed checkout clones into tools/<name>"
tag_checkout_out="$(
  git() { echo "git $*"; }
  checkout_managed_source_tag "$checkout_tmp/tools/git-lantern" "0.8.2"
)"
assert_contains "$tag_checkout_out" "git check-ref-format --allow-onelevel refs/tags/0.8.2" "managed tag validates the ref name"
assert_contains "$tag_checkout_out" "git -C $checkout_tmp/tools/git-lantern fetch origin refs/tags/0.8.2:refs/tags/0.8.2" "managed tag fetches the requested release without rewriting local tags"
assert_contains "$tag_checkout_out" "git -C $checkout_tmp/tools/git-lantern checkout --detach refs/tags/0.8.2" "managed tag uses a detached release checkout"
mkdir -p "$checkout_tmp/tools/detached-source/.git"
detached_checkout_out="$(
  STATE_DIR="$checkout_tmp"
  git() {
    case "$*" in
      "-C $checkout_tmp/tools/detached-source symbolic-ref -q HEAD") return 1 ;;
      "-C $checkout_tmp/tools/detached-source symbolic-ref --short refs/remotes/origin/HEAD") printf '%s\\n' origin/main ;;
      *) echo "git $*" ;;
    esac
  }
  managed_source_checkout detached-source https://example.invalid/detached-source.git
)"
assert_contains "$detached_checkout_out" "git -C $checkout_tmp/tools/detached-source switch main" "managed checkout restores the default branch after a detached release checkout"
assert_contains "$detached_checkout_out" "git -C $checkout_tmp/tools/detached-source pull --ff-only" "managed checkout refreshes the restored default branch"
mkdir -p "$checkout_tmp/tools/git-lantern"
if (STATE_DIR="$checkout_tmp"; uninstall_source_checkout git-lantern >/dev/null 2>&1); then
  fail "uninstall_source_checkout refuses a directory without .git"
else
  pass "uninstall_source_checkout refuses a directory without .git"
fi
mkdir -p "$checkout_tmp/tools/git-lantern/.git"
# shellcheck disable=SC2034
(STATE_DIR="$checkout_tmp"; uninstall_source_checkout git-lantern >/dev/null 2>&1)
[[ ! -e "$checkout_tmp/tools/git-lantern" ]] && pass "uninstall_source_checkout removes a managed checkout" || fail "uninstall_source_checkout removes a managed checkout"

lantern_root="$checkout_tmp/lantern-root"
lantern_bin="$checkout_tmp/bin/lantern"
mkdir -p "$checkout_tmp/tools/git-lantern/.git" "$lantern_root/venv/bin" "$(dirname "$lantern_bin")"
touch "$lantern_root/.distrodeck-managed" "$lantern_root/venv/bin/lantern"
chmod +x "$lantern_root/venv/bin/lantern"
ln -s "$lantern_root/venv/bin/lantern" "$lantern_bin"
(
  STATE_DIR="$checkout_tmp"
  git_lantern_install_root() { printf '%s\n' "$lantern_root"; }
  git_lantern_bin_link() { printf '%s\n' "$lantern_bin"; }
  uninstall_git_lantern >/dev/null 2>&1
)
[[ ! -e "$lantern_root" && ! -e "$lantern_bin" && ! -e "$checkout_tmp/tools/git-lantern" ]] \
  && pass "uninstall_git_lantern removes only its managed files" \
  || fail "uninstall_git_lantern removes only its managed files"

mkdir -p "$checkout_tmp/tools/git-lantern/.git" "$lantern_root"
(
  STATE_DIR="$checkout_tmp"
  git_lantern_install_root() { printf '%s\n' "$lantern_root"; }
  git_lantern_bin_link() { printf '%s\n' "$lantern_bin"; }
  uninstall_git_lantern >/dev/null 2>&1
)
[[ -d "$lantern_root" ]] && pass "uninstall_git_lantern preserves an unmarked prefix" || fail "uninstall_git_lantern preserves an unmarked prefix"

foreign_launcher="$checkout_tmp/foreign-lantern"
touch "$foreign_launcher"
rm -rf "$lantern_root" "$checkout_tmp/tools/git-lantern"
mkdir -p "$checkout_tmp/tools/git-lantern/.git" "$lantern_root"
touch "$lantern_root/.distrodeck-managed"
rm -f "$lantern_bin"
ln -s "$foreign_launcher" "$lantern_bin"
(
  STATE_DIR="$checkout_tmp"
  git_lantern_install_root() { printf '%s\n' "$lantern_root"; }
  git_lantern_bin_link() { printf '%s\n' "$lantern_bin"; }
  uninstall_git_lantern >/dev/null 2>&1
)
[[ -L "$lantern_bin" && ! -e "$lantern_root" ]] \
  && pass "uninstall_git_lantern preserves a foreign launcher" \
  || fail "uninstall_git_lantern preserves a foreign launcher"

mkdir -p "$checkout_tmp/tools/git-lantern"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'prefix=""' \
  'bin_link=""' \
  'while [[ $# -gt 0 ]]; do' \
  '  case "$1" in' \
  '    --prefix) prefix="$2"; shift 2 ;;' \
  '    --bin-link) bin_link="$2"; shift 2 ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'mkdir -p "$prefix/venv/bin" "$(dirname "$bin_link")"' \
  'printf "#!/usr/bin/env bash\\nexit 0\\n" > "$prefix/venv/bin/lantern"' \
  'chmod +x "$prefix/venv/bin/lantern"' \
  'ln -sf "$prefix/venv/bin/lantern" "$bin_link"' \
  > "$checkout_tmp/tools/git-lantern/install"
chmod +x "$checkout_tmp/tools/git-lantern/install"
(
  STATE_DIR="$checkout_tmp"
  git_lantern_install_root() { printf '%s\n' "$lantern_root"; }
  git_lantern_bin_link() { printf '%s\n' "$lantern_bin"; }
  managed_source_checkout() { :; }
  checkout_managed_source_tag() { printf '%s\n' "$2" > "$STATE_DIR/git-lantern-tag"; }
  DISTRODECK_GIT_LANTERN_TAG="0.8.2"
  install_git_lantern test >/dev/null
)
[[ -x "$lantern_bin" && -f "$lantern_root/.distrodeck-managed" && "$(<"$checkout_tmp/git-lantern-tag")" == "0.8.2" ]] \
  && pass "install_git_lantern installs a managed launcher" \
  || fail "install_git_lantern installs a managed launcher"
rm -rf "$checkout_tmp"

# ── Categories and the TSV catalog ───────────────────────────────────────────

set +e
tsv="$("$INSTALLER" --list-catalog --format tsv 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "--list-catalog --format tsv exits 0" || fail "--list-catalog --format tsv exits 0" "rc=$rc"
bad_lines="$(awk -F'\t' 'NF != 7 || $5 !~ /^[01]$/ || $6 !~ /^[01]$/ || $7 !~ /^(-|[a-z0-9-]+(,[a-z0-9-]+)*)$/' <<< "$tsv")"
[[ -z "$bad_lines" ]] && pass "every TSV line has 7 columns: 0/1 flags and a needs list" || fail "every TSV line has 7 columns: 0/1 flags and a needs list" "$bad_lines"
needs_of() { awk -F'\t' -v t="$1" '$3 == t {print $7}' <<< "$tsv"; }
for pair in qdrant:docker oracle-free:docker plugin-hookify:claude-code chroma:pipx pgvector:postgresql atlas:- mongodb:- vlc:-; do
  [[ "$(needs_of "${pair%%:*}")" == "${pair#*:}" ]] && pass "needs of ${pair%%:*} is ${pair#*:}" || fail "needs of ${pair%%:*} is ${pair#*:}" "got $(needs_of "${pair%%:*}")"
done
bad_needs="$(awk -F'\t' '$7 != "-" {print $7}' <<< "$tsv" | tr ',' '\n' | sort -u | while read -r n; do is_catalog_tool "$n" || echo "$n"; done)"
[[ -z "$bad_needs" ]] && pass "every needs entry is a catalog tool id" || fail "every needs entry is a catalog tool id" "$bad_needs"
[[ "$tsv" != *$'\e'* ]] && pass "TSV catalog has no ANSI" || fail "TSV catalog has no ANSI"
mongo_line="$(awk -F'\t' '$3 == "mongodb"' <<< "$tsv")"
expected_prefix="$(printf 'db-nosql\tNoSQL & graph databases\tmongodb\tMongoDB Community server + mongosh\t1\t')"
if [[ "$mongo_line" == "$expected_prefix"[01]$'\t-' ]]; then
  pass "TSV column order is category_id, category_label, tool, label, opt_in, installed, needs"
else
  fail "TSV column order is category_id, category_label, tool, label, opt_in, installed, needs" "$mongo_line"
fi
[[ "$(wc -l <<< "$tsv")" -eq "$("$INSTALLER" --list-tools | wc -l)" ]] && pass "TSV has one line per catalog tool" || fail "TSV has one line per catalog tool"
assert_exit 0 "--list-catalog works without a package manager" bash -c '
  source "$1"
  detect_pkg_mgr() { echo unknown; }
  main --list-catalog --format tsv >/dev/null
' _ "$INSTALLER"
assert_exit 2 "--list-catalog rejects --format json" "$INSTALLER" --list-catalog --format json
assert_exit 2 "--format without --list-catalog is refused" "$INSTALLER" --format tsv --tools bat
assert_exit 2 "unknown --category exits 2" "$INSTALLER" --category media,nope
assert_exit 2 "--category with --tools exits 2" "$INSTALLER" --category media --tools vlc
cats="$("$INSTALLER" --list-categories)"
for id in shell editors system network backup dev ai ides lang devops media graphics util db-sql db-nosql db-vector storage db-admin sysadmin web prog claude-plugins apps; do
  [[ "$cats" == *"$id"$'\t'* ]] || fail "--list-categories includes $id"
done
pass "--list-categories lists every category"

# Every catalog tool belongs to exactly one category and has a label.
dupes="$(printf '%s\n' "${TOOL_CATALOG[@]}" | sort | uniq -d)"
[[ -z "$dupes" ]] && pass "no tool is in two categories" || fail "no tool is in two categories" "$dupes"
nolabel=""
for t in "${TOOL_CATALOG[@]}"; do [[ "$(tool_desc "$t")" == "$t" ]] && nolabel+=" $t"; done
[[ -z "$nolabel" ]] && pass "every catalog tool has a label" || fail "every catalog tool has a label" "$nolabel"
for t in vscode zed intellij-idea-community pycharm-community cursor kiro antigravity; do
  is_opt_in_tool "$t" || fail "IDE $t is opt-in"
done
pass "every IDE is opt-in"

# --category installs default-on tools only, one block per category, never uninstalls.
cat_out="$(bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  is_installed_tool() { [[ -e "$STATE_DIR/$1" ]]; }
  install_package_tool() { echo "INSTALL $1"; touch "$STATE_DIR/$1"; }
  install_mongodb() { echo "INSTALL mongodb"; }
  install_gimp() { echo "INSTALL gimp"; touch "$STATE_DIR/gimp"; }
  install_pkg() { echo "UNEXPECTED install_pkg $*"; return 1; }
  main --category graphics,db-nosql </dev/null
' _ "$INSTALLER" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "--category graphics,db-nosql exits 0" || fail "--category graphics,db-nosql exits 0" "$cat_out"
assert_contains "$cat_out" "INSTALL krita" "--category installs the category's tools"
order="$(grep -o '^INSTALL [a-z]*' <<< "$cat_out" | tr '\n' ' ')"
[[ "$order" == "INSTALL blender INSTALL darktable INSTALL gimp INSTALL inkscape INSTALL krita " ]] && pass "--category installs in catalog order" || fail "--category installs in catalog order" "$order"
assert_not_contains "$cat_out" "INSTALL mongodb" "--category never installs an opt-in tool"
assert_contains "$cat_out" "Category db-nosql has only opt-in tools" "--category explains an all-opt-in category"
all_inst_out="$(bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  is_installed_tool() { return 0; }
  install_package_tool() { echo "INSTALL $1"; }
  install_pkg() { echo "INSTALL pkg $*"; }
  main --category media </dev/null
' _ "$INSTALLER" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "--category with every tool installed exits 0" || fail "--category with every tool installed exits 0" "$all_inst_out"
assert_not_contains "$all_inst_out" "INSTALL" "--category with every tool installed installs nothing"

# Package tools: distro package first, Flathub when the manager has none.
assert_contains "$(package_tool_pkg ffmpeg dnf)" "ffmpeg-free" "ffmpeg is ffmpeg-free on dnf"
assert_contains "$(package_tool_pkg intellij-idea-community pacman)" "intellij-idea-community-edition" "IntelliJ CE package on pacman"
fp_out="$(
  install_pkg() { echo "PKG $*"; }
  flatpak() { echo "FLATPAK $*"; }
  install_package_tool handbrake dnf 2>&1
  install_package_tool zed zypper 2>&1
  install_package_tool vlc pacman 2>&1
)"
assert_contains "$fp_out" "FLATPAK install -y flathub fr.handbrake.ghb" "handbrake on dnf falls back to Flathub"
assert_contains "$fp_out" "FLATPAK install -y flathub dev.zed.Zed" "zed on zypper falls back to Flathub"
assert_contains "$fp_out" "PKG pacman vlc" "vlc on pacman uses the distro package"
nopkg_out="$(
  package_tool_spec() { echo "pkg - - - - - - - nothing"; }
  install_package_tool fake apt 2>&1; echo "rc=$?"
)"
assert_contains "$nopkg_out" "has no apt package and no Flatpak" "a tool with no package and no Flatpak says so"
assert_contains "$nopkg_out" "rc=1" "a tool with no package and no Flatpak fails"
un_out="$(
  uninstall_pkg() { echo "UNPKG $*"; }
  flatpak() { [[ "$1" == info ]] && return 1; echo "FLATPAK $*"; }
  uninstall_package_tool krita zypper 2>&1
  uninstall_package_tool zed apt 2>&1; echo "rc=$?"
)"
assert_contains "$un_out" "UNPKG zypper krita" "krita uninstall removes the zypper package"
assert_contains "$un_out" "zed has no apt package to remove" "zed uninstall without Flatpak or package says so"

notty_out="$(bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  dialog() { echo "DIALOG CALLED"; }
  main </dev/null
' _ "$INSTALLER" 2>&1 | cat)"
assert_contains "$notty_out" "needs a terminal" "no-argument run without a terminal explains itself"
assert_not_contains "$notty_out" "DIALOG CALLED" "no-argument run without a terminal never calls dialog"
assert_exit 2 "no-argument run without a terminal exits 2" bash -c 'source "$1"; detect_pkg_mgr() { echo apt; }; main </dev/null >/dev/null' _ "$INSTALLER"

# The interactive menu: open one category, install its block, quit.
# macOS has no timeout(1); the loop guard is the menu-call counter anyway.
with_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
tui_out="$(with_timeout 30 bash -c '
  source "$1"
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  echo bat > "$INSTALLED_TOOLS_FILE"
  detect_pkg_mgr() { echo apt; }
  ensure_dialog() { :; }
  dialog_init() { DIALOG_HEIGHT=20; DIALOG_WIDTH=60; }
  clear() { :; }
  is_installed_tool() { [[ -e "$STATE_DIR/$1" ]]; }
  install_package_tool() { echo "INSTALL $1"; touch "$STATE_DIR/$1"; }
  # dialog runs in a command substitution, so the count lives in a file.
  echo 0 > "$STATE_DIR/menu-calls"
  dialog() {
    local calls
    case " $* " in
      *" --menu "*)
        calls=$(( $(cat "$STATE_DIR/menu-calls") + 1 ))
        echo "$calls" > "$STATE_DIR/menu-calls"
        echo "MENU $calls" >&2
        [[ $calls -eq 1 ]] && { echo media; return 0; }
        return 1;;
      *" --checklist "*) echo "CHECKLIST $*" >&2; echo "vlc mpv"; return 0;;
      *) return 0;;
    esac
  }
  DISTRODECK_FORCE_TUI=1 main </dev/null
' _ "$INSTALLER" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "category menu exits 0 on Quit" || fail "category menu exits 0 on Quit" "$tui_out"
assert_contains "$tui_out" "MENU 2" "category menu returns to the menu after a block"
assert_contains "$tui_out" "INSTALL vlc" "category block installs checked tools"
assert_not_contains "$tui_out" "INSTALL audacity" "category block leaves unchecked tools alone"
checklist_line="$(grep '^CHECKLIST' <<< "$tui_out")"
assert_not_contains "$checklist_line" " krita " "a category checklist shows only its own tools"
assert_contains "$checklist_line" "vlc" "a category checklist shows its tools"

# Detection: binary, then the package database, then `flatpak info`.
det_log="$(mktemp)"
det_out="$(
  command() { [[ "$1" == "-v" && "$2" == "flatpak" ]] && return 0; [[ "$1" == "-v" ]] && return 1; builtin command "$@"; }
  detect_pkg_mgr() { echo zypper; }
  rpm() { [[ "$2" == "blender" ]]; }
  flatpak() { echo "FLATPAK $*" >> "$det_log"; [[ "$1" == info && "$2" == "dev.zed.Zed" ]]; }
  package_tool_installed blender && echo "blender:yes" || echo "blender:no"
  package_tool_installed zed && echo "zed:yes" || echo "zed:no"
  package_tool_installed krita && echo "krita:yes" || echo "krita:no"
)"
det_out+=$'\n'"$(cat "$det_log")"
rm -f "$det_log"
assert_contains "$det_out" "blender:yes" "a package with no plain binary is found through rpm -q"
assert_contains "$det_out" "FLATPAK info dev.zed.Zed" "Flatpak detection uses flatpak info <id>"
assert_contains "$det_out" "zed:yes" "a Flatpak-only install counts as installed"
assert_contains "$det_out" "krita:no" "a tool with no binary, package or Flatpak is missing"
for t in handbrake:ghb obs-studio:obs zed:zeditor intellij-idea-community:idea pycharm-community:pycharm; do
  spec="$(package_tool_spec "${t%%:*}")"
  [[ ",${spec##* }," == *",${t##*:},"* ]] || fail "${t%%:*} detects ${t##*:}" "$spec"
done
pass "detection binaries match the package file lists"

# ── Spec v2: kinds, brew, servers, containers, plugins, macOS ────────────────

set +e
# Every catalog tool has a label, exactly one category and a manager.
nomgr=""
for t in "${TOOL_CATALOG[@]}"; do
  ok=false
  for m in apt dnf pacman zypper brew; do
    tool_supported_on "$t" "$m" && { ok=true; break; }
  done
  $ok || nomgr+=" $t"
done
[[ -z "$nomgr" ]] && pass "every catalog tool has at least one supported manager" || fail "every catalog tool has at least one supported manager" "$nomgr"
nospec=""
for t in "${TOOL_CATALOG[@]}"; do
  is_package_tool "$t" && { [[ "$(package_tool_spec "$t" | wc -w)" -eq 9 ]] || nospec+=" $t"; }
done
[[ -z "$nospec" ]] && pass "every spec row has 9 fields" || fail "every spec row has 9 fields" "$nospec"
for t in postgresql mysql mariadb redis valkey oracle-free qdrant milvus weaviate seaweedfs nginx apache2 caddy cockpit plugin-code-review dbeaver-ce; do
  is_opt_in_tool "$t" || fail "$t is opt-in"
done
pass "servers, containers, GUI admin tools and plugins are opt-in"

assert_contains "$(spec_field obs-studio brew)" "cask:obs" "brew column holds a cask"
assert_contains "$(spec_field btop brew)" "btop" "brew column holds a formula"
brew_out="$(
  brew() { echo "BREW $*"; }
  sudo() { echo "SUDO $*"; }
  install_pkg brew cask:obs btop
  uninstall_pkg brew cask:obs
)"
assert_contains "$brew_out" "BREW install --cask obs" "install_pkg brew installs a cask with --cask"
assert_contains "$brew_out" "BREW install btop" "install_pkg brew installs a formula"
assert_contains "$brew_out" "BREW uninstall --cask obs" "uninstall_pkg brew removes a cask"
assert_not_contains "$brew_out" "SUDO" "brew never runs with sudo"
mac_mgr="$(uname() { echo Darwin; }; brew() { :; }; detect_pkg_mgr)"
assert_contains "$mac_mgr" "brew" "detect_pkg_mgr returns brew on Darwin"

# Linux-only tools are hidden on brew, present on apt.
util_brew=" $(category_tools_for util brew) "
assert_not_contains "$util_brew" " ntfs " "ntfs is hidden on macOS"
assert_not_contains "$util_brew" " nala " "nala is hidden on macOS"
assert_contains " $(category_tools_for util apt) " " ntfs " "ntfs is offered on apt"
assert_contains " $(category_tools_for db-nosql dnf) " " redis " "Linux shows a tool without a package; picking it explains"
assert_not_contains " $(default_all_selection apt) " " pyenv " "--all on apt skips tools apt cannot install"
prog_out="$(bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  is_installed_tool() { return 1; }
  install_tool() { echo "INSTALL $1"; }
  main --category prog </dev/null
' _ "$INSTALLER" 2>&1)"
assert_contains "$prog_out" "No apt package, skipped: pyenv" "--category names the tools this manager cannot install"
assert_not_contains "$prog_out" "INSTALL pyenv" "--category does not try a tool without a package"
assert_not_contains " $(category_tools_for sysadmin brew) " " cockpit " "cockpit is hidden on macOS"
assert_not_contains " $(default_all_selection brew) " " ufw " "--all on macOS skips Linux-only tools"
assert_contains " $(default_all_selection apt) " " ufw " "--all on apt keeps ufw"

# macOS re-exec under bash 3.2.
fake_prefix="$(mktemp -d)"; mkdir -p "$fake_prefix/bin"; printf '#!/bin/sh\n' > "$fake_prefix/bin/bash"; chmod +x "$fake_prefix/bin/bash"
reexec_out="$(
  uname() { echo Darwin; }
  brew() { [[ "$1" == --prefix ]] && echo "$fake_prefix"; }
  exec() { echo "EXEC $*"; exit 0; }
  ensure_modern_bash 3 2 --tools jq
)"
rm -rf "$fake_prefix"
assert_contains "$reexec_out" "/bin/bash" "bash 3.2 on macOS re-execs under Homebrew bash"
assert_contains "$reexec_out" "--tools jq" "the re-exec keeps the arguments"
noreexec_rc="$( ( uname() { echo Darwin; }; command() { [[ "$2" == brew ]] && return 1; builtin command "$@"; }; ensure_modern_bash 3 2 ) >/dev/null 2>&1; echo $? )"
[[ "$noreexec_rc" == "2" ]] && pass "bash 3.2 without Homebrew bash exits 2" || fail "bash 3.2 without Homebrew bash exits 2" "rc=$noreexec_rc"
# uname is stubbed: on a Mac runner the real one would re-exec this test file.
( uname() { echo Linux; }; ensure_modern_bash 4 3 ) >/dev/null 2>&1 && fail "bash 4.3 is refused (empty arrays under set -u)" || pass "bash 4.3 is refused (empty arrays under set -u)"
( ensure_modern_bash 5 2 ) && pass "bash 5 needs no re-exec" || fail "bash 5 needs no re-exec"

# pgvector follows the installed PostgreSQL major.
pg_out="$(psql() { echo "psql (PostgreSQL) 16.4"; }; package_tool_pkg pgvector apt; package_tool_pkg pgvector zypper)"
assert_contains "$pg_out" "postgresql-16-pgvector" "pgvector on apt matches the PostgreSQL major"
assert_contains "$pg_out" "postgresql16-pgvector" "pgvector on zypper matches the PostgreSQL major"
pg_none="$( (psql() { return 1; }; install_package_tool pgvector apt) 2>&1; echo "rc=$?")"
assert_contains "$pg_none" "needs PostgreSQL installed first" "pgvector without PostgreSQL says so"
assert_contains "$pg_none" "rc=1" "pgvector without PostgreSQL fails"

# Server bind: config rewritten to 127.0.0.1.
etc="$(mktemp -d)"
mkdir -p "$etc/etc/nginx/sites-available" "$etc/etc/apache2" "$etc/etc/mysql/conf.d" "$etc/etc/caddy"
printf 'server {\n    listen 80 default_server;\n    listen [::]:80 default_server;\n}\n' > "$etc/etc/nginx/sites-available/default"
printf 'Listen 80\n<IfModule ssl_module>\n\tListen 443\n</IfModule>\n' > "$etc/etc/apache2/ports.conf"
printf ':80 {\n\troot * /usr/share/caddy\n}\n' > "$etc/etc/caddy/Caddyfile"
(
  # shellcheck disable=SC2034  # read by the sourced installer
  ETC_ROOT="$etc"
  brew_prefix_safe() { echo /nonexistent; }
  sudo() { "$@"; }
  for t in nginx apache2 caddy mariadb; do server_bind_localhost "$t" apt; done
)
assert_contains "$(cat "$etc/etc/nginx/sites-available/default")" "listen 127.0.0.1:80 default_server;" "nginx binds 127.0.0.1"
assert_contains "$(cat "$etc/etc/nginx/sites-available/default")" "listen [::1]:80" "nginx binds ::1"
assert_contains "$(cat "$etc/etc/apache2/ports.conf")" "Listen 127.0.0.1:80" "apache binds 127.0.0.1"
assert_contains "$(cat "$etc/etc/apache2/ports.conf")" "Listen 127.0.0.1:443" "apache binds 127.0.0.1 for TLS"
assert_contains "$(cat "$etc/etc/caddy/Caddyfile")" "bind 127.0.0.1" "caddy binds 127.0.0.1"
[[ "$(sed -n 2p "$etc/etc/caddy/Caddyfile")" == $'\tbind 127.0.0.1' ]] && pass "caddy bind is its own line (no literal n from sed)" || fail "caddy bind is its own line (no literal n from sed)"
assert_contains "$(cat "$etc/etc/mysql/conf.d/99-distrodeck-bind.cnf")" "bind-address = 127.0.0.1" "mariadb binds 127.0.0.1"
rm -rf "$etc"
srv_out="$(
  sudo() { echo "SUDO $*"; }
  command() { [[ "$2" == systemctl ]] && return 0; builtin command "$@"; }
  server_bind_localhost() { :; }
  server_setup redis apt 2>&1
  server_teardown valkey pacman 2>&1
)"
assert_contains "$srv_out" "SUDO systemctl enable redis-server" "redis-server is enabled on apt"
assert_contains "$srv_out" "SUDO systemctl disable --now valkey" "valkey is stopped on uninstall"
assert_contains "$srv_out" "Kept the valkey data" "server uninstall keeps data"

# Containers: pinned tags, 127.0.0.1 ports, busy ports refused.
for t in oracle-free qdrant milvus weaviate seaweedfs; do
  img="$(container_spec "$t" | cut -d' ' -f1)"
  [[ "$img" == *:* && "$img" != *:latest ]] || fail "$t image tag is pinned" "$img"
done
pass "container images use pinned tags"
cont_out="$(
  # shellcheck disable=SC2034
  STATE_DIR="$(mktemp -d)"
  container_cli() { echo docker; }
  docker() { echo "DOCKER $*"; [[ "$1" == container ]] && return 1; return 0; }
  port_holder() { return 1; }
  install_container_tool qdrant 2>&1
)"
assert_contains "$cont_out" "DOCKER run -d --name distrodeck-qdrant --restart unless-stopped -v distrodeck-qdrant:/qdrant/storage -p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334 docker.io/qdrant/qdrant:v1.19.1" "qdrant runs pinned, with a named volume, on 127.0.0.1"
busy_out="$(
  container_cli() { echo docker; }
  docker() { echo "DOCKER $*"; [[ "$1" == container ]] && return 1; return 0; }
  port_holder() { [[ "$1" == 6333 ]] && echo "postgres"; }
  install_container_tool qdrant 2>&1; echo "rc=$?"
)"
assert_contains "$busy_out" "Port 6333 is already in use by postgres" "a busy port is refused with the holder's name"
assert_not_contains "$busy_out" "DOCKER run" "a busy port starts nothing"
assert_contains "$busy_out" "rc=1" "a busy port fails the tool"
ora_dir="$(mktemp -d)"
ora_out="$(
  # shellcheck disable=SC2034
  STATE_DIR="$ora_dir"
  container_cli() { echo docker; }
  docker() { echo "DOCKER $*"; [[ "$1" == container ]] && return 1; return 0; }
  port_holder() { return 1; }
  install_container_tool oracle-free 2>&1
)"
assert_contains "$ora_out" "--env-file $ora_dir/oracle-free.env" "the Oracle password goes in through an env file"
assert_not_contains "$ora_out" "ORACLE_PASSWORD=" "the Oracle password is never on the command line"
[[ "$(stat -c %a "$ora_dir/oracle-free.env" 2>/dev/null || stat -f %Lp "$ora_dir/oracle-free.env")" == "600" ]] && pass "the Oracle env file is mode 600" || fail "the Oracle env file is mode 600"
# shellcheck disable=SC2034
pw_len="$(STATE_DIR="$(mktemp -d)"; container_secret probe | wc -c | tr -d ' ')"
[[ "$pw_len" -eq 24 ]] && pass "generated container secrets are 24 characters" || fail "generated container secrets are 24 characters" "$pw_len"
rm -rf "$ora_dir"
nodock_out="$( (container_cli() { return 1; }; install_container_tool milvus) 2>&1; echo "rc=$?")"
assert_contains "$nodock_out" "needs docker or podman" "a container tool without docker says so"
purge_out="$(
  container_cli() { echo docker; }
  docker() { echo "DOCKER $*"; }
  uninstall_container_tool weaviate 2>&1
  DISTRODECK_PURGE=1 uninstall_container_tool weaviate 2>&1
)"
assert_contains "$purge_out" "Kept volume distrodeck-weaviate" "container uninstall keeps the volume"
assert_contains "$purge_out" "Removed volume distrodeck-weaviate" "--purge removes the volume"
holder="$(ss() { printf 'LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:* users:(("postgres",pid=1,fd=5))\n'; }; port_holder 5432)"
assert_contains "$holder" "postgres" "port_holder names the process from ss"

# Claude plugins.
nocl="$( (command() { [[ "$2" == claude ]] && return 1; builtin command "$@"; }; install_claude_plugin plugin-code-review) 2>&1; echo "rc=$?")"
assert_contains "$nocl" "needs the claude CLI" "a plugin without claude says so"
assert_contains "$nocl" "rc=1" "a plugin without claude fails"
# claude runs under timeout(1), so the stubs are executables on PATH.
stub_bin="$(mktemp -d)"
cat > "$stub_bin/claude" <<'STUB'
#!/usr/bin/env bash
state="${CLAUDE_STUB_STATE:?}"
if [[ "$1 $2" == "plugin list" ]]; then cat "$state/plugins" 2>/dev/null; exit 0; fi
if [[ "$1 $2 $3" == "plugin marketplace list" ]]; then exit 0; fi
echo "CLAUDE $*"
IFS= read -r -t 1 answer && echo "READ-STDIN $answer"
if [[ "$2" == install ]]; then
  [[ -n "${CLAUDE_STUB_HANG:-}" ]] && exec sleep 30
  echo "$3" >> "$state/plugins"
fi
exit 0
STUB
chmod +x "$stub_bin/claude"
claude_state="$(mktemp -d)"
# A "y" waits on stdin: an install that could read it could answer a prompt.
cl_out="$(PATH="$stub_bin:$PATH" CLAUDE_STUB_STATE="$claude_state" install_claude_plugin plugin-code-review 2>&1 <<< "y")"
assert_contains "$cl_out" "CLAUDE plugin marketplace add anthropics/claude-plugins-official --scope user" "the official marketplace is added when missing"
assert_contains "$cl_out" "CLAUDE plugin install code-review@claude-plugins-official --scope user" "plugins install from the official marketplace, user scope"
assert_not_contains "$cl_out" "READ-STDIN" "claude plugin commands never read stdin"
[[ "$CLAUDE_MARKETPLACE_REPO" == "anthropics/claude-plugins-official" && "$(grep -c 'marketplace add' "$INSTALLER")" -eq 1 ]] && pass "only the official marketplace is ever added" || fail "only the official marketplace is ever added"
hang_start=$SECONDS
hang_out="$(PATH="$stub_bin:$PATH" CLAUDE_STUB_STATE="$claude_state" CLAUDE_STUB_HANG=1 CLAUDE_PLUGIN_TIMEOUT=2 install_claude_plugin plugin-hookify 2>&1; echo "rc=$?")"
assert_contains "$hang_out" "gave no answer in 2s" "a hung plugin install is stopped by the timeout"
assert_not_contains "$hang_out" "rc=0" "a hung plugin install fails"
(( SECONDS - hang_start < 20 )) && pass "the timeout ends the hang quickly" || fail "the timeout ends the hang quickly"

verify_out="$(PATH="$stub_bin:$PATH" CLAUDE_STUB_STATE="$(mktemp -d)" bash -c '
  source "$1"
  detect_pkg_mgr() { echo apt; }
  STATE_DIR="$(mktemp -d)"; INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"
  main --tools plugin-hookify </dev/null
' _ "$INSTALLER" 2>&1)"
assert_contains "$verify_out" "Successfully installed: plugin-hookify" "a plugin installed this run is detected (cache refreshed)"

# ── Servers: no service start before the loopback bind (apt) ─────────────────
policy_tmp="$(mktemp -d)"
policy_out="$(
  POLICY_RC_D="$policy_tmp/policy-rc.d"
  sudo() { "$@"; }
  install_pkg() { if [[ -x "$POLICY_RC_D" ]] && "$POLICY_RC_D" nginx start; then echo "POLICY-ALLOWS"; else echo "POLICY-DENIES rc=$?"; fi; echo "INSTALL $*"; return "${INSTALL_RC:-0}"; }
  apt_install_no_autostart nginx
  echo "after-ok exists=$([[ -e "$POLICY_RC_D" ]] && echo yes || echo no)"
  INSTALL_RC=100 apt_install_no_autostart nginx; echo "fail-rc=$?"
  echo "after-fail exists=$([[ -e "$POLICY_RC_D" ]] && echo yes || echo no)"
)"
assert_contains "$policy_out" "POLICY-DENIES rc=101" "apt server installs run under a policy-rc.d that answers 101"
assert_contains "$policy_out" "after-ok exists=no" "policy-rc.d is removed after a good install"
assert_contains "$policy_out" "fail-rc=100" "a failed install keeps its exit code"
assert_contains "$policy_out" "after-fail exists=no" "policy-rc.d is removed after a failed install"
printf '#!/bin/sh\nexit 0\n' > "$policy_tmp/policy-rc.d"
foreign_out="$(POLICY_RC_D="$policy_tmp/policy-rc.d"; sudo() { "$@"; }; install_pkg() { echo "INSTALL $*"; }; apt_install_no_autostart nginx 2>&1; cat "$POLICY_RC_D")"
assert_contains "$foreign_out" "not distrodeck's" "a foreign policy-rc.d is left in charge"
assert_contains "$foreign_out" "exit 0" "a foreign policy-rc.d is not overwritten"
order_out="$(
  sudo() { "$@"; }
  apt-cache() { printf 'Candidate: 1.0\n'; }
  apt_install_no_autostart() { echo "NOSTART $*"; }
  install_pkg() { echo "PLAIN $*"; }
  server_setup() { echo "SETUP $*"; }
  install_package_tool nginx apt; install_package_tool btop apt; install_package_tool redis apt
)"
assert_contains "$order_out" "NOSTART nginx" "nginx installs with service start held"
assert_contains "$order_out" "NOSTART redis-server" "redis installs with service start held"
assert_contains "$order_out" "PLAIN apt btop" "a non-server package installs normally"
for t in cassandra neo4j; do
  grep -A12 "^install_${t}()" "$INSTALLER" | grep -q "apt_install_no_autostart $t" && pass "$t installs with service start held" || fail "$t installs with service start held"
done

# ── Debian release names ─────────────────────────────────────────────────────
debian_cache() { case "$2" in mysql-server|valkey-server) printf 'Candidate: (none)\n';; *) printf 'Candidate: 1:11.8\n';; esac; }
deb_mysql="$( apt-cache() { debian_cache "$@"; }; package_tool_pkg mysql apt 2>&1 )"
assert_contains "$deb_mysql" "default-mysql-server" "mysql on Debian installs default-mysql-server"
assert_contains "$deb_mysql" "MariaDB" "mysql on Debian says it is MariaDB"
assert_contains "$( apt-cache() { debian_cache "$@"; }; server_unit mysql apt )" "mariadb" "mysql on Debian runs the mariadb unit"
deb_valkey="$( apt-cache() { debian_cache "$@"; }; package_tool_pkg valkey apt 2>&1; echo "pkg=[$(package_tool_pkg valkey apt 2>/dev/null)]" )"
assert_contains "$deb_valkey" "bookworm-backports" "valkey on bookworm points at backports"
assert_contains "$deb_valkey" "pkg=[]" "valkey on bookworm installs nothing"
ub_mysql="$( apt-cache() { printf 'Candidate: 8.0\n'; }; package_tool_pkg mysql apt 2>/dev/null; server_unit mysql apt )"
assert_contains "$ub_mysql" "mysql-server" "mysql on Ubuntu stays mysql-server"
assert_not_contains "$ub_mysql" "mariadb" "mysql on Ubuntu keeps the mysql unit"

# ── MinIO, Qdrant on macOS ───────────────────────────────────────────────────
minio_out="$( brew() { echo "BREW $*"; }; server_setup minio brew 2>&1 )"
assert_not_contains "$minio_out" "BREW services" "minio is never started by brew services (it binds :9000)"
assert_contains "$minio_out" "--address 127.0.0.1:9000" "minio prints a loopback run command"
[[ -z "$(spec_field qdrant brew)" ]] && pass "qdrant has no Homebrew formula" || fail "qdrant has no Homebrew formula"

# ── Milvus matches standalone_embed.sh ───────────────────────────────────────
milvus_state="$(mktemp -d)"
milvus_args="$(STATE_DIR="$milvus_state" container_args milvus | tr '\n' ' ')"
for want in "seccomp:unconfined" "ETCD_CONFIG_PATH=/milvus/configs/embedEtcd.yaml" "DEPLOY_MODE=STANDALONE" "$milvus_state/milvus/embedEtcd.yaml:/milvus/configs/embedEtcd.yaml" "milvus run standalone"; do
  assert_contains "$milvus_args" "$want" "milvus run has $want"
done
grep -q "quota-backend-bytes: 4294967296" "$milvus_state/milvus/embedEtcd.yaml" && pass "milvus embedEtcd.yaml is written" || fail "milvus embedEtcd.yaml is written"

# ── Port check without ss ────────────────────────────────────────────────────
ns_holder="$(
  command() { [[ "$2" == ss ]] && return 1; builtin command "$@"; }
  lsof() { :; }
  netstat() { printf 'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)\ntcp46      0      0  *.6333                 *.*                    LISTEN\n'; }
  port_holder 6333; echo "rc=$?"; port_holder 6334; echo "rc=$?"
)"
assert_contains "$ns_holder" "another user's process" "port_holder sees another user's listener through netstat"
assert_contains "$ns_holder" "rc=1" "port_holder reports a free port as free"

# ── Detection and MongoDB releases ───────────────────────────────────────────
pgv="$( detect_pkg_mgr() { echo apt; }; pg_major() { echo 17; }; native_pkg_installed() { echo "ASKED $2"; return 1; }; command() { [[ "$2" == pipx || "$2" == flatpak ]] && return 1; builtin command "$@"; }; package_tool_installed pgvector )"
assert_contains "$pgv" "ASKED postgresql-17-pgvector" "pgvector detection asks for the real package name"
trixie_os="$(mktemp)"; printf 'ID=debian\nVERSION_CODENAME=trixie\n' > "$trixie_os"
assert_contains "$(OS_RELEASE_FILE="$trixie_os" mongodb_apt_target 2>&1)" "debian trixie main" "MongoDB apt target for Debian trixie"

# ── Signing key pins (fixture keys in tests/fixtures/keys) ───────────────────
KEYS="$REPO_ROOT/tests/fixtures/keys"
FPR_A=98BBB2E9F66810576B9A59034021A45345209A33
FPR_B=5C8A6C806C39769FF516968319D85A1B7E79951C
if command -v gpg >/dev/null 2>&1; then
  assert_exit 0 "a key with the pinned fingerprint is accepted" verify_key_fingerprint "$KEYS/test-key-a.asc" "$FPR_A"
  assert_exit 1 "a different key is refused" verify_key_fingerprint "$KEYS/test-key-b.asc" "$FPR_A"
  assert_exit 1 "the pinned key plus an extra key is refused" verify_key_fingerprint "$KEYS/test-keys-ab.asc" "$FPR_A"
  assert_exit 1 "a file with no key is refused" verify_key_fingerprint "$KEYS/not-a-key.txt" "$FPR_A"
  [[ "$MONGODB_KEY_FINGERPRINT" == *41DE058A4E7DCA05 && ${#MONGODB_KEY_FINGERPRINT} -eq 40 ]] && pass "MongoDB pin is the full 8.0 key fingerprint" || fail "MongoDB pin is the full 8.0 key fingerprint"
  [[ "$NEO4J_KEY_FINGERPRINT" == *59D700E4D37F5F19 && ${#NEO4J_KEY_FINGERPRINT} -eq 40 ]] && pass "Neo4j pin is the full key fingerprint" || fail "Neo4j pin is the full key fingerprint"
  for case in "b:refuse" "a:accept"; do
    key="${case%%:*}"
    mongo_pin_tmp="$(mktemp -d)"
    pin_out="$(
      MONGODB_KEY_FINGERPRINT="$FPR_A"
      # shellcheck disable=SC2034  # read by the sourced installer
      MONGODB_YUM_REPO="$mongo_pin_tmp/mongodb-org.repo"
      # shellcheck disable=SC2034  # read by the sourced installer
      MONGODB_RPM_KEY="$mongo_pin_tmp/rpm.key"
      printf 'ID=rocky\nVERSION_ID=9.4\n' > "$mongo_pin_tmp/os"; OS_RELEASE_FILE="$mongo_pin_tmp/os"
      sudo() { "$@"; }
      download_file() { cp "$KEYS/test-key-$key.asc" "$2"; }
      mongodb_repo_setup dnf 2>&1; echo "rc=$?"; cat "$MONGODB_YUM_REPO" 2>/dev/null
    )"
    if [[ "$key" == b ]]; then
      assert_contains "$pin_out" "fingerprint mismatch" "MongoDB dnf refuses a key with the wrong fingerprint"
      [[ ! -e "$mongo_pin_tmp/mongodb-org.repo" && ! -e "$mongo_pin_tmp/rpm.key" ]] && pass "a refused key writes no repo file" || fail "a refused key writes no repo file"
    else
      assert_contains "$pin_out" "gpgkey=file://$mongo_pin_tmp/rpm.key" "MongoDB dnf repo uses the verified local key"
    fi
    rm -rf "$mongo_pin_tmp"
  done
  vend_tmp="$(mktemp -d)"
  vend_out="$(
    sudo() { "$@"; }
    install() { cp "${@: -2:1}" "${@: -1}" 2>/dev/null || :; }
    tee() { command tee "$vend_tmp/list" >/dev/null; }
    download_file() { cp "$KEYS/$VEND_KEY" "$2"; }
    VEND_KEY=test-key-b.asc apt_vendor_repo neo4j https://k https://r stable latest "$FPR_A" 2>&1; echo "pinned-wrong rc=$?"
    VEND_KEY=test-keys-ab.asc apt_vendor_repo cassandra https://k https://r 50x main 2>&1; echo "unpinned rc=$?"
    VEND_KEY=not-a-key.txt apt_vendor_repo cassandra https://k https://r 50x main 2>&1; echo "nokey rc=$?"
  )"
  assert_contains "$vend_out" "pinned-wrong rc=1" "apt_vendor_repo refuses a key that misses the pin"
  assert_contains "$vend_out" "signing keys: $FPR_A $FPR_B" "cassandra logs every KEYS fingerprint"
  assert_contains "$vend_out" "unpinned rc=0" "cassandra accepts a KEYS file with keys"
  assert_contains "$vend_out" "nokey rc=1" "cassandra refuses a KEYS file with no key"
  grep -q 'stable latest "\$NEO4J_KEY_FINGERPRINT"' "$INSTALLER" && pass "neo4j repo setup passes its pin" || fail "neo4j repo setup passes its pin"
  rm -rf "$vend_tmp"
else
  echo "SKIP: gpg not available; key pin tests skipped."
fi

# ── Uninstall removes the concrete server packages ───────────────────────────
dpkg_installed="postgresql postgresql-16 postgresql-17 postgresql-17-pgvector postgresql-client-17 postgresql-common mysql-server mysql-server-8.0 mysql-server-core-8.0 default-mysql-server default-mysql-server-core mariadb-server mariadb-server-core redis-server redis-tools apache2 apache2-bin nginx default-jdk default-jdk-headless openjdk-17-jdk openjdk-17-jdk-headless openjdk-21-jdk openjdk-21-jdk-headless"
fake_dpkg_query() {
  # dpkg-query -W -f=FMT PATTERN...; answers from $dpkg_installed with shell globs.
  local fmt="" pat p out=1
  shift  # -W
  if [[ "$1" == -f=* ]]; then fmt="${1#-f=}"; shift; fi
  if [[ "$fmt" == '${Depends}' ]]; then
    [[ "$1" == default-jdk ]] && printf 'default-jdk-headless (= 2:1.17), openjdk-17-jdk, libc6'
    return 0
  fi
  for pat in "$@"; do
    for p in $dpkg_installed; do
      # shellcheck disable=SC2053  # glob match on purpose
      if [[ "$p" == $pat ]]; then printf 'installed %s\n' "$p"; out=0; fi
    done
  done
  return "$out"
}
rm_out="$(
  dpkg-query() { fake_dpkg_query "$@"; }
  apt-cache() { printf 'Candidate: 8.0\n'; }
  for t in postgresql pgvector mysql redis apache2 nginx; do echo "$t: $(server_remove_pkgs "$t" apt x)"; done
  echo "dnf: $(server_remove_pkgs postgresql dnf postgresql-server)"
)"
assert_contains "$rm_out" "postgresql: postgresql postgresql-16 postgresql-17 postgresql-17-pgvector" "postgresql uninstall names every server major and its pgvector"
assert_not_contains "$rm_out" "postgresql-client-17" "postgresql uninstall keeps the client"
assert_not_contains "$rm_out" "postgresql-common" "postgresql uninstall keeps postgresql-common"
assert_contains "$rm_out" "pgvector: postgresql-17-pgvector" "pgvector uninstall names the versioned package"
assert_contains "$rm_out" "mysql: mysql-server mysql-server-8.0 mysql-server-core-8.0" "mysql uninstall names the versioned server"
assert_not_contains "$(grep '^mysql:' <<< "$rm_out")" "mariadb" "mysql on Ubuntu never removes MariaDB"
assert_contains "$rm_out" "redis: redis-server redis-tools" "redis uninstall removes the binary package"
assert_contains "$rm_out" "apache2: apache2 apache2-bin" "apache2 uninstall removes apache2-bin"
assert_contains "$rm_out" "dnf: postgresql-server" "dnf keeps the concrete spec package"
deb_rm="$( dpkg-query() { fake_dpkg_query "$@"; }; apt-cache() { debian_cache "$@"; }; server_remove_pkgs mysql apt default-mysql-server )"
assert_contains "$deb_rm" "default-mysql-server default-mysql-server-core mariadb-server mariadb-server-core" "mysql on Debian removes the MariaDB server it installed"
full_rm="$(
  dpkg-query() { fake_dpkg_query "$@"; }
  apt-cache() { printf 'Candidate: 8.0\n'; }
  sudo() { echo "SUDO $*"; }
  systemctl() { :; }
  uninstall_pkg() { echo "REMOVE $*"; }
  uninstall_package_tool postgresql apt 2>&1
)"
assert_contains "$full_rm" "REMOVE apt postgresql postgresql-16 postgresql-17 postgresql-17-pgvector" "uninstall_package_tool removes the resolved packages"
assert_contains "$full_rm" "Kept the postgresql data directory" "server uninstall says the data is kept"
assert_not_contains "$full_rm" "autoremove" "server uninstall never autoremoves"
java_rm="$(
  dpkg-query() { fake_dpkg_query "$@"; }
  uninstall_pkg() { echo "REMOVE $*"; }
  JAVA_STATE_FILE=/nonexistent/java-version uninstall_java apt
  JAVA_STATE_FILE="$(mktemp)"; echo 21 > "$JAVA_STATE_FILE"; uninstall_java apt
)"
assert_contains "$java_rm" "REMOVE apt default-jdk default-jdk-headless openjdk-17-jdk openjdk-17-jdk-headless" "legacy default-jdk uninstall removes the JDK behind it"
assert_contains "$java_rm" "REMOVE apt openjdk-21-jdk openjdk-21-jdk-headless" "java uninstall removes the headless JDK too"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "${PASSES} passed, ${FAILURES} failed"
[[ "$FAILURES" -eq 0 ]]
