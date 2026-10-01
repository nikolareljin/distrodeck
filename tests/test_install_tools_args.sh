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
rm -rf "$checkout_tmp"

# ── Categories and the TSV catalog ───────────────────────────────────────────

set +e
tsv="$("$INSTALLER" --list-catalog --format tsv 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "--list-catalog --format tsv exits 0" || fail "--list-catalog --format tsv exits 0" "rc=$rc"
bad_lines="$(awk -F'\t' 'NF != 6 || $5 !~ /^[01]$/ || $6 !~ /^[01]$/' <<< "$tsv")"
[[ -z "$bad_lines" ]] && pass "every TSV line has 6 columns with 0/1 flags" || fail "every TSV line has 6 columns with 0/1 flags" "$bad_lines"
[[ "$tsv" != *$'\e'* ]] && pass "TSV catalog has no ANSI" || fail "TSV catalog has no ANSI"
mongo_line="$(grep -P '\tmongodb\t' <<< "$tsv")"
expected_prefix="$(printf 'db\tDatabases\tmongodb\tMongoDB Community server + mongosh\t1\t')"
if [[ "$mongo_line" == "$expected_prefix"[01] ]]; then
  pass "TSV column order is category_id, category_label, tool, label, opt_in, installed"
else
  fail "TSV column order is category_id, category_label, tool, label, opt_in, installed" "$mongo_line"
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
for id in shell editors system network backup dev ai ides lang devops media graphics util db apps; do
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
  main --category graphics,db </dev/null
' _ "$INSTALLER" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && pass "--category graphics,db exits 0" || fail "--category graphics,db exits 0" "$cat_out"
assert_contains "$cat_out" "INSTALL krita" "--category installs the category's tools"
order="$(grep -o '^INSTALL [a-z]*' <<< "$cat_out" | tr '\n' ' ')"
[[ "$order" == "INSTALL blender INSTALL darktable INSTALL gimp INSTALL inkscape INSTALL krita " ]] && pass "--category installs in catalog order" || fail "--category installs in catalog order" "$order"
assert_not_contains "$cat_out" "INSTALL mongodb" "--category never installs an opt-in tool"
assert_contains "$cat_out" "Category db has only opt-in tools" "--category explains an all-opt-in category"
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
  package_tool_spec() { echo "- - - - - nothing"; }
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
tui_out="$(timeout 30 bash -c '
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

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "${PASSES} passed, ${FAILURES} failed"
[[ "$FAILURES" -eq 0 ]]
