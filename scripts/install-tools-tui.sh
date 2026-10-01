#!/usr/bin/env bash
# SCRIPT: install-tools-tui.sh
# DESCRIPTION: TUI installer for common developer tools.
# USAGE: ./install-tools-tui.sh [--all]
# PARAMETERS: Optional flag --all installs all tools without interactive selection.
# EXAMPLE: ./install-tools-tui.sh --all
# ----------------------------------------------------

# macOS ships bash 3.2; this script needs bash 4.4+ (namerefs, associative
# arrays, empty "${arr[@]}" under set -u). Re-exec under Homebrew bash 5 when it is there, otherwise say how.
ensure_modern_bash() {
  local major="${1:-${BASH_VERSINFO[0]}}" minor="${2:-${BASH_VERSINFO[1]}}"
  shift 2
  if (( major > 4 || (major == 4 && minor >= 4) )); then
    return 0
  fi
  local brew_bash=""
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    brew_bash="$(brew --prefix)/bin/bash"
  fi
  if [[ -n "$brew_bash" && -x "$brew_bash" && "${DISTRODECK_REEXEC:-}" != "1" ]]; then
    DISTRODECK_REEXEC=1 exec "$brew_bash" "$0" "$@"
  fi
  echo "install-tools needs bash 4.4 or newer (this is ${BASH_VERSION})." >&2
  echo "On macOS: brew install bash, then run it again." >&2
  exit 2
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ensure_modern_bash "" "" "$@"
fi

set -euo pipefail
# Tool installations are wrapped in subshells (see main loop) to isolate failures
# while preserving -e for the rest of the script to catch unexpected errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-}"
LOOKED_IN=()

helper_candidates=(
  "${SCRIPT_DIR}/script-helpers"
  "${SCRIPT_DIR}/../script-helpers"
  "/usr/local/share/distrodeck/scripts/script-helpers"
  "/usr/share/distrodeck/scripts/script-helpers"
  "/usr/lib/distrodeck/scripts/script-helpers"
)

if [[ -n "$SCRIPT_HELPERS_DIR" ]]; then
  LOOKED_IN+=("$SCRIPT_HELPERS_DIR")
fi

for candidate in "${helper_candidates[@]}"; do
  if [[ " ${LOOKED_IN[*]} " != *" ${candidate} "* ]]; then
    LOOKED_IN+=("$candidate")
  fi
done

if [[ -n "$SCRIPT_HELPERS_DIR" && -d "$SCRIPT_HELPERS_DIR" ]]; then
  :
else
  SCRIPT_HELPERS_DIR=""
  for candidate in "${helper_candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      SCRIPT_HELPERS_DIR="$candidate"
      break
    fi
  done
fi

# Check if script-helpers directory exists
if [[ -z "$SCRIPT_HELPERS_DIR" || ! -d "$SCRIPT_HELPERS_DIR" ]]; then
  echo "The script-helpers directory is missing."
  echo "Looked in:"
  for candidate in "${LOOKED_IN[@]}"; do
    echo "  ${candidate}"
  done
  if [[ -e "${SCRIPT_DIR}/../.git" || -e "${SCRIPT_DIR}/../scripts/.git" ]]; then
    # Source checkout likely missing submodules.
    echo "Please run the update.sh script to initialize submodules:"
    echo "  ./scripts/update.sh"
  else
    echo "If running from an installed package, please reinstall distrodeck to restore helper files."
  fi
  exit 1
fi

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging dialog

# ─────────────────────────────────────────────────────────────────────────────
# Fallback versions for GitHub release downloads
# ─────────────────────────────────────────────────────────────────────────────
# These versions are used when the GitHub API fails to return the latest release.
# This can happen due to rate limiting, network issues, or API changes.
#
# MAINTENANCE: Update these periodically to recent stable versions.
# Check each tool's GitHub releases page for current versions:
#   - lazygit:  https://github.com/jesseduffield/lazygit/releases
#   - k9s:      https://github.com/derailed/k9s/releases
#   - glow:     https://github.com/charmbracelet/glow/releases
#   - delta:    https://github.com/dandavison/delta/releases
#   - bfg:      https://github.com/rtyley/bfg-repo-cleaner/releases
#   - rustdesk: https://github.com/rustdesk/rustdesk/releases
#
# NVM is not a release download; it is cloned and checked out at this tag.
#   - nvm:      https://github.com/nvm-sh/nvm/releases
#
# Last updated: 2026-08-21
FALLBACK_VERSION_LAZYGIT="0.64.1"
FALLBACK_VERSION_K9S="v0.51.0"
FALLBACK_VERSION_GLOW="3.0.0"
FALLBACK_VERSION_DELTA="0.19.2"
FALLBACK_VERSION_BFG="1.15.0"
FALLBACK_VERSION_RUSTDESK="v1.4.9"
NVM_PINNED_VERSION="v0.40.7"

# Default Node.js major installed by the `node` tool. Node 20 reached
# end-of-life in April 2026; 24 is the current Active LTS.
NODE_DEFAULT_MAJOR="24"
# Additional Node major installed under nvm so users can switch between them.
NODE_ALT_MAJOR="22"

# ─────────────────────────────────────────────────────────────────────────────
# State tracking for installed tools
# ─────────────────────────────────────────────────────────────────────────────

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/distrodeck"
INSTALLED_TOOLS_FILE="$STATE_DIR/installed-tools.txt"

# Ensure state directory exists
ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

# Load previously tracked installed tools into an associative array
# Usage: declare -A tracked; load_tracked_tools tracked
load_tracked_tools() {
  local -n _tracked=$1
  if [[ -f "$INSTALLED_TOOLS_FILE" ]]; then
    while IFS= read -r tool; do
      [[ -n "$tool" ]] && _tracked["$tool"]="true"
    done < "$INSTALLED_TOOLS_FILE"
  fi
}

# Save tracked installed tools from an array
# Usage: save_tracked_tools "tool1" "tool2" ...
save_tracked_tools() {
  ensure_state_dir
  printf "%s\n" "$@" > "$INSTALLED_TOOLS_FILE"
}

# Append a tool to the tracked list (if not already present)
add_tracked_tool() {
  ensure_state_dir
  local tool="$1"
  if ! grep -qx "$tool" "$INSTALLED_TOOLS_FILE" 2>/dev/null; then
    echo "$tool" >> "$INSTALLED_TOOLS_FILE"
  fi
}

# Remove a tool from the tracked list
remove_tracked_tool() {
  local tool="$1"
  if [[ -f "$INSTALLED_TOOLS_FILE" ]]; then
    local tmp_file
    tmp_file="$(mktemp)"
    grep -vx "$tool" "$INSTALLED_TOOLS_FILE" > "$tmp_file" || true
    mv "$tmp_file" "$INSTALLED_TOOLS_FILE"
  fi
}

detect_pkg_mgr() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v brew >/dev/null 2>&1; then echo "brew"; else echo "unknown"; fi
  elif command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo "unknown"
  fi
}

install_pkg() {
  local mgr="$1"; shift
  case "$mgr" in
    apt)
      # Allow apt-get update to have some errors (e.g., broken PPAs) but still try to install
      sudo apt-get update || log_warn "apt-get update had errors, attempting install anyway..."
      sudo apt-get install -y "$@"
      ;;
    dnf) sudo dnf install -y "$@";;
    pacman) sudo pacman -S --needed --noconfirm "$@";;
    zypper) sudo zypper install -y "$@";;
    brew)
      # Never with sudo. cask:<name> is a cask, anything else a formula.
      local name
      for name in "$@"; do
        if [[ "$name" == cask:* ]]; then
          brew install --cask "${name#cask:}" || return 1
        else
          brew install "$name" || return 1
        fi
      done
      ;;
    *) return 1;;
  esac
}

uninstall_pkg() {
  local mgr="$1"; shift
  case "$mgr" in
    apt) sudo apt-get remove -y "$@";;
    dnf) sudo dnf remove -y "$@";;
    pacman) sudo pacman -Rs --noconfirm "$@";;
    zypper) sudo zypper remove -y "$@";;
    brew)
      local name
      for name in "$@"; do
        if [[ "$name" == cask:* ]]; then
          brew uninstall --cask "${name#cask:}" || return 1
        else
          brew uninstall "$name" || return 1
        fi
      done
      ;;
    *) return 1;;
  esac
}

ensure_dialog() {
  if command -v dialog >/dev/null 2>&1; then
    return 0
  fi
  local mgr
  mgr="$(detect_pkg_mgr)"
  if [[ "$mgr" == "unknown" ]]; then
    log_error "dialog is required but no supported package manager was found."
    return 1
  fi
  log_warn "dialog not found. Installing..."
  install_pkg "$mgr" dialog
}

install_docker() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" docker.io;;
    dnf|pacman|zypper) install_pkg "$mgr" docker;;
    *) log_warn "Docker install not supported for this distro.";;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker || true
  fi
}

install_nala() {
  local mgr="$1"
  if [[ "$mgr" == "apt" ]]; then
    install_pkg "$mgr" nala
  else
    log_warn "Nala is only available on apt-based distros."
  fi
}

install_dialog_pkg() {
  install_pkg "$1" dialog
}

install_jq() {
  install_pkg "$1" jq
}

install_ripgrep() {
  install_pkg "$1" ripgrep || log_warn "Failed to install ripgrep from repos."
}

install_fd() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" fd-find;;
    dnf|pacman|zypper) install_pkg "$mgr" fd;;
    *) log_warn "fd install not supported for this distro.";;
  esac
}

install_bat() {
  install_pkg "$1" bat || log_warn "Failed to install bat from repos."
}

install_eza() {
  install_pkg "$1" eza || log_warn "Failed to install eza from repos."
}

install_fzf() {
  install_pkg "$1" fzf || log_warn "Failed to install fzf from repos."
}

install_zoxide() {
  install_pkg "$1" zoxide || log_warn "Failed to install zoxide from repos."
}

install_yq() {
  install_pkg "$1" yq || log_warn "Failed to install yq from repos."
}

install_curl() {
  install_pkg "$1" curl
}

install_wget() {
  install_pkg "$1" wget
}

install_git() {
  install_pkg "$1" git
}

install_ansible() {
  install_pkg "$1" ansible || log_warn "Failed to install ansible from repos."
}

install_adb() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" android-tools-adb;;
    dnf|pacman|zypper) install_pkg "$mgr" android-tools;;
    *) log_warn "adb install not supported for this distro.";;
  esac
}

install_git_lfs() {
  install_pkg "$1" git-lfs || log_warn "Failed to install git-lfs from repos."
}

install_zsh() {
  install_pkg "$1" zsh || log_warn "Failed to install zsh from repos."
}

install_starship() {
  install_pkg "$1" starship || log_warn "Failed to install starship from repos."
}

install_tmux() {
  install_pkg "$1" tmux || log_warn "Failed to install tmux from repos."
}

install_htop() {
  install_pkg "$1" htop || log_warn "Failed to install htop from repos."
}

install_ncdu() {
  install_pkg "$1" ncdu || log_warn "Failed to install ncdu from repos."
}

install_duf() {
  install_pkg "$1" duf || log_warn "Failed to install duf from repos."
}

install_tree() {
  install_pkg "$1" tree || log_warn "Failed to install tree from repos."
}

install_build_tools() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" build-essential;;
    dnf) install_pkg "$mgr" gcc gcc-c++ make;;
    pacman) install_pkg "$mgr" base-devel;;
    zypper) install_pkg "$mgr" gcc gcc-c++ make;;
    *) log_warn "Build tools install not supported for this distro.";;
  esac
}

install_neovim() {
  install_pkg "$1" neovim || log_warn "Failed to install neovim from repos."
}

install_micro() {
  install_pkg "$1" micro || log_warn "Failed to install micro from repos."
}

install_node_major_version() {
  local mgr="$1" node_major="${2:-20}"
  case "$mgr" in
    apt)
      # Try system repo first (Ubuntu 22.04+ has Node 18+)
      if install_pkg "$mgr" nodejs npm 2>/dev/null; then
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return
        fi
        log_warn "System repository Node.js is older than ${node_major}; using NodeSource fallback."
      fi
      # Fall back to NodeSource repository (manual setup, no piped scripts)
      log_info "Adding NodeSource repository for Node.js ${node_major}.x..."
      if ! command -v curl >/dev/null 2>&1; then
        install_pkg "$mgr" curl ca-certificates || true
      fi
      if ! command -v gpg >/dev/null 2>&1; then
        install_pkg "$mgr" gnupg || true
      fi
      if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl is required to download the NodeSource GPG key."
        return 1
      fi
      if ! command -v gpg >/dev/null 2>&1; then
        log_warn "gpg is required to install the NodeSource apt repository key."
        return 1
      fi
      sudo mkdir -p /etc/apt/keyrings
      local keyring="/etc/apt/keyrings/nodesource.gpg"
      local tmp_key
      tmp_key="$(mktemp)"
      if curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key -o "$tmp_key"; then
        if ! sudo gpg --dearmor -o "$keyring" < "$tmp_key" 2>/dev/null && \
          ! cat "$tmp_key" | sudo gpg --dearmor -o "$keyring"; then
          rm -f "$tmp_key"
          sudo rm -f "$keyring" 2>/dev/null || true
          log_warn "Failed to install NodeSource apt repository key."
          return 1
        fi
        sudo chmod 0755 /etc/apt/keyrings
        sudo chmod 0644 "$keyring"
        rm -f "$tmp_key"
        echo "deb [signed-by=$keyring] https://deb.nodesource.com/node_${node_major}.x nodistro main" | \
          sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
        if ! sudo apt-get update; then
          log_warn "apt-get update reported errors after adding NodeSource; continuing with Node.js installation attempt."
        fi
        if ! install_pkg "$mgr" nodejs; then
          sudo rm -f /etc/apt/sources.list.d/nodesource.list "$keyring" 2>/dev/null || true
          return 1
        fi
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return 0
        fi
        log_warn "NodeSource did not provide Node.js ${node_major}+."
        sudo rm -f /etc/apt/sources.list.d/nodesource.list "$keyring" 2>/dev/null || true
        return 1
      else
        rm -f "$tmp_key"
        log_warn "Failed to download NodeSource GPG key."
        return 1
      fi
      ;;
    dnf)
      # Try system repo first (Fedora has recent Node.js)
      if install_pkg "$mgr" nodejs npm 2>/dev/null; then
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return
        fi
        log_warn "System repository Node.js is older than ${node_major}; using NodeSource fallback."
      fi
      # Fall back to NodeSource repository (manual setup)
      log_info "Adding NodeSource repository for Node.js ${node_major}.x..."
      if ! command -v curl >/dev/null 2>&1; then
        install_pkg "$mgr" curl ca-certificates || true
      fi
      if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl is required to download the NodeSource GPG key."
        return 1
      fi
      local keyring="/etc/pki/rpm-gpg/NODESOURCE-GPG-SIGNING-KEY-EL"
      local tmp_key
      tmp_key="$(mktemp)"
      if curl -fsSL https://rpm.nodesource.com/gpgkey/ns-operations-public.key -o "$tmp_key"; then
        sudo mkdir -p /etc/pki/rpm-gpg
        sudo cp "$tmp_key" "$keyring"
        rm -f "$tmp_key"
        cat << REPO | sudo tee /etc/yum.repos.d/nodesource-nodistro.repo > /dev/null
[nodesource-nodistro]
name=Node.js Packages for Linux RPM based distros - x86_64
baseurl=https://rpm.nodesource.com/pub_${node_major}.x/nodistro/x86_64
priority=1
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/NODESOURCE-GPG-SIGNING-KEY-EL
REPO
        if ! install_pkg "$mgr" nodejs; then
          sudo rm -f /etc/yum.repos.d/nodesource-nodistro.repo "$keyring" 2>/dev/null || true
          return 1
        fi
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return 0
        fi
        log_warn "NodeSource did not provide Node.js ${node_major}+."
        sudo rm -f /etc/yum.repos.d/nodesource-nodistro.repo "$keyring" 2>/dev/null || true
        return 1
      else
        rm -f "$tmp_key"
        log_warn "Failed to download NodeSource GPG key."
        return 1
      fi
      ;;
    pacman) install_pkg "$mgr" nodejs npm;;
    zypper)
      # openSUSE ships versioned packages (nodejs22, nodejs24, ...). Fall back
      # to the unversioned package when the requested major is unavailable.
      install_pkg "$mgr" "nodejs${node_major}" "npm${node_major}" || install_pkg "$mgr" nodejs npm
      ;;
    *) log_warn "Node install not supported for this distro.";;
  esac
}

# Directory nvm is cloned into. Overridable for tests.
NVM_INSTALL_DIR="${NVM_DIR:-$HOME/.nvm}"

# Shell profile block markers, so the wiring stays idempotent and removable.
NVM_PROFILE_BEGIN="# >>> distrodeck nvm >>>"
NVM_PROFILE_END="# <<< distrodeck nvm <<<"

# Append the nvm sourcing block to a shell profile if it is not already there.
# Usage: wire_nvm_profile /path/to/.bashrc
wire_nvm_profile() {
  local profile="$1"
  [[ -e "$profile" ]] || return 0
  if grep -Fq "$NVM_PROFILE_BEGIN" "$profile" 2>/dev/null; then
    return 0
  fi
  {
    echo ""
    echo "$NVM_PROFILE_BEGIN"
    printf 'export NVM_DIR=%q\n' "$NVM_INSTALL_DIR"
    echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'
    echo "$NVM_PROFILE_END"
  } >> "$profile"
  log_info "Wired nvm into ${profile}."
}

# Remove the distrodeck-managed nvm block from a shell profile.
unwire_nvm_profile() {
  local profile="$1"
  [[ -f "$profile" ]] || return 0
  grep -Fq "$NVM_PROFILE_BEGIN" "$profile" 2>/dev/null || return 0
  grep -Fq "$NVM_PROFILE_END" "$profile" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp)"
  if ! sed "/${NVM_PROFILE_BEGIN}/,/${NVM_PROFILE_END}/d" "$profile" > "$tmp"; then
    rm -f "$tmp"
    log_error "Failed to remove nvm wiring from ${profile}."
    return 1
  fi
  if ! mv "$tmp" "$profile"; then
    rm -f "$tmp"
    log_error "Failed to update ${profile}."
    return 1
  fi
  log_info "Removed nvm wiring from ${profile}."
}

# Install nvm by cloning the repository at a pinned tag. Deliberately avoids
# piping the upstream install script into a shell: the clone is deterministic,
# reviewable, and needs no sudo, which keeps `node` usable in --all runs.
install_nvm() {
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git is required to install nvm; skipping nvm setup."
    return 1
  fi

  if [[ -d "$NVM_INSTALL_DIR/.git" ]]; then
    log_info "Updating existing nvm in ${NVM_INSTALL_DIR} to ${NVM_PINNED_VERSION}..."
    git -C "$NVM_INSTALL_DIR" fetch --tags --quiet origin || {
      log_warn "Failed to fetch nvm tags; keeping the existing checkout."
      return 1
    }
  elif [[ -d "$NVM_INSTALL_DIR" ]]; then
    log_warn "${NVM_INSTALL_DIR} exists but is not a git checkout; leaving it untouched."
    return 1
  else
    log_info "Installing nvm ${NVM_PINNED_VERSION} into ${NVM_INSTALL_DIR}..."
    git clone --quiet https://github.com/nvm-sh/nvm.git "$NVM_INSTALL_DIR" || {
      log_warn "Failed to clone nvm."
      return 1
    }
  fi

  git -C "$NVM_INSTALL_DIR" checkout --quiet "$NVM_PINNED_VERSION" || {
    log_warn "Failed to check out nvm ${NVM_PINNED_VERSION}."
    return 1
  }

  wire_nvm_profile "$HOME/.bashrc"
  wire_nvm_profile "$HOME/.zshrc"

  # nvm is a shell function, not a binary: source it before use.
  # shellcheck source=/dev/null
  export NVM_DIR="$NVM_INSTALL_DIR"
  if ! . "$NVM_INSTALL_DIR/nvm.sh"; then
    log_warn "Failed to source nvm; Node versions were not installed via nvm."
    return 1
  fi

  local major
  for major in "$NODE_DEFAULT_MAJOR" "$NODE_ALT_MAJOR"; do
    log_info "Installing Node ${major} via nvm..."
    nvm install "$major" >/dev/null 2>&1 || log_warn "nvm could not install Node ${major}."
  done
  nvm alias default "$NODE_DEFAULT_MAJOR" >/dev/null 2>&1 || true

  log_info "nvm ready. Open a new shell (or run 'source ~/.bashrc') to use it."
  log_info "Switch versions with: nvm use ${NODE_ALT_MAJOR}  /  nvm use ${NODE_DEFAULT_MAJOR}"
  return 0
}

install_node() {
  # System Node keeps sudo, cron, and deb dependencies working; nvm sits on top
  # for per-shell switching between the default and alternate majors.
  install_node_major_version "$1" "$NODE_DEFAULT_MAJOR"
  install_nvm || true
}

install_lazygit() {
  local mgr="$1"

  # For non-apt package managers, try native package first
  if [[ "$mgr" != "apt" ]]; then
    if install_pkg "$mgr" lazygit; then
      return
    fi
    if install_pkg "$mgr" lazygit-gm; then
      return
    fi
  fi

  # Primary method: Download from GitHub releases (most reliable)
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    local os arch url tmp_dir bin_path version api_url
    os="$(uname -s)"
    case "$os" in
      Linux) os="Linux";;
      Darwin) os="Darwin";;
      *) log_warn "GitHub release lazygit install not supported for OS: $os";;
    esac

    if [[ "$os" == "Linux" || "$os" == "Darwin" ]]; then
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) arch="x86_64";;
        aarch64|arm64) arch="arm64";;
        armv7l|armv7) arch="armv7";;
        i386|i686) arch="386";;
        *) log_warn "GitHub release lazygit install not supported for arch: $arch"; arch="";;
      esac

      if [[ -n "$arch" ]]; then
        tmp_dir="$(mktemp -d)"
        bin_path="$tmp_dir/lazygit"

        # Get latest version from GitHub API
        api_url="https://api.github.com/repos/jesseduffield/lazygit/releases/latest"
        if download_file "$api_url" "$tmp_dir/lazygit-release.json"; then
          version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"v\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/lazygit-release.json" | head -n1)"
        fi
        if [[ -z "$version" ]]; then
          version="$FALLBACK_VERSION_LAZYGIT"
        fi

        url="https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_${os}_${arch}.tar.gz"
        log_info "Downloading lazygit v${version} from GitHub releases..."

        if download_file "$url" "$tmp_dir/lazygit.tar.gz"; then
          if tar -xzf "$tmp_dir/lazygit.tar.gz" -C "$tmp_dir"; then
            if [[ -f "$bin_path" ]]; then
              sudo install -m 0755 "$bin_path" /usr/local/bin/lazygit
              log_info "Installed lazygit to /usr/local/bin/lazygit"
              rm -rf "$tmp_dir"
              return
            fi
          fi
        fi
        rm -rf "$tmp_dir"
        log_warn "GitHub release download failed; trying alternative methods..."
      fi
    fi
  fi

  # Fallback: go install
  if ! command -v go >/dev/null 2>&1; then
    log_warn "Go is required for lazygit go-install fallback; installing Go..."
    install_go "$mgr" || true
  fi
  if command -v go >/dev/null 2>&1; then
    GOBIN="${GOBIN:-$HOME/.local/bin}"
    mkdir -p "$GOBIN"
    log_info "Installing lazygit via go install..."
    if GOBIN="$GOBIN" go install github.com/jesseduffield/lazygit@latest; then
      return
    fi
    log_warn "go install failed; trying snap..."
  fi

  # Last resort: snap
  if command -v snap >/dev/null 2>&1; then
    log_info "Installing lazygit via snap..."
    if sudo snap install lazygit; then
      return
    fi
    if sudo snap install lazygit-gm; then
      return
    fi
    log_warn "Snap install failed for lazygit."
  fi

  log_warn "All lazygit installation methods failed."
}

install_lazydocker() {
  if install_pkg "$1" lazydocker; then
    return
  fi

  log_warn "Failed to install lazydocker from repos."
}

# JDK major installed by the `java` tool: 17, 21 (default) or 25.
# Set with --java-version or DISTRODECK_JAVA_VERSION.
JAVA_VERSION="${DISTRODECK_JAVA_VERSION:-21}"
JAVA_SUPPORTED_VERSIONS="17 21 25"
JAVA_STATE_FILE="$STATE_DIR/java-version"

is_supported_java_version() {
  [[ " $JAVA_SUPPORTED_VERSIONS " == *" $1 "* ]]
}

# Print the JDK package for manager $1 and major $2.
java_package() {
  local mgr="$1" version="$2"
  case "$mgr" in
    apt) echo "openjdk-${version}-jdk";;
    dnf|zypper) echo "java-${version}-openjdk-devel";;
    pacman) echo "jdk${version}-openjdk";;
    *) return 1;;
  esac
}

install_java() {
  local mgr="$1" pkg
  if ! is_supported_java_version "$JAVA_VERSION"; then
    log_warn "Unsupported Java version '$JAVA_VERSION'; choose one of: $JAVA_SUPPORTED_VERSIONS."
    return 1
  fi
  if ! pkg="$(java_package "$mgr" "$JAVA_VERSION")"; then
    log_warn "Java install not supported for this distro."
    return 1
  fi
  if ! install_pkg "$mgr" "$pkg"; then
    log_warn "Failed to install $pkg; this release may not package JDK $JAVA_VERSION. Try --java-version with one of: $JAVA_SUPPORTED_VERSIONS."
    return 1
  fi
  ensure_state_dir
  echo "$JAVA_VERSION" > "$JAVA_STATE_FILE"
}

install_rust() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" rustc cargo;;
    dnf) install_pkg "$mgr" rust cargo;;
    pacman) install_pkg "$mgr" rust;;
    zypper) install_pkg "$mgr" rust cargo;;
    *) log_warn "Rust install not supported for this distro.";;
  esac
}

install_go() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" golang;;
    dnf) install_pkg "$mgr" golang;;
    pacman) install_pkg "$mgr" go;;
    zypper) install_pkg "$mgr" go;;
    *) log_warn "Go install not supported for this distro.";;
  esac
}

install_vscode() {
  if command -v snap >/dev/null 2>&1; then
    sudo snap install code --classic
    return
  fi
  local mgr="$1"
  if ! install_pkg "$mgr" code; then
    log_warn "Failed to install VS Code. Install repository may be missing."
  fi
}

install_pkg_simple() {
  install_pkg "$1" "$2" || log_warn "Failed to install $2 from repos."
}

install_image_view() {
  local mgr="$1"
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git is required to install image-view; installing git..."
    install_git "$mgr" || true
  fi
  if ! command -v git >/dev/null 2>&1; then
    log_warn "git still missing; cannot install image-view."
    return 1
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    log_warn "cargo is required to install image-view; installing Rust..."
    install_rust "$mgr" || true
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    log_warn "cargo still missing; cannot install image-view."
    return 1
  fi
  cargo install --git https://github.com/nikolareljin/image-view --bin image-view
}

download_file() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$dest" "$url"
    return $?
  fi
  return 1
}

install_isoforge() {
  local mgr="$1"
  local deb_url="${ISOFORGE_DEB_URL:-${BURN_ISO_DEB_URL:-}}"
  local repo_dir="${ISOFORGE_REPO_DIR:-${BURN_ISO_REPO_DIR:-}}"
  local tmp_dir deb_path

  if [[ -n "$deb_url" ]]; then
    tmp_dir="$(mktemp -d)"
    deb_path="$tmp_dir/isoforge.deb"
    if download_file "$deb_url" "$deb_path"; then
      sudo dpkg -i "$deb_path" || true
      if [[ "$mgr" == "apt" ]]; then
        sudo apt-get -f install -y
      fi
      if dpkg -s isoforge >/dev/null 2>&1; then
        rm -rf "$tmp_dir"
        return 0
      fi
    fi
    rm -rf "$tmp_dir"
  fi

  if [[ -z "$repo_dir" ]]; then
    # burn-iso was renamed to iso-forge; keep finding an older checkout.
    for candidate in "$HOME/Projects/iso-forge" "$HOME/Projects/burn-iso"; do
      if [[ -d "$candidate" ]]; then
        repo_dir="$candidate"
        break
      fi
    done
    repo_dir="${repo_dir:-$HOME/Projects/iso-forge}"
  fi
  if [[ -d "$repo_dir" && -x "$repo_dir/tools/build-deb.sh" ]]; then
    (cd "$repo_dir" && ./tools/build-deb.sh)
    deb_path=$(ls -t "$repo_dir"/dist/*.deb 2>/dev/null | head -n1 || true)
    if [[ -n "$deb_path" ]]; then
      sudo dpkg -i "$deb_path" || true
      if [[ "$mgr" == "apt" ]]; then
        sudo apt-get -f install -y
      fi
      if dpkg -s isoforge >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi

  if [[ "$mgr" == "apt" ]]; then
    install_pkg "$mgr" isoforge || log_warn "Failed to install isoforge from repos."
    return 0
  fi

  log_warn "Isoforge install failed; set ISOFORGE_DEB_URL or ISOFORGE_REPO_DIR for fallback."
  return 1
}

install_php() {
  install_pkg "$1" php || log_warn "Failed to install PHP from repos."
}

install_composer() {
  install_pkg "$1" composer || log_warn "Failed to install Composer from repos."
}

install_tldr() {
  local mgr="$1"

  # Try tealdeer (Rust-based, fast tldr client) first
  case "$mgr" in
    apt)
      # tealdeer is available as 'tldr' in some Ubuntu versions
      if install_pkg "$mgr" tldr 2>/dev/null; then
        return
      fi
      ;;
    dnf|pacman|zypper)
      if install_pkg "$mgr" tealdeer 2>/dev/null || install_pkg "$mgr" tldr 2>/dev/null; then
        return
      fi
      ;;
  esac

  # Fallback: install via cargo (tealdeer)
  if command -v cargo >/dev/null 2>&1; then
    log_info "Installing tealdeer (tldr) via cargo..."
    if cargo install tealdeer; then
      return
    fi
  fi

  # Fallback: install via npm
  if command -v npm >/dev/null 2>&1; then
    log_info "Installing tldr via npm..."
    if sudo npm install -g tldr; then
      return
    fi
  fi

  # Fallback: install via pip
  if command -v pip3 >/dev/null 2>&1; then
    log_info "Installing tldr via pip3..."
    if pip3 install --user tldr; then
      return
    fi
  fi

  log_warn "Failed to install tldr. Install Node.js, Python pip, or Rust cargo for fallback methods."
}

install_bandwhich() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # bandwhich not in default repos, try cargo
      if ! command -v cargo >/dev/null 2>&1; then
        log_warn "cargo is required to install bandwhich; installing Rust..."
        install_rust "$mgr" || true
      fi
      if command -v cargo >/dev/null 2>&1; then
        cargo install bandwhich || log_warn "Failed to install bandwhich via cargo."
      else
        log_warn "cargo still missing; cannot install bandwhich."
      fi
      ;;
    dnf) install_pkg "$mgr" bandwhich || log_warn "Failed to install bandwhich from repos.";;
    pacman) install_pkg "$mgr" bandwhich;;
    zypper)
      if ! command -v cargo >/dev/null 2>&1; then
        install_rust "$mgr" || true
      fi
      if command -v cargo >/dev/null 2>&1; then
        cargo install bandwhich || log_warn "Failed to install bandwhich via cargo."
      fi
      ;;
    *) log_warn "bandwhich install not supported for this distro.";;
  esac
}

install_k9s() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # k9s not in default repos, download from GitHub
      local version url tmp_dir arch os
      tmp_dir="$(mktemp -d)"
      os="Linux"
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) arch="amd64";;
        aarch64|arm64) arch="arm64";;
        *) log_warn "k9s install not supported for arch: $arch"; return 1;;
      esac
      if download_file "https://api.github.com/repos/derailed/k9s/releases/latest" "$tmp_dir/release.json"; then
        version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
      fi
      if [[ -z "$version" ]]; then
        version="$FALLBACK_VERSION_K9S"
      fi
      url="https://github.com/derailed/k9s/releases/download/${version}/k9s_${os}_${arch}.tar.gz"
      if download_file "$url" "$tmp_dir/k9s.tar.gz"; then
        tar -xzf "$tmp_dir/k9s.tar.gz" -C "$tmp_dir"
        sudo install -m 0755 "$tmp_dir/k9s" /usr/local/bin/k9s
        log_info "Installed k9s to /usr/local/bin/k9s"
      else
        log_warn "Failed to download k9s."
      fi
      rm -rf "$tmp_dir"
      ;;
    dnf) install_pkg "$mgr" k9s || log_warn "Failed to install k9s from repos.";;
    pacman) install_pkg "$mgr" k9s;;
    zypper) install_pkg "$mgr" k9s || log_warn "Failed to install k9s from repos.";;
    *) log_warn "k9s install not supported for this distro.";;
  esac
}

install_podman() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" podman;;
    dnf) install_pkg "$mgr" podman;;
    pacman) install_pkg "$mgr" podman;;
    zypper) install_pkg "$mgr" podman;;
    *) log_warn "podman install not supported for this distro.";;
  esac
}

install_tokei() {
  local mgr="$1"
  case "$mgr" in
    apt)
      if ! install_pkg "$mgr" tokei; then
        if ! command -v cargo >/dev/null 2>&1; then
          install_rust "$mgr" || true
        fi
        if command -v cargo >/dev/null 2>&1; then
          cargo install tokei || log_warn "Failed to install tokei via cargo."
        fi
      fi
      ;;
    dnf) install_pkg "$mgr" tokei || log_warn "Failed to install tokei from repos.";;
    pacman) install_pkg "$mgr" tokei;;
    zypper)
      if ! command -v cargo >/dev/null 2>&1; then
        install_rust "$mgr" || true
      fi
      if command -v cargo >/dev/null 2>&1; then
        cargo install tokei || log_warn "Failed to install tokei via cargo."
      fi
      ;;
    *) log_warn "tokei install not supported for this distro.";;
  esac
}

install_glow() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # glow not in default repos, download from GitHub
      local version url tmp_dir arch
      tmp_dir="$(mktemp -d)"
      arch="$(uname -m)"
      case "$arch" in
        x86_64|amd64) arch="x86_64";;
        aarch64|arm64) arch="arm64";;
        i386|i686) arch="i386";;
        *) log_warn "glow install not supported for arch: $arch"; return 1;;
      esac
      if download_file "https://api.github.com/repos/charmbracelet/glow/releases/latest" "$tmp_dir/release.json"; then
        version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"v\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
      fi
      if [[ -z "$version" ]]; then
        version="$FALLBACK_VERSION_GLOW"
      fi
      url="https://github.com/charmbracelet/glow/releases/download/v${version}/glow_${version}_Linux_${arch}.tar.gz"
      if download_file "$url" "$tmp_dir/glow.tar.gz"; then
        tar -xzf "$tmp_dir/glow.tar.gz" -C "$tmp_dir"
        local glow_bin
        glow_bin=$(find "$tmp_dir" -name "glow" -type f -executable 2>/dev/null | head -n1)
        if [[ -z "$glow_bin" ]]; then
          glow_bin=$(find "$tmp_dir" -name "glow" -type f 2>/dev/null | head -n1)
        fi
        if [[ -n "$glow_bin" ]]; then
          sudo install -m 0755 "$glow_bin" /usr/local/bin/glow
          log_info "Installed glow to /usr/local/bin/glow"
        else
          log_warn "glow binary not found in archive."
        fi
      else
        log_warn "Failed to download glow."
      fi
      rm -rf "$tmp_dir"
      ;;
    dnf) install_pkg "$mgr" glow || log_warn "Failed to install glow from repos.";;
    pacman) install_pkg "$mgr" glow;;
    zypper) install_pkg "$mgr" glow || log_warn "Failed to install glow from repos.";;
    *) log_warn "glow install not supported for this distro.";;
  esac
}

install_delta() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # delta package is git-delta on some systems
      if ! install_pkg "$mgr" git-delta; then
        # Fallback: download from GitHub
        local version url tmp_dir arch
        tmp_dir="$(mktemp -d)"
        arch="$(uname -m)"
        case "$arch" in
          x86_64|amd64) arch="x86_64-unknown-linux-gnu";;
          aarch64|arm64) arch="aarch64-unknown-linux-gnu";;
          i386|i686) arch="i686-unknown-linux-gnu";;
          *) log_warn "delta install not supported for arch: $arch"; return 1;;
        esac
        if download_file "https://api.github.com/repos/dandavison/delta/releases/latest" "$tmp_dir/release.json"; then
          version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
        fi
        if [[ -z "$version" ]]; then
          version="$FALLBACK_VERSION_DELTA"
        fi
        url="https://github.com/dandavison/delta/releases/download/${version}/delta-${version}-${arch}.tar.gz"
        if download_file "$url" "$tmp_dir/delta.tar.gz"; then
          tar -xzf "$tmp_dir/delta.tar.gz" -C "$tmp_dir"
          local delta_bin
          delta_bin=$(find "$tmp_dir" -name "delta" -type f -executable | head -n1)
          if [[ -n "$delta_bin" ]]; then
            sudo install -m 0755 "$delta_bin" /usr/local/bin/delta
            log_info "Installed delta to /usr/local/bin/delta"
          fi
        else
          log_warn "Failed to download delta."
        fi
        rm -rf "$tmp_dir"
      fi
      ;;
    dnf) install_pkg "$mgr" git-delta || log_warn "Failed to install delta from repos.";;
    pacman) install_pkg "$mgr" git-delta;;
    zypper) install_pkg "$mgr" git-delta || log_warn "Failed to install delta from repos.";;
    *) log_warn "delta install not supported for this distro.";;
  esac
}

install_meld() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" meld;;
    dnf) install_pkg "$mgr" meld;;
    pacman) install_pkg "$mgr" meld;;
    zypper) install_pkg "$mgr" meld;;
    *) log_warn "meld install not supported for this distro.";;
  esac
}

install_ruby() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" ruby ruby-dev;;
    dnf) install_pkg "$mgr" ruby ruby-devel;;
    pacman) install_pkg "$mgr" ruby;;
    zypper) install_pkg "$mgr" ruby ruby-devel;;
    *) log_warn "ruby install not supported for this distro.";;
  esac
}

install_flatpak() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" flatpak;;
    dnf) install_pkg "$mgr" flatpak;;
    pacman) install_pkg "$mgr" flatpak;;
    zypper) install_pkg "$mgr" flatpak;;
    *) log_warn "flatpak install not supported for this distro.";;
  esac
  # Add Flathub repository if flatpak is installed
  if command -v flatpak >/dev/null 2>&1; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
  fi
}

install_wine() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # Enable 32-bit architecture for wine32
      sudo dpkg --add-architecture i386 || true
      sudo apt-get update || true
      install_pkg "$mgr" wine wine64 wine32 || install_pkg "$mgr" wine
      ;;
    dnf) install_pkg "$mgr" wine;;
    pacman) install_pkg "$mgr" wine wine-mono wine-gecko;;
    zypper) install_pkg "$mgr" wine;;
    *) log_warn "wine install not supported for this distro.";;
  esac
}

install_tor() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # Install tor and torbrowser-launcher
      install_pkg "$mgr" tor torbrowser-launcher || install_pkg "$mgr" tor
      ;;
    dnf) install_pkg "$mgr" tor;;
    pacman) install_pkg "$mgr" tor torbrowser-launcher || install_pkg "$mgr" tor;;
    zypper) install_pkg "$mgr" tor;;
    *) log_warn "tor install not supported for this distro.";;
  esac
}

install_ntfs() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" ntfs-3g;;
    dnf) install_pkg "$mgr" ntfs-3g;;
    pacman) install_pkg "$mgr" ntfs-3g;;
    zypper) install_pkg "$mgr" ntfs-3g;;
    *) log_warn "ntfs-3g install not supported for this distro.";;
  esac
}

install_streamcontroller() {
  # StreamController is installed via Flatpak
  if ! command -v flatpak >/dev/null 2>&1; then
    log_warn "Flatpak is required for StreamController; installing flatpak..."
    install_flatpak "$1" || true
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub com.core447.StreamController || log_warn "Failed to install StreamController via Flatpak."
  else
    log_warn "Flatpak still missing; cannot install StreamController."
  fi
}

# Resolve the latest RustDesk release tag from the GitHub API, falling back to
# the pinned version when the API is unavailable or rate-limited. The tag is
# retained verbatim because release download paths may require its v prefix.
rustdesk_latest_tag() {
  local tmp_dir tag=""
  tmp_dir="$(mktemp -d)"
  if download_file "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" "$tmp_dir/release.json"; then
    tag="$(sed -n "s/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$tmp_dir/release.json" | head -n1)"
  fi
  rm -rf "$tmp_dir"
  if [[ -z "$tag" ]]; then
    tag="$FALLBACK_VERSION_RUSTDESK"
  fi
  printf "%s\n" "$tag"
}

install_rustdesk() {
  local mgr="$1"
  local arch tag version url tmp_dir pkg_path

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64";;
    aarch64|arm64) arch="aarch64";;
    *) arch="";;
  esac

  if [[ -n "$arch" ]] && { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }; then
    tag="$(rustdesk_latest_tag)"
    version="${tag#v}"
    tmp_dir="$(mktemp -d)"
    case "$mgr" in
      apt)
        url="https://github.com/rustdesk/rustdesk/releases/download/${tag}/rustdesk-${version}-${arch}.deb"
        pkg_path="$tmp_dir/rustdesk.deb"
        ;;
      dnf)
        url="https://github.com/rustdesk/rustdesk/releases/download/${tag}/rustdesk-${version}-0.${arch}.rpm"
        pkg_path="$tmp_dir/rustdesk.rpm"
        ;;
      zypper)
        url="https://github.com/rustdesk/rustdesk/releases/download/${tag}/rustdesk-${version}-0.${arch}-suse.rpm"
        pkg_path="$tmp_dir/rustdesk.rpm"
        ;;
      pacman)
        url="https://github.com/rustdesk/rustdesk/releases/download/${tag}/rustdesk-${version}-0-${arch}.pkg.tar.zst"
        pkg_path="$tmp_dir/rustdesk.pkg.tar.zst"
        ;;
      *)
        url=""
        ;;
    esac

    if [[ -n "$url" ]]; then
      log_info "Downloading RustDesk ${version} from GitHub releases..."
      if download_file "$url" "$pkg_path"; then
        case "$mgr" in
          apt)
            sudo dpkg -i "$pkg_path" || true
            sudo apt-get -f install -y || true
            ;;
          dnf) sudo dnf install -y "$pkg_path" || true;;
          zypper) sudo zypper --non-interactive install "$pkg_path" || true;;
          pacman) sudo pacman -U --noconfirm "$pkg_path" || true;;
        esac
        rm -rf "$tmp_dir"
        if command -v rustdesk >/dev/null 2>&1; then
          return 0
        fi
        log_warn "RustDesk package install did not produce a rustdesk binary; trying Flatpak..."
      else
        rm -rf "$tmp_dir"
        log_warn "Failed to download RustDesk package; trying Flatpak..."
      fi
    else
      rm -rf "$tmp_dir"
    fi
  fi

  # Flatpak fallback keeps RustDesk available on distros or architectures with
  # no matching release artifact.
  if ! command -v flatpak >/dev/null 2>&1; then
    install_flatpak "$mgr" || true
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak install -y flathub com.rustdesk.RustDesk || log_warn "Failed to install RustDesk via Flatpak."
  else
    log_warn "Could not install RustDesk: no package artifact and no flatpak."
  fi
}

install_gimp() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # Install GIMP with plugins including export-to-web
      install_pkg "$mgr" gimp gimp-plugin-registry gimp-data-extras || install_pkg "$mgr" gimp
      ;;
    dnf) install_pkg "$mgr" gimp gimp-data-extras || install_pkg "$mgr" gimp;;
    pacman) install_pkg "$mgr" gimp;;
    zypper) install_pkg "$mgr" gimp;;
    *) log_warn "gimp install not supported for this distro.";;
  esac
}

install_gh() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # Add GitHub CLI official repo for apt
      if ! command -v gh >/dev/null 2>&1; then
        # Ensure wget is available
        if ! command -v wget >/dev/null 2>&1; then
          if ! install_pkg "$mgr" wget; then
            log_warn "Failed to install wget for gh CLI setup."
            return 1
          fi
        fi

        # Create keyrings directory
        if ! sudo mkdir -p -m 755 /etc/apt/keyrings; then
          log_warn "Failed to create /etc/apt/keyrings directory."
          return 1
        fi

        # Download GPG key
        local tmp_key
        tmp_key="$(mktemp)"
        if ! wget -nv -O "$tmp_key" https://cli.github.com/packages/githubcli-archive-keyring.gpg; then
          log_warn "Failed to download GitHub CLI GPG key."
          rm -f "$tmp_key"
          return 1
        fi

        # Install GPG key
        if ! sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg < "$tmp_key" > /dev/null; then
          log_warn "Failed to install GitHub CLI GPG key."
          rm -f "$tmp_key"
          return 1
        fi
        rm -f "$tmp_key"
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

        # Add repository
        local arch
        arch="$(dpkg --print-architecture)"
        echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
          sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

        # Update and install
        sudo apt-get update || true
        install_pkg "$mgr" gh
      fi
      ;;
    dnf)
      sudo dnf install -y 'dnf-command(config-manager)' || true
      sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo || true
      install_pkg "$mgr" gh
      ;;
    pacman)
      install_pkg "$mgr" github-cli
      ;;
    zypper)
      sudo zypper addrepo https://cli.github.com/packages/rpm/gh-cli.repo || true
      sudo zypper ref || true
      install_pkg "$mgr" gh
      ;;
    *)
      log_warn "gh CLI install not supported for this distro."
      ;;
  esac
}

install_bfg() {
  local mgr="$1"
  # Try package manager first
  case "$mgr" in
    apt)
      if install_pkg "$mgr" bfg; then
        return 0
      fi
      ;;
    pacman)
      if install_pkg "$mgr" bfg; then
        return 0
      fi
      ;;
  esac

  # Fallback: download JAR directly
  if ! command -v java >/dev/null 2>&1; then
    log_warn "Java is required for BFG; installing Java..."
    install_java "$mgr" || true
  fi
  if ! command -v java >/dev/null 2>&1; then
    log_warn "Java still missing; cannot install BFG."
    return 1
  fi

  local version url tmp_dir jar_path
  local install_dir="/usr/local/lib/bfg"
  local bin_path="/usr/local/bin/bfg"

  # Get latest version from GitHub API
  tmp_dir="$(mktemp -d)"
  if download_file "https://api.github.com/repos/rtyley/bfg-repo-cleaner/releases/latest" "$tmp_dir/release.json"; then
    version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"v\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
  fi
  if [[ -z "$version" ]]; then
    version="$FALLBACK_VERSION_BFG"
  fi

  url="https://repo1.maven.org/maven2/com/madgag/bfg/${version}/bfg-${version}.jar"
  jar_path="$tmp_dir/bfg.jar"

  if download_file "$url" "$jar_path"; then
    sudo mkdir -p "$install_dir"
    if ! sudo cp "$jar_path" "$install_dir/bfg.jar"; then
      log_warn "Failed to copy BFG JAR to $install_dir."
      rm -rf "$tmp_dir"
      return 1
    fi
    # Verify JAR was installed before creating wrapper
    if [[ ! -f "$install_dir/bfg.jar" ]]; then
      log_warn "BFG JAR not found at $install_dir/bfg.jar after copy."
      rm -rf "$tmp_dir"
      return 1
    fi
    # Create wrapper script
    sudo tee "$bin_path" > /dev/null << 'WRAPPER'
#!/bin/sh
exec java -jar /usr/local/lib/bfg/bfg.jar "$@"
WRAPPER
    sudo chmod +x "$bin_path"
    log_info "Installed BFG to $bin_path"
  else
    log_warn "Failed to download BFG JAR."
    rm -rf "$tmp_dir"
    return 1
  fi
  rm -rf "$tmp_dir"
}

node_major_version() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi
  local major
  major="$(node --version | sed 's/^v//' | cut -d. -f1)"
  if [[ "$major" =~ ^[0-9]+$ ]]; then
    echo "$major"
  else
    echo 0
  fi
}

ensure_node_major() {
  local mgr="$1" required="$2"
  local major
  major="$(node_major_version)"
  if [[ "$major" -ge "$required" ]]; then
    return 0
  fi
  if [[ "$major" -eq 0 ]]; then
    log_warn "Node.js is required; installing or upgrading Node.js first..."
  else
    log_warn "Node.js $required+ is required; detected Node.js $major."
  fi
  install_node_major_version "$mgr" "$required" || true
  major="$(node_major_version)"
  if [[ "$major" -lt "$required" ]]; then
    log_warn "Node.js $required+ is still unavailable; cannot install this tool."
    return 1
  fi
}

install_npm_global() {
  local mgr="$1" package="$2" required="${3:-20}"
  ensure_node_major "$mgr" "$required" || return 1
  if ! command -v npm >/dev/null 2>&1; then
    install_node_major_version "$mgr" "$required" || true
    ensure_node_major "$mgr" "$required" || return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log_warn "npm is required to install $package."
    return 1
  fi
  sudo npm install -g "$package"
}

show_downloaded_script_preview() {
  local url="$1" path="$2"
  log_info "Downloaded installer from $url to $path"
  log_info "Installer preview, first 20 lines:"
  sed -n '1,20p' "$path" >&2 || true
}

confirm_remote_script_execution() {
  local url="$1"
  if [[ "${DISTRODECK_NONINTERACTIVE:-false}" == "true" ]]; then
    log_warn "Skipping downloaded installer in noninteractive mode: $url"
    return 1
  fi
  if [[ ! -t 0 ]]; then
    log_warn "Refusing to execute downloaded installer without an interactive terminal: $url"
    return 1
  fi
  printf "Run installer downloaded from %s? [y/N] " "$url" >&2
  local answer=""
  if ! IFS= read -r answer; then
    answer=""
  fi
  case "$answer" in
    y|Y|yes|YES) return 0;;
    *) log_warn "Skipped downloaded installer: $url"; return 1;;
  esac
}

run_downloaded_script() {
  local url="$1"
  local tmp_file rc
  tmp_file="$(mktemp)"
  if ! download_file "$url" "$tmp_file"; then
    rm -f "$tmp_file"
    log_warn "Failed to download installer: $url"
    return 1
  fi
  show_downloaded_script_preview "$url" "$tmp_file"
  if ! confirm_remote_script_execution "$url"; then
    rm -f "$tmp_file"
    return 1
  fi
  if bash "$tmp_file"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp_file"
  return "$rc"
}

install_codex() {
  install_npm_global "$1" "@openai/codex"
}

install_copilot() {
  install_npm_global "$1" "@github/copilot" 22
}

install_claude_code() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_curl "$1" || true
  fi
  run_downloaded_script "https://claude.ai/install.sh"
}

install_gemini() {
  local mgr="$1"
  ensure_node_major "$mgr" 20 || return 1
  install_npm_global "$mgr" "@google/gemini-cli"
}

install_ollama() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_curl "$1" || true
  fi
  run_downloaded_script "https://ollama.com/install.sh"
}

install_cursor() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_curl "$1" || true
  fi
  run_downloaded_script "https://cursor.com/install"
}

install_kiro() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_curl "$1" || true
  fi
  run_downloaded_script "https://cli.kiro.dev/install"
}

install_antigravity() {
  if command -v antigravity >/dev/null 2>&1; then
    return 0
  fi
  local mgr="$1"
  case "$mgr" in
    apt)
      if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        install_curl "$mgr" || true
      fi
      if ! command -v gpg >/dev/null 2>&1; then
        install_pkg "$mgr" gnupg || true
      fi
      if ! command -v gpg >/dev/null 2>&1; then
        log_warn "gpg is required to install the Antigravity apt repository key."
        return 1
      fi
      sudo mkdir -p /etc/apt/keyrings
      local tmp_key
      tmp_key="$(mktemp)"
      if download_file "https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg" "$tmp_key"; then
        if ! sudo gpg --dearmor --yes -o /etc/apt/keyrings/antigravity-repo-key.gpg "$tmp_key"; then
          rm -f "$tmp_key"
          sudo rm -f /etc/apt/keyrings/antigravity-repo-key.gpg 2>/dev/null || true
          log_warn "Failed to import Antigravity apt repository key."
          return 1
        fi
        sudo chmod 0644 /etc/apt/keyrings/antigravity-repo-key.gpg
        rm -f "$tmp_key"
      else
        rm -f "$tmp_key"
        log_warn "Failed to download Antigravity apt repository key."
        return 1
      fi
      echo "deb [signed-by=/etc/apt/keyrings/antigravity-repo-key.gpg] https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev/ antigravity-debian main" | \
        sudo tee /etc/apt/sources.list.d/antigravity.list > /dev/null
      install_pkg "$mgr" antigravity
      ;;
    dnf)
      log_warn "Antigravity RPM install is disabled because the upstream RPM repository does not publish a package signing key."
      log_warn "Use https://antigravity.google/download/linux for manual RPM installation guidance."
      return 1
      ;;
    zypper)
      log_warn "Antigravity RPM install is disabled because the upstream RPM repository does not publish a package signing key."
      log_warn "Use https://antigravity.google/download/linux for manual RPM installation guidance."
      return 1
      ;;
    *)
      log_warn "Antigravity install is supported by distrodeck on apt systems."
      return 1
      ;;
  esac
}

install_aider() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    install_curl "$1" || true
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log_warn "curl or wget is required to install aider."
    return 1
  fi
  run_downloaded_script "https://aider.chat/install.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Spec table: one row per table-driven tool
# ─────────────────────────────────────────────────────────────────────────────
# Fields (space separated, "-" = none):
#   kind apt dnf pacman zypper brew flatpak extra bins
# kind:  pkg (distro package, then Flatpak, then pipx), repo (a vendor repo or
#        installer function install_<tool>), container (docker/podman),
#        pipx, claude-plugin.
# brew:  a formula, or cask:<name>.
# extra: pkg/pipx -> pipx package; container -> see container_spec;
#        claude-plugin -> plugin name in the official marketplace.
# bins:  comma separated binaries from the package file lists.
# apt names: packages.ubuntu.com (noble); dnf: Fedora rawhide (mdapi); pacman:
# archlinux.org (official repos only, AUR is unsupported); zypper: Tumbleweed
# oss repodata; brew: formulae.brew.sh; Flatpak: flathub.org. "@PG@" is the
# installed PostgreSQL major. Detection also asks the package database and
# `flatpak info`: openSUSE ships /usr/bin/blender-<version> only.
package_tool_spec() {
  case "$1" in
    # ── IDEs, Media, Graphics ──
    vlc) echo "pkg vlc vlc vlc vlc cask:vlc org.videolan.VLC - vlc";;
    mpv) echo "pkg mpv mpv mpv mpv mpv io.mpv.Mpv - mpv";;
    ffmpeg) echo "pkg ffmpeg ffmpeg-free ffmpeg ffmpeg ffmpeg - - ffmpeg";;
    obs-studio) echo "pkg obs-studio obs-studio obs-studio obs-studio cask:obs com.obsproject.Studio - obs";;
    audacity) echo "pkg audacity audacity audacity audacity cask:audacity org.audacityteam.Audacity - audacity";;
    kdenlive) echo "pkg kdenlive kdenlive kdenlive kdenlive cask:kdenlive org.kde.kdenlive - kdenlive";;
    handbrake) echo "pkg handbrake - handbrake - cask:handbrake-app fr.handbrake.ghb - ghb";;
    inkscape) echo "pkg inkscape inkscape inkscape inkscape cask:inkscape org.inkscape.Inkscape - inkscape";;
    krita) echo "pkg krita krita krita krita cask:krita org.kde.krita - krita";;
    blender) echo "pkg blender blender blender blender cask:blender org.blender.Blender - blender";;
    darktable) echo "pkg darktable darktable darktable darktable cask:darktable org.darktable.Darktable - darktable";;
    zed) echo "pkg - - zed - cask:zed dev.zed.Zed - zeditor,zed";;
    intellij-idea-community) echo "pkg - - intellij-idea-community-edition - cask:intellij-idea-ce com.jetbrains.IntelliJ-IDEA-Community - idea";;
    pycharm-community) echo "pkg - - pycharm-community-edition - cask:pycharm-ce com.jetbrains.PyCharm-Community - pycharm";;
    # ── Relational ──
    postgresql) echo "pkg postgresql postgresql-server postgresql postgresql-server postgresql@18 - - -";;
    pgvector) echo "pkg postgresql-@PG@-pgvector pgvector pgvector postgresql@PG@-pgvector pgvector - - -";;
    mysql) echo "pkg mysql-server mysql8.4-server - - mysql - - mysqld";;
    mariadb) echo "pkg mariadb-server mariadb-server mariadb mariadb mariadb - - mariadbd";;
    sqlite) echo "pkg sqlite3 sqlite sqlite sqlite3 sqlite - - sqlite3";;
    oracle-free) echo "container - - - - - - - -";;
    # ── NoSQL & graph ──
    redis) echo "pkg redis-server - - redis redis - - redis-server";;
    valkey) echo "pkg valkey-server valkey valkey valkey valkey - - valkey-server";;
    cassandra) echo "repo cassandra - - - cassandra - - cassandra";;
    couchdb) echo "pkg - - couchdb - couchdb - - -";;
    neo4j) echo "repo neo4j - - - neo4j - - neo4j";;
    # ── Vector ──
    qdrant) echo "container - - - - - - - -";;
    chroma) echo "pipx - - - - chroma - chromadb chroma";;
    milvus) echo "container - - - - - - - -";;
    weaviate) echo "container - - - - - - - -";;
    # ── Object storage ──
    minio) echo "pkg - - - - minio - - minio";;
    minio-client) echo "pkg - - minio-client - minio-mc - - mcli";;
    seaweedfs) echo "container - - - - seaweedfs - - -";;
    rclone) echo "pkg rclone rclone rclone rclone rclone - - rclone";;
    s3cmd) echo "pkg s3cmd s3cmd s3cmd s3cmd s3cmd - - s3cmd";;
    # ── DB admin ──
    dbeaver-ce) echo "pkg - - dbeaver - cask:dbeaver-community io.dbeaver.DBeaverCommunity - dbeaver";;
    pgadmin4) echo "pkg - - - - cask:pgadmin4 org.pgadmin.pgadmin4 - pgadmin4";;
    mongodb-compass) echo "pkg - - - - cask:mongodb-compass com.mongodb.Compass - mongodb-compass";;
    sqlitebrowser) echo "pkg sqlitebrowser sqlitebrowser sqlitebrowser sqlitebrowser cask:db-browser-for-sqlite org.sqlitebrowser.sqlitebrowser - sqlitebrowser";;
    beekeeper-studio) echo "pkg - - - - cask:beekeeper-studio io.beekeeperstudio.Studio - beekeeper-studio";;
    pgcli) echo "pkg pgcli pgcli pgcli - pgcli - pgcli pgcli";;
    mycli) echo "pkg mycli mycli - - mycli - mycli mycli";;
    litecli) echo "pkg litecli litecli - - litecli - litecli litecli";;
    usql) echo "pkg - - - - usql - - usql";;
    # ── System admin ──
    cockpit) echo "pkg cockpit cockpit cockpit cockpit - - - -";;
    btop) echo "pkg btop btop btop btop btop - - btop";;
    glances) echo "pkg glances glances glances - glances - glances glances";;
    lnav) echo "pkg lnav lnav lnav lnav lnav - - lnav";;
    # ── Web services ──
    nginx) echo "pkg nginx nginx nginx nginx nginx - - nginx";;
    apache2) echo "pkg apache2 httpd apache apache2 httpd - - apache2,httpd";;
    caddy) echo "pkg caddy caddy caddy caddy caddy - - caddy";;
    haproxy) echo "pkg haproxy haproxy haproxy haproxy haproxy - - haproxy";;
    certbot) echo "pkg certbot certbot certbot - certbot - - certbot";;
    mkcert) echo "pkg mkcert mkcert mkcert mkcert mkcert - - mkcert";;
    # ── Programming tools ──
    dotnet-sdk) echo "pkg dotnet-sdk-10.0 dotnet-sdk-10.0 dotnet-sdk - cask:dotnet-sdk - - dotnet";;
    uv) echo "pkg - uv uv - uv - uv uv";;
    pipx) echo "pkg pipx pipx python-pipx python313-pipx pipx - - pipx";;
    pyenv) echo "pkg - - pyenv pyenv pyenv - - pyenv";;
    nvm) echo "repo - - - - - - - -";;
    sdkman) echo "repo - - - - - - - -";;
    kotlin) echo "pkg kotlin - kotlin - kotlin - - kotlinc";;
    cmake) echo "pkg cmake cmake cmake cmake cmake - - cmake";;
    ninja) echo "pkg ninja-build ninja-build ninja ninja ninja - - ninja";;
    clang) echo "pkg clang clang clang clang llvm - - clang";;
    gdb) echo "pkg gdb gdb gdb gdb gdb - - gdb";;
    valgrind) echo "pkg valgrind valgrind valgrind valgrind valgrind - - valgrind";;
    shellcheck) echo "pkg shellcheck ShellCheck shellcheck ShellCheck shellcheck - - shellcheck";;
    pre-commit) echo "pkg pre-commit pre-commit pre-commit - pre-commit - pre-commit pre-commit";;
    httpie) echo "pkg httpie httpie httpie httpie httpie - - http";;
    bruno) echo "pkg - - - - cask:bruno com.usebruno.Bruno - bruno";;
    # ── Claude Code plugins (anthropics/claude-plugins-official only) ──
    plugin-*) echo "claude-plugin - - - - - - ${1#plugin-} -";;
    *) return 1;;
  esac
}

# Print field $2 of tool $1's spec: kind apt dnf pacman zypper brew flatpak extra bins.
spec_field() {
  local spec idx
  spec="$(package_tool_spec "$1")" || return 1
  case "$2" in
    kind) idx=1;; apt) idx=2;; dnf) idx=3;; pacman) idx=4;; zypper) idx=5;;
    brew) idx=6;; flatpak) idx=7;; extra) idx=8;; bins) idx=9;; *) return 1;;
  esac
  local fields value
  read -r -a fields <<< "$spec"
  value="${fields[idx - 1]:-}"
  [[ "$value" == "-" ]] && value=""
  printf '%s\n' "$value"
}

# Installed PostgreSQL major, for the pgvector package name.
pg_major() {
  local version
  version="$(psql --version 2>/dev/null | awk '{print $3}')"
  version="${version%%.*}"
  [[ "$version" =~ ^[0-9]+$ ]] && printf '%s\n' "$version"
}

# Print the package for tool $1 on manager $2 (brew: formula or cask:name), or nothing.
package_tool_pkg() {
  local pkg major
  pkg="$(spec_field "$1" "$2")" || return 0
  if [[ "$pkg" == *@PG@* ]]; then
    if ! major="$(pg_major)" || [[ -z "$major" ]]; then
      log_warn "$1 needs PostgreSQL installed first (install the postgresql tool)."
      return 0
    fi
    pkg="${pkg//@PG@/$major}"
  fi
  if [[ "$2" == "apt" ]]; then
    pkg="$(apt_release_pkg "$1" "$pkg")" || return 0
  fi
  printf '%s\n' "$pkg"
}

# Return 0 when apt has an install candidate for package $1.
apt_has_candidate() {
  local candidate
  candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

# Debian (bookworm, trixie) ships no mysql-server; default-mysql-server is MariaDB.
apt_mysql_is_mariadb() {
  ! apt_has_candidate mysql-server && apt_has_candidate default-mysql-server
}

# Print the apt package for tool $1 on this release (default $2), or fail with
# a message when the release does not ship it.
apt_release_pkg() {
  local tool="$1" pkg="$2"
  case "$tool" in
    mysql)
      if apt_mysql_is_mariadb; then
        log_warn "This release ships no mysql-server; installing default-mysql-server, which is MariaDB, not Oracle MySQL. For MySQL itself use the MySQL APT repository: https://dev.mysql.com/downloads/repo/apt/"
        pkg="default-mysql-server"
      fi
      ;;
    valkey)
      if ! apt_has_candidate "$pkg"; then
        log_warn "This release ships no $pkg. On Debian bookworm it is in bookworm-backports: enable it, then run: sudo apt install -t bookworm-backports $pkg"
        return 1
      fi
      ;;
  esac
  printf '%s\n' "$pkg"
}

package_tool_flatpak() {
  spec_field "$1" flatpak
}

is_package_tool() {
  package_tool_spec "$1" >/dev/null 2>&1
}

# Return 0 when package $2 is installed under manager $1.
native_pkg_installed() {
  local mgr="$1" pkg="$2"
  [[ -n "$pkg" ]] || return 1
  case "$mgr" in
    apt) [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" == "installed" ]];;
    dnf|zypper) rpm -q "$pkg" >/dev/null 2>&1;;
    pacman) pacman -Q "$pkg" >/dev/null 2>&1;;
    brew)
      if [[ "$pkg" == cask:* ]]; then
        brew list --cask --versions "${pkg#cask:}" >/dev/null 2>&1
      else
        brew list --versions "$pkg" >/dev/null 2>&1
      fi
      ;;
    *) return 1;;
  esac
}

# Is tool $1 installable with manager $2 at all? Used to hide Linux-only
# tools on macOS instead of listing them as failures.
tool_supported_on() {
  local tool="$1" mgr="$2" kind
  if ! is_package_tool "$tool"; then
    [[ "$mgr" != "brew" ]] && return 0
    [[ -n "$(legacy_brew_name "$tool")" ]]
    return
  fi
  kind="$(spec_field "$tool" kind)"
  case "$kind" in
    claude-plugin) return 0;;
    container) [[ "$mgr" != "brew" || -n "$(spec_field "$tool" brew)" ]];;
    repo) [[ "$mgr" == "apt" || -n "$(spec_field "$tool" "$mgr")" ]] || [[ "$tool" == nvm || "$tool" == sdkman ]];;
    pipx) return 0;;
    *)
      [[ -n "$(spec_field "$tool" "$mgr")" ]] && return 0
      [[ "$mgr" != "brew" && -n "$(spec_field "$tool" flatpak)" ]] && return 0
      [[ -n "$(spec_field "$tool" extra)" ]]
      ;;
  esac
}

# Installed when a known binary is on PATH, the package is installed, the
# Flatpak is installed (`flatpak info`, never a binary name), the container
# exists, the pipx venv exists or the Claude plugin is listed.
package_tool_installed() {
  local tool="$1" kind bins bin flatpak_id mgr extra
  kind="$(spec_field "$tool" kind)"
  case "$kind" in
    container) container_installed "$tool" && return 0;;
    claude-plugin) claude_plugin_installed "$tool"; return;;
    repo)
      case "$tool" in
        nvm) [[ -s "${NVM_INSTALL_DIR}/nvm.sh" ]] && return 0;;
        sdkman) [[ -s "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" ]] && return 0;;
      esac
      ;;
  esac
  bins="$(spec_field "$tool" bins)"
  for bin in ${bins//,/ }; do
    command -v "$bin" >/dev/null 2>&1 && return 0
  done
  mgr="$(detect_pkg_mgr)"
  native_pkg_installed "$mgr" "$(package_tool_pkg "$tool" "$mgr" 2>/dev/null)" && return 0
  extra="$(spec_field "$tool" extra)"
  if [[ -n "$extra" && "$kind" != "container" ]] && pipx_has "$extra"; then
    return 0
  fi
  flatpak_id="$(spec_field "$tool" flatpak)"
  [[ -n "$flatpak_id" ]] && command -v flatpak >/dev/null 2>&1 && \
    flatpak info "$flatpak_id" >/dev/null 2>&1
}

# `pipx list` takes about half a second; ask once per run.
PIPX_LIST_CACHE=""
pipx_has() {
  command -v pipx >/dev/null 2>&1 || return 1
  if [[ -z "$PIPX_LIST_CACHE" ]]; then
    PIPX_LIST_CACHE="$(pipx list --short 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$PIPX_LIST_CACHE" ]] || PIPX_LIST_CACHE=" "
  fi
  grep -qx "$1" <<< "$PIPX_LIST_CACHE"
}

ensure_pipx() {
  local mgr="$1"
  command -v pipx >/dev/null 2>&1 && return 0
  log_info "pipx is required; installing it."
  install_package_tool pipx "$mgr" || return 1
  command -v pipx >/dev/null 2>&1 || { log_warn "pipx is still unavailable."; return 1; }
}

install_pipx_package() {
  local package="$1" mgr="$2"
  ensure_pipx "$mgr" || return 1
  pipx install "$package"
}

install_package_tool() {
  local tool="$1" mgr="$2" kind pkg flatpak_id extra
  kind="$(spec_field "$tool" kind)"
  case "$kind" in
    container)
      if [[ "$mgr" == "brew" && -n "$(spec_field "$tool" brew)" ]]; then
        install_pkg brew "$(spec_field "$tool" brew)" || return 1
        server_setup "$tool" "$mgr"
        return
      fi
      install_container_tool "$tool"
      return
      ;;
    claude-plugin) install_claude_plugin "$tool"; return;;
    repo)
      if [[ "$mgr" == "brew" && -n "$(spec_field "$tool" brew)" ]]; then
        install_pkg brew "$(spec_field "$tool" brew)" || return 1
        server_setup "$tool" "$mgr"
        return
      fi
      "install_${tool//-/_}" "$mgr" || return 1
      server_setup "$tool" "$mgr"
      return
      ;;
    pipx)
      if [[ "$mgr" == "brew" && -n "$(spec_field "$tool" brew)" ]]; then
        install_pkg brew "$(spec_field "$tool" brew)"
        return
      fi
      install_pipx_package "$(spec_field "$tool" extra)" "$mgr"
      return
      ;;
  esac
  pkg="$(package_tool_pkg "$tool" "$mgr")"
  if [[ -n "$pkg" ]]; then
    if [[ "$mgr" == "apt" && -n "$(server_unit "$tool" "$mgr")" ]]; then
      apt_install_no_autostart "$pkg" || return 1
    else
      install_pkg "$mgr" "$pkg" || return 1
    fi
    server_setup "$tool" "$mgr"
    return
  fi
  if [[ "$(spec_field "$tool" "$mgr")" == *@PG@* ]]; then
    return 1
  fi
  flatpak_id="$(package_tool_flatpak "$tool")"
  if [[ -n "$flatpak_id" && "$mgr" != "brew" ]]; then
    log_info "$tool has no ${mgr} package; installing the Flathub Flatpak ${flatpak_id}."
    command -v flatpak >/dev/null 2>&1 || install_flatpak "$mgr" || return 1
    command -v flatpak >/dev/null 2>&1 || { log_warn "Flatpak is unavailable; cannot install $tool."; return 1; }
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
    flatpak install -y flathub "$flatpak_id"
    return
  fi
  extra="$(spec_field "$tool" extra)"
  if [[ -n "$extra" ]]; then
    log_info "$tool has no ${mgr} package; installing it with pipx."
    install_pipx_package "$extra" "$mgr"
    return
  fi
  log_warn "$tool has no ${mgr} package and no Flatpak; skipping it on this system."
  return 1
}

uninstall_package_tool() {
  local tool="$1" mgr="$2" kind pkg flatpak_id extra
  kind="$(spec_field "$tool" kind)"
  case "$kind" in
    container)
      if [[ "$mgr" != "brew" || -z "$(spec_field "$tool" brew)" ]]; then
        uninstall_container_tool "$tool"
        return
      fi
      ;;
    claude-plugin) uninstall_claude_plugin "$tool"; return;;
    repo)
      if [[ "$mgr" != "brew" ]] || [[ -z "$(spec_field "$tool" brew)" ]]; then
        server_teardown "$tool" "$mgr"
        "uninstall_${tool//-/_}" "$mgr"
        return
      fi
      ;;
  esac
  flatpak_id="$(package_tool_flatpak "$tool")"
  if [[ -n "$flatpak_id" ]] && command -v flatpak >/dev/null 2>&1 && \
     flatpak info "$flatpak_id" >/dev/null 2>&1; then
    flatpak uninstall -y "$flatpak_id"
    return
  fi
  extra="$(spec_field "$tool" extra)"
  if [[ -n "$extra" ]] && pipx_has "$extra"; then
    pipx uninstall "$extra"
    return
  fi
  pkg="$(package_tool_pkg "$tool" "$mgr")"
  if [[ -z "$pkg" ]]; then
    log_warn "$tool has no ${mgr} package to remove."
    return 1
  fi
  server_teardown "$tool" "$mgr"
  local remove=()
  read -r -a remove <<< "$(server_remove_pkgs "$tool" "$mgr" "$pkg")"
  uninstall_pkg "$mgr" "${remove[@]}"
}

# Print the installed apt packages matching dpkg-query patterns "$@".
apt_installed_matching() {
  dpkg-query -W -f='${db:Status-Status} ${Package}\n' "$@" 2>/dev/null | awk '$1 == "installed" {print $2}'
}

# Print the packages to remove for tool $1 on manager $2 (spec package $3),
# space separated. On apt several tools install a metapackage and removing it
# alone leaves the server installed (mysql-server -> mysql-server-8.0,
# postgresql -> postgresql-17, default-mysql-server -> mariadb-server,
# apache2 -> apache2-bin, redis-server -> redis-tools' binary), so the
# concrete packages are resolved now from what dpkg has installed. No
# autoremove: shared dependencies stay. dnf, pacman, zypper and brew names
# in the spec table are the concrete packages already.
server_remove_pkgs() {
  local tool="$1" mgr="$2" pkg="$3" found=()
  if [[ "$mgr" == "apt" ]]; then
    case "$tool" in
      postgresql)
        # Server majors and their pgvector builds; postgresql-client-N and
        # postgresql-common stay (clients may use them).
        mapfile -t found < <(apt_installed_matching postgresql 'postgresql-[0-9]*' | grep -E '^postgresql(-[0-9]+(-pgvector)?)?$')
        ;;
      pgvector) mapfile -t found < <(apt_installed_matching 'postgresql-[0-9]*-pgvector');;
      mysql)
        if apt_mysql_is_mariadb; then
          mapfile -t found < <(apt_installed_matching default-mysql-server 'default-mysql-server-core' mariadb-server 'mariadb-server-*')
        else
          mapfile -t found < <(apt_installed_matching mysql-server 'mysql-server-*')
        fi
        ;;
      mariadb) mapfile -t found < <(apt_installed_matching mariadb-server 'mariadb-server-*');;
      redis) mapfile -t found < <(apt_installed_matching redis-server redis-tools);;
      valkey) mapfile -t found < <(apt_installed_matching valkey-server valkey-tools);;
      apache2) mapfile -t found < <(apt_installed_matching apache2 apache2-bin);;
      nginx) mapfile -t found < <(apt_installed_matching nginx nginx-core nginx-full nginx-light nginx-extras);;
      cockpit) mapfile -t found < <(apt_installed_matching cockpit cockpit-ws cockpit-system cockpit-bridge);;
    esac
  fi
  if [[ ${#found[@]} -gt 0 ]]; then
    printf '%s\n' "${found[*]}"
  else
    printf '%s\n' "$pkg"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Servers: enable the service, bind 127.0.0.1, keep data on uninstall
# ─────────────────────────────────────────────────────────────────────────────
# Print the service name of server tool $1 under manager $2, or nothing.
server_unit() {
  local tool="$1" mgr="$2"
  case "$tool:$mgr" in
    postgresql:brew) echo "postgresql@18";;
    postgresql:*) echo "postgresql";;
    mysql:apt) if apt_mysql_is_mariadb; then echo "mariadb"; else echo "mysql"; fi;;
    mysql:*) echo "mysqld";;
    mariadb:*) echo "mariadb";;
    redis:apt) echo "redis-server";;
    redis:*) echo "redis";;
    valkey:apt) echo "valkey-server";;
    valkey:*) echo "valkey";;
    couchdb:*) echo "couchdb";;
    neo4j:*) echo "neo4j";;
    cassandra:*) echo "cassandra";;
    nginx:*) echo "nginx";;
    apache2:apt|apache2:zypper) echo "apache2";;
    apache2:*) echo "httpd";;
    caddy:*) echo "caddy";;
    haproxy:*) echo "haproxy";;
    cockpit:brew) ;;
    cockpit:*) echo "cockpit.socket";;
    *) ;;
  esac
}

# A Debian/Ubuntu postinst starts its service at once: nginx, apache2 and
# caddy on 0.0.0.0:80 and cockpit.socket on *:9090, before server_setup can
# rewrite the bind. A policy-rc.d that answers 101 makes invoke-rc.d and
# deb-systemd-invoke skip that start; server_setup then binds 127.0.0.1 and
# starts it. Every apt server goes through here, although these already ship
# loopback-only defaults: mysql-server mysqld.cnf and mariadb 50-server.cnf
# "bind-address = 127.0.0.1", redis/valkey "bind 127.0.0.1 -::1", postgresql
# listen_addresses 'localhost', cassandra listen_address/rpc_address
# localhost, neo4j server.default_listen_address 127.0.0.1.
POLICY_RC_D="${POLICY_RC_D:-/usr/sbin/policy-rc.d}"
POLICY_RC_D_MARK="# distrodeck: hold service starts during install"

apt_install_no_autostart() {
  if [[ -e "$POLICY_RC_D" ]] && ! grep -qF "$POLICY_RC_D_MARK" "$POLICY_RC_D" 2>/dev/null; then
    # Someone else's policy (a container image, a build host): it decides.
    log_warn "$POLICY_RC_D exists and is not distrodeck's; leaving it in charge of service starts."
    install_pkg apt "$@"
    return
  fi
  # Subshell: its EXIT trap removes the file on success, failure and Ctrl-C,
  # without replacing the caller's traps.
  (
    trap 'sudo rm -f "$POLICY_RC_D"' EXIT
    trap 'exit 130' INT TERM
    printf '#!/bin/sh\n%s\nexit 101\n' "$POLICY_RC_D_MARK" | sudo tee "$POLICY_RC_D" >/dev/null || exit 1
    sudo chmod 755 "$POLICY_RC_D" || exit 1
    install_pkg apt "$@"
  )
}

# Rewrite listen directives so a server never binds 0.0.0.0. Each step is a
# no-op when the file is missing or already bound to loopback.
server_bind_localhost() {
  # ETC_ROOT prefixes the config paths (tests point it at a temp dir).
  local tool="$1" mgr="$2" file root="${ETC_ROOT:-}"
  case "$tool" in
    nginx)
      for file in "$root"/etc/nginx/sites-available/default "$root"/etc/nginx/nginx.conf "$root"/etc/nginx/conf.d/default.conf \
                  "$(brew_prefix_safe)/etc/nginx/nginx.conf"; do
        [[ -f "$file" ]] || continue
        sudo_if_needed "$file" sed -i.distrodeck -E \
          -e 's/^([[:space:]]*listen[[:space:]]+)([0-9]+)([[:space:];])/\1127.0.0.1:\2\3/' \
          -e 's/^([[:space:]]*listen[[:space:]]+)\[::\]:([0-9]+)/\1[::1]:\2/' "$file"
      done
      ;;
    apache2)
      for file in "$root"/etc/apache2/ports.conf "$root"/etc/httpd/conf/httpd.conf "$root"/etc/apache2/listen.conf \
                  "$(brew_prefix_safe)/etc/httpd/httpd.conf"; do
        [[ -f "$file" ]] || continue
        sudo_if_needed "$file" sed -i.distrodeck -E 's/^([[:space:]]*Listen[[:space:]]+)([0-9]+)[[:space:]]*$/\1127.0.0.1:\2/' "$file"
      done
      ;;
    caddy)
      for file in "$root"/etc/caddy/Caddyfile "$(brew_prefix_safe)/etc/Caddyfile"; do
        [[ -f "$file" ]] || continue
        grep -q 'bind 127.0.0.1' "$file" && continue
        # A backslash-newline, not "\n": BSD sed (Homebrew caddy) writes a literal n.
        sudo_if_needed "$file" sed -i.distrodeck -E 's/^(:[0-9]+[[:space:]]*\{)[[:space:]]*$/\1\
	bind 127.0.0.1/' "$file"
      done
      ;;
    mysql|mariadb)
      local dir
      for dir in "$root"/etc/mysql/conf.d "$root"/etc/my.cnf.d "$(brew_prefix_safe)/etc/my.cnf.d"; do
        [[ -d "$dir" ]] || continue
        printf '[mysqld]\nbind-address = 127.0.0.1\n' | sudo_if_needed "$dir" tee "$dir/99-distrodeck-bind.cnf" >/dev/null
        break
      done
      ;;
    cockpit)
      [[ "$mgr" == "brew" ]] && return 0
      sudo mkdir -p /etc/systemd/system/cockpit.socket.d
      printf '[Socket]\nListenStream=\nListenStream=127.0.0.1:9090\n' | \
        sudo tee /etc/systemd/system/cockpit.socket.d/distrodeck-listen.conf >/dev/null
      sudo systemctl daemon-reload 2>/dev/null || true
      ;;
  esac
  return 0
}

brew_prefix_safe() {
  if command -v brew >/dev/null 2>&1; then brew --prefix; else echo /nonexistent; fi
}

# Run "$@" with sudo unless path $1 is writable by this user (brew prefixes).
sudo_if_needed() {
  local path="$1"; shift
  if [[ -w "$path" ]]; then "$@"; else sudo "$@"; fi
}

# Initialise a fresh PostgreSQL cluster where the package does not.
postgresql_init() {
  local mgr="$1"
  case "$mgr" in
    pacman)
      if [[ ! -s /var/lib/postgres/data/PG_VERSION ]]; then
        sudo -u postgres initdb -D /var/lib/postgres/data
      fi
      ;;
    dnf)
      [[ -s /var/lib/pgsql/data/PG_VERSION ]] || sudo postgresql-setup --initdb
      ;;
  esac
}

server_setup() {
  local tool="$1" mgr="$2" unit
  if [[ "$tool:$mgr" == minio:brew ]]; then
    # The formula's service runs `--address=:9000`, every interface, so it is
    # not started for you. MinIO archived the open-source server; the formula
    # is deprecated and Homebrew disables it on 2027-02-17.
    log_warn "MinIO's open-source server is archived upstream and the minio formula is deprecated; seaweedfs is the maintained S3 option."
    log_info "Run MinIO on loopback only: minio server --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 \"\$(brew --prefix)/var/minio\""
    return 0
  fi
  unit="$(server_unit "$tool" "$mgr")"
  [[ -n "$unit" ]] || return 0
  [[ "$tool" == postgresql ]] && { postgresql_init "$mgr" || return 1; }
  server_bind_localhost "$tool" "$mgr"
  if [[ "$mgr" == "brew" ]]; then
    brew services restart "$unit" || { log_warn "brew services could not start $unit."; return 1; }
  elif command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable "$unit" || return 1
    sudo systemctl restart "$unit" || { log_warn "$unit did not start; check: journalctl -u $unit"; return 1; }
  else
    log_warn "No systemd; start $unit yourself."
  fi
  log_info "$tool is running and bound to 127.0.0.1 (service: $unit)."
}

server_teardown() {
  local tool="$1" mgr="$2" unit
  unit="$(server_unit "$tool" "$mgr")"
  [[ -n "$unit" ]] || return 0
  if [[ "$mgr" == "brew" ]]; then
    brew services stop "$unit" 2>/dev/null || true
  elif command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now "$unit" 2>/dev/null || true
  fi
  if [[ "$tool" == cockpit ]]; then
    sudo rm -f /etc/systemd/system/cockpit.socket.d/distrodeck-listen.conf
    sudo systemctl daemon-reload 2>/dev/null || true
  fi
  log_info "Kept the $tool data directory; remove it manually to drop the data."
}

# ─────────────────────────────────────────────────────────────────────────────
# Vendor apt repositories (cassandra, neo4j), same signed-by pattern as MongoDB
# ─────────────────────────────────────────────────────────────────────────────
# Print the primary-key fingerprints in key file $1, one per line.
key_fingerprints() {
  local home rc=0
  home="$(mktemp -d)"
  gpg --homedir "$home" --batch --show-keys --with-colons "$1" 2>/dev/null | \
    awk -F: '$1 == "pub" {want = 1; next} $1 == "fpr" && want {print $10; want = 0}' || rc=$?
  rm -rf "$home"
  return "$rc"
}

# Refuse key file $1 unless every primary key in it is fingerprint $2: a file
# that adds a second key would make apt or dnf trust that key as well.
verify_key_fingerprint() {
  local file="$1" expected="$2" fprs
  fprs="$(key_fingerprints "$file")"
  if [[ "$fprs" != "$expected" ]]; then
    log_error "Signing key fingerprint mismatch: expected ${expected}, got: ${fprs:-no key}. Refusing it."
    return 1
  fi
}

# Usage: apt_vendor_repo <name> <key-url> <repo-url> <suite> <component> [fingerprint]
# Without a fingerprint the file must still hold a key, and its fingerprints are logged.
apt_vendor_repo() {
  local name="$1" key_url="$2" url="$3" suite="$4" component="$5" fingerprint="${6:-}"
  local keyring="/usr/share/keyrings/${name}.gpg" tmp_key tmp_home
  command -v gpg >/dev/null 2>&1 || install_pkg apt gnupg || return 1
  tmp_key="$(mktemp)"; tmp_home="$(mktemp -d)"
  if ! download_file "$key_url" "$tmp_key"; then
    log_warn "Failed to download the $name signing key."
    rm -rf "$tmp_key" "$tmp_home"
    return 1
  fi
  if [[ -n "$fingerprint" ]]; then
    verify_key_fingerprint "$tmp_key" "$fingerprint" || { rm -rf "$tmp_key" "$tmp_home"; return 1; }
  else
    local fprs
    fprs="$(key_fingerprints "$tmp_key")"
    if [[ -z "$fprs" ]]; then
      log_error "The $name key file holds no OpenPGP key; refusing it."
      rm -rf "$tmp_key" "$tmp_home"
      return 1
    fi
    log_info "$name signing keys: $(tr '\n' ' ' <<< "$fprs")"
  fi
  # Import then export: a KEYS file holds several armored keys and
  # `gpg --dearmor` would keep only the first.
  if ! gpg --homedir "$tmp_home" --batch --quiet --import "$tmp_key" || \
     ! gpg --homedir "$tmp_home" --batch --export > "$tmp_key.gpg"; then
    rm -rf "$tmp_key" "$tmp_key.gpg" "$tmp_home"
    return 1
  fi
  sudo install -m 644 "$tmp_key.gpg" "$keyring" || { rm -rf "$tmp_key" "$tmp_key.gpg" "$tmp_home"; return 1; }
  rm -rf "$tmp_key" "$tmp_key.gpg" "$tmp_home"
  echo "deb [signed-by=${keyring}] ${url} ${suite} ${component}" | \
    sudo tee "/etc/apt/sources.list.d/${name}.list" >/dev/null
}

apt_vendor_repo_remove() {
  sudo rm -f "/etc/apt/sources.list.d/$1.list" "/usr/share/keyrings/$1.gpg"
}

install_cassandra() {
  local mgr="$1"
  if [[ "$mgr" != "apt" ]]; then
    log_warn "cassandra: only the Apache apt repository (and brew) is supported; ${mgr} has no official package."
    return 1
  fi
  # Not pinned: KEYS is the set of release managers' keys and changes when one
  # joins, and Apache publishes no single repository fingerprint. The file is
  # checked to hold keys and their fingerprints are logged.
  apt_vendor_repo cassandra https://downloads.apache.org/cassandra/KEYS \
    https://debian.cassandra.apache.org 50x main || return 1
  apt_install_no_autostart cassandra
}

uninstall_cassandra() {
  [[ "$1" == "apt" ]] || return 1
  uninstall_pkg apt cassandra || return 1
  apt_vendor_repo_remove cassandra
}

# Neo4j Admins <admins@neotechnology.com>, key id 59D700E4D37F5F19.
NEO4J_KEY_FINGERPRINT="1EEFB8767D4924B86EAD08A459D700E4D37F5F19"

install_neo4j() {
  local mgr="$1"
  if [[ "$mgr" != "apt" ]]; then
    log_warn "neo4j: only the Neo4j apt repository (and brew) is supported; ${mgr} has no official package."
    return 1
  fi
  apt_vendor_repo neo4j https://debian.neo4j.com/neotechnology.gpg.key \
    https://debian.neo4j.com stable latest "$NEO4J_KEY_FINGERPRINT" || return 1
  apt_install_no_autostart neo4j
}

uninstall_neo4j() {
  [[ "$1" == "apt" ]] || return 1
  uninstall_pkg apt neo4j || return 1
  apt_vendor_repo_remove neo4j
}

uninstall_nvm() {
  unwire_nvm_profile "$HOME/.bashrc"
  unwire_nvm_profile "$HOME/.zshrc"
  log_info "Left ${NVM_INSTALL_DIR} in place; remove it to drop nvm-managed Node versions."
}

install_sdkman() {
  command -v curl >/dev/null 2>&1 || install_curl "$1" || return 1
  command -v zip >/dev/null 2>&1 || install_pkg "$1" zip || true
  run_downloaded_script "https://get.sdkman.io?rcupdate=true"
}

uninstall_sdkman() {
  log_warn "Remove SDKMAN with: rm -rf ${SDKMAN_DIR:-$HOME/.sdkman} and its lines in ~/.bashrc / ~/.zshrc."
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Containers: pinned tag, named volume, 127.0.0.1 ports, refuse busy ports
# ─────────────────────────────────────────────────────────────────────────────
# Fields: image ports(comma) data-path. Tags were checked on the registry API.
container_spec() {
  case "$1" in
    oracle-free) echo "docker.io/gvenzl/oracle-free:23.9-slim 1521 /opt/oracle/oradata";;
    qdrant) echo "docker.io/qdrant/qdrant:v1.19.1 6333,6334 /qdrant/storage";;
    milvus) echo "docker.io/milvusdb/milvus:v2.6.25 19530,9091 /var/lib/milvus";;
    weaviate) echo "docker.io/semitechnologies/weaviate:1.39.8 8080,50051 /var/lib/weaviate";;
    seaweedfs) echo "docker.io/chrislusf/seaweedfs:4.48 8333 /data";;
    *) return 1;;
  esac
}

# Extra `run` arguments (environment, command) per container, one per line.
container_args() {
  case "$1" in
    # The password goes in through a 600 env file, never on the command line.
    oracle-free) printf '%s\n' --env-file "$(container_env_file oracle-free ORACLE_PASSWORD)";;
    # As milvus scripts/standalone_embed.sh at the pinned tag (v2.6.25) runs
    # it: same env, config mounts and seccomp:unconfined. The embedded etcd
    # listens on 2379 inside the container only; that port is not published.
    milvus)
      local conf
      conf="$(milvus_config_dir)" || return 1
      printf '%s\n' --security-opt seccomp:unconfined \
        -e ETCD_USE_EMBED=true -e ETCD_DATA_DIR=/var/lib/milvus/etcd \
        -e ETCD_CONFIG_PATH=/milvus/configs/embedEtcd.yaml \
        -e COMMON_STORAGETYPE=local -e DEPLOY_MODE=STANDALONE \
        -v "$conf/embedEtcd.yaml:/milvus/configs/embedEtcd.yaml:ro,Z" \
        -v "$conf/user.yaml:/milvus/configs/user.yaml:ro,Z" \
        -- milvus run standalone
      ;;
    weaviate) printf '%s\n' -e PERSISTENCE_DATA_PATH=/var/lib/weaviate \
      -e AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=true -e DEFAULT_VECTORIZER_MODULE=none \
      -e CLUSTER_HOSTNAME=node1;;
    seaweedfs) printf '%s\n' -- server -s3 -dir=/data;;
  esac
}

# Write the embedded-etcd and user configs standalone_embed.sh mounts; print the dir.
milvus_config_dir() {
  local dir="$STATE_DIR/milvus"
  mkdir -p "$dir" || return 1
  cat > "$dir/embedEtcd.yaml" <<'YAML'
listen-client-urls: http://0.0.0.0:2379
advertise-client-urls: http://0.0.0.0:2379
quota-backend-bytes: 4294967296
auto-compaction-mode: revision
auto-compaction-retention: '1000'
YAML
  [[ -f "$dir/user.yaml" ]] || echo "# Extra config to override default milvus.yaml" > "$dir/user.yaml"
  printf '%s\n' "$dir"
}

# A random password kept in the state dir (mode 600), created once.
container_secret() {
  local file="$STATE_DIR/$1.password"
  ensure_state_dir
  if [[ ! -s "$file" ]]; then
    # Bounded input: `tr < /dev/urandom | head` never ended on a macOS runner.
    (umask 077; head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24 > "$file")
  fi
  cat "$file"
}

# Write "<VAR>=<secret>" for container $1 to a mode-600 env file; print its path.
container_env_file() {
  local file="$STATE_DIR/$1.env"
  (umask 077; printf '%s=%s\n' "$2" "$(container_secret "$1")" > "$file")
  printf '%s\n' "$file"
}

# Print the container CLI to use ("docker", "sudo docker" or "podman").
container_cli() {
  if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then echo docker; return 0; fi
    if sudo -n docker info >/dev/null 2>&1; then echo "sudo docker"; return 0; fi
    # A docker CLI whose daemon is unreachable: podman works without one.
    if command -v podman >/dev/null 2>&1; then echo podman; return 0; fi
    echo "sudo docker"; return 0
  fi
  if command -v podman >/dev/null 2>&1; then echo podman; return 0; fi
  return 1
}

# Print the process holding TCP port $1 on any address, or nothing if free.
port_holder() {
  local port="$1" line
  if command -v ss >/dev/null 2>&1; then
    line="$(ss -ltnpH "sport = :$port" 2>/dev/null | head -n 1)"
    [[ -n "$line" ]] || return 1
  else
    # Unprivileged lsof lists only this user's sockets, so a root or other
    # user's listener needs netstat (every socket, tcp4/tcp6/tcp46, no names).
    if command -v lsof >/dev/null 2>&1; then
      line="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed -n 2p)"
      if [[ -n "$line" ]]; then
        awk '{print $1}' <<< "$line"
        return 0
      fi
    fi
    if command -v netstat >/dev/null 2>&1 && \
       netstat -an 2>/dev/null | awk -v p="$port" '
         toupper($0) ~ /LISTEN/ && $1 ~ /^tcp/ {
           n = split($4, a, /[.:]/); if (a[n] == p) found = 1
         } END { exit !found }'; then
      printf '%s\n' "another user's process (run as root to see it)"
      return 0
    fi
    return 1
  fi
  if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "an unknown process (run as root to see it)"
  fi
}

# Detection only: never prompts for a password (sudo -n), asks once per run.
CONTAINER_CLI_CACHE=""
container_installed() {
  local cli
  if [[ -z "$CONTAINER_CLI_CACHE" ]]; then
    CONTAINER_CLI_CACHE="$(container_cli 2>/dev/null || echo none)"
  fi
  cli="$CONTAINER_CLI_CACHE"
  [[ "$cli" == none ]] && return 1
  [[ "$cli" == "sudo docker" ]] && cli="sudo -n docker"
  $cli container inspect "distrodeck-$1" >/dev/null 2>&1
}

install_container_tool() {
  local tool="$1" image ports data cli port holder
  read -r image ports data <<< "$(container_spec "$tool")"
  if ! cli="$(container_cli)"; then
    log_warn "$tool runs in a container and needs docker or podman. Install the docker or podman tool (DevOps & Containers) first."
    return 1
  fi
  if $cli container inspect "distrodeck-$tool" >/dev/null 2>&1; then
    log_info "Container distrodeck-$tool already exists; starting it."
    $cli start "distrodeck-$tool" >/dev/null
    return
  fi
  local publish=()
  for port in ${ports//,/ }; do
    if holder="$(port_holder "$port")"; then
      log_error "Port $port is already in use by ${holder}; refusing to start $tool."
      return 1
    fi
    publish+=(-p "127.0.0.1:${port}:${port}")
  done
  if [[ "$tool" == milvus ]]; then
    milvus_config_dir >/dev/null || { log_error "Could not write the Milvus config in $STATE_DIR/milvus."; return 1; }
  fi
  local extra=() run_cmd=() arg seen_cmd=false
  while IFS= read -r arg; do
    [[ -z "$arg" ]] && continue
    if [[ "$arg" == "--" ]]; then seen_cmd=true; continue; fi
    if $seen_cmd; then run_cmd+=("$arg"); else extra+=("$arg"); fi
  done < <(container_args "$tool")
  log_info "Starting $image as distrodeck-$tool (volume distrodeck-$tool, ports ${ports} on 127.0.0.1)."
  # shellcheck disable=SC2086  # cli may be "sudo docker"
  $cli run -d --name "distrodeck-$tool" --restart unless-stopped \
    -v "distrodeck-$tool:$data" "${publish[@]}" "${extra[@]}" "$image" "${run_cmd[@]}" || return 1
  [[ "$tool" == oracle-free ]] && log_info "Oracle password (SYSTEM, PDB FREEPDB1): see $STATE_DIR/oracle-free.password"
  return 0
}

uninstall_container_tool() {
  local tool="$1" cli
  cli="$(container_cli)" || { log_warn "docker/podman not found; nothing to remove for $tool."; return 1; }
  $cli rm -f "distrodeck-$tool" >/dev/null || return 1
  if [[ "${DISTRODECK_PURGE:-}" == "1" ]]; then
    $cli volume rm "distrodeck-$tool" >/dev/null && log_info "Removed volume distrodeck-$tool."
    # The data is gone, so its generated password and configs go too.
    rm -f -- "$STATE_DIR/$tool.password" "$STATE_DIR/$tool.env"
    if [[ "$tool" == milvus ]]; then rm -rf -- "$STATE_DIR/milvus"; fi
  else
    log_info "Kept volume distrodeck-$tool with the data; --purge removes it."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Claude Code plugins (public anthropics/claude-plugins-official only)
# ─────────────────────────────────────────────────────────────────────────────
CLAUDE_MARKETPLACE="claude-plugins-official"
CLAUDE_MARKETPLACE_REPO="anthropics/claude-plugins-official"

claude_plugin_id() {
  printf '%s@%s\n' "$(spec_field "$1" extra)" "$CLAUDE_MARKETPLACE"
}

# `claude plugin list` takes about a second; ask once per run.
CLAUDE_PLUGIN_LIST_CACHE=""
claude_plugin_installed() {
  command -v claude >/dev/null 2>&1 || return 1
  if [[ -z "$CLAUDE_PLUGIN_LIST_CACHE" ]]; then
    CLAUDE_PLUGIN_LIST_CACHE="$(claude plugin list 2>/dev/null || true)"
    [[ -n "$CLAUDE_PLUGIN_LIST_CACHE" ]] || CLAUDE_PLUGIN_LIST_CACHE=" "
  fi
  grep -qF "$(claude_plugin_id "$1")" <<< "$CLAUDE_PLUGIN_LIST_CACHE"
}

install_claude_plugin() {
  local tool="$1"
  if ! command -v claude >/dev/null 2>&1; then
    log_warn "$tool is a Claude Code plugin and needs the claude CLI. Install the claude-code tool (AI tools) first."
    return 1
  fi
  if ! claude plugin marketplace list 2>/dev/null | grep -qF "$CLAUDE_MARKETPLACE"; then
    claude_bounded plugin marketplace add "$CLAUDE_MARKETPLACE_REPO" --scope user || return 1
  fi
  claude_bounded plugin install "$(claude_plugin_id "$tool")" --scope user
}

uninstall_claude_plugin() {
  command -v claude >/dev/null 2>&1 || { log_warn "claude CLI not found."; return 1; }
  claude_bounded plugin uninstall "$(claude_plugin_id "$1")" --scope user
}

# Run `claude "$@"` with no stdin and a time limit, so a prompt can never hold
# up a --tools or --all run. Without a TTY `plugin install` refuses (rather
# than asks) when a plugin needs a confirmed command; -y is deliberately not
# passed, so such a plugin fails and must be installed by hand.
CLAUDE_PLUGIN_TIMEOUT="${DISTRODECK_PLUGIN_TIMEOUT:-300}"
claude_bounded() {
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$CLAUDE_PLUGIN_TIMEOUT" claude "$@" </dev/null || rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 10 "$CLAUDE_PLUGIN_TIMEOUT" claude "$@" </dev/null || rc=$?
  else
    # macOS without coreutils: the alarm survives exec and SIGALRM ends claude.
    perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$CLAUDE_PLUGIN_TIMEOUT" claude "$@" </dev/null || rc=$?
  fi
  if [[ "$rc" -eq 124 || "$rc" -eq 137 || "$rc" -eq 142 ]]; then
    log_error "claude $* gave no answer in ${CLAUDE_PLUGIN_TIMEOUT}s; stopped it."
  fi
  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# macOS: Homebrew names for catalog tools without a spec row
# ─────────────────────────────────────────────────────────────────────────────
# A formula, cask:<name>, "=" (the tool's own installer works on macOS) or
# nothing (Linux-only: hidden on macOS). Names checked on formulae.brew.sh.
legacy_brew_name() {
  case "$1" in
    bat|eza|fd|fzf|glow|jq|ripgrep|tree|yq|zoxide|zsh|micro|neovim|screen|tmux) echo "$1";;
    bandwhich|duf|htop|ncdu|curl|iperf3|mtr|nmap|tcpdump|tor|wget) echo "$1";;
    borgbackup|duplicity|fdupes|lz4|bfg|gh|git|git-lfs|lazygit|tokei) echo "$1";;
    go|php|ruby|rust|composer|ansible|k9s|lazydocker|podman|ollama|dialog) echo "$1";;
    tldr) echo "tlrc";;
    mc) echo "midnight-commander";;
    bind-tools) echo "bind";;
    delta) echo "git-delta";;
    node) echo "node@24";;
    java) echo "openjdk@${JAVA_VERSION}";;
    atlas) echo "mongodb-atlas-cli";;
    meld) echo "cask:meld";;
    docker) echo "cask:docker-desktop";;
    vscode) echo "cask:visual-studio-code";;
    cursor) echo "cask:cursor";;
    kiro) echo "cask:kiro";;
    antigravity) echo "cask:antigravity";;
    gimp) echo "cask:gimp";;
    adb) echo "cask:android-platform-tools";;
    rustdesk) echo "cask:rustdesk";;
    aider|claude-code|codex|copilot|gemini|git-lantern|ai-runner|image-view) echo "=";;
    *) ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# MongoDB (official repository, shared by mongodb and atlas)
# ─────────────────────────────────────────────────────────────────────────────
# 8.2 is the current on-premises series; DISTRODECK_MONGODB_SERIES=8.0 picks
# the previous one. Only series signed by the key below are accepted: 9.0 is
# signed by a different key that MongoDB does not publish at a stable URL yet.
MONGODB_SERIES="${DISTRODECK_MONGODB_SERIES:-8.2}"
MONGODB_SUPPORTED_SERIES="8.0 8.2"
MONGODB_KEY_URL="https://pgp.mongodb.com/server-8.0.asc"
# "MongoDB 8.0 Release Signing Key", key id 41DE058A4E7DCA05.
MONGODB_KEY_FINGERPRINT="4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05"
MONGODB_RPM_KEY="/etc/pki/rpm-gpg/RPM-GPG-KEY-mongodb-server-8.0"
MONGODB_KEYRING="/usr/share/keyrings/mongodb-server.gpg"
MONGODB_APT_LIST="/etc/apt/sources.list.d/mongodb-org.list"
MONGODB_YUM_REPO="/etc/yum.repos.d/mongodb-org.repo"

# Print the value of KEY from os-release (OS_RELEASE_FILE overrides the path).
# Parsed, not sourced: the file is data, and sourcing it runs it.
os_release_value() {
  local key="$1" file="${OS_RELEASE_FILE:-/etc/os-release}" value
  [[ -r "$file" ]] || return 0
  value="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
  value="${value#[\"\']}"
  value="${value%[\"\']}"
  printf '%s\n' "$value"
}

# Print "<distro-path> <codename> <component>" for the apt repository, or
# nothing when this release has no MongoDB packages.
mongodb_apt_target() {
  local id codename
  id="$(os_release_value ID)"
  codename="$(os_release_value UBUNTU_CODENAME)"
  [[ -n "$codename" ]] || codename="$(os_release_value VERSION_CODENAME)"
  case "$codename" in
    jammy|noble) echo "ubuntu $codename multiverse";;
    bookworm|trixie) echo "debian $codename main";;
    *)
      log_warn "MongoDB publishes apt packages for Ubuntu jammy/noble and Debian bookworm/trixie; this system is ${id:-unknown} ${codename:-unknown}."
      return 1
      ;;
  esac
}

# Print the RHEL major used in the yum repository path.
mongodb_rpm_release() {
  local id version
  id="$(os_release_value ID)"
  version="$(os_release_value VERSION_ID)"
  version="${version%%.*}"
  case "$id" in
    fedora)
      log_warn "MongoDB does not publish Fedora packages; using the RHEL 9 repository."
      echo 9
      ;;
    rhel|centos|rocky|almalinux|ol)
      case "$version" in
        8|9|10) echo "$version";;
        *) log_warn "MongoDB has no packages for $id $version."; return 1;;
      esac
      ;;
    *) log_warn "MongoDB has no dnf repository for ${id:-this distro}."; return 1;;
  esac
}

mongodb_repo_setup() {
  local mgr="$1"
  if [[ " $MONGODB_SUPPORTED_SERIES " != *" $MONGODB_SERIES "* ]]; then
    log_warn "Unsupported MongoDB series '$MONGODB_SERIES'; choose one of: $MONGODB_SUPPORTED_SERIES."
    return 1
  fi
  case "$mgr" in
    apt)
      local target distro codename component tmp_key
      target="$(mongodb_apt_target)" || return 1
      read -r distro codename component <<< "$target"
      command -v gpg >/dev/null 2>&1 || install_pkg "$mgr" gnupg || return 1
      command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || install_curl "$mgr" || return 1
      tmp_key="$(mktemp)"
      if ! download_file "$MONGODB_KEY_URL" "$tmp_key"; then
        log_warn "Failed to download the MongoDB signing key."
        rm -f "$tmp_key"
        return 1
      fi
      verify_key_fingerprint "$tmp_key" "$MONGODB_KEY_FINGERPRINT" || { rm -f "$tmp_key"; return 1; }
      if ! sudo gpg --batch --yes -o "$MONGODB_KEYRING" --dearmor "$tmp_key"; then
        rm -f "$tmp_key"
        return 1
      fi
      rm -f "$tmp_key"
      sudo chmod 644 "$MONGODB_KEYRING"
      echo "deb [arch=$(dpkg --print-architecture) signed-by=${MONGODB_KEYRING}] https://repo.mongodb.org/apt/${distro} ${codename}/mongodb-org/${MONGODB_SERIES} ${component}" | \
        sudo tee "$MONGODB_APT_LIST" >/dev/null
      ;;
    dnf)
      local release
      release="$(mongodb_rpm_release)" || return 1
      # dnf would fetch gpgkey= itself and trust whatever came back; install
      # the verified key locally and point the repo at it instead.
      local rpm_key
      command -v gpg >/dev/null 2>&1 || install_pkg "$mgr" gnupg2 || return 1
      rpm_key="$(mktemp)"
      if ! download_file "$MONGODB_KEY_URL" "$rpm_key"; then
        log_warn "Failed to download the MongoDB signing key."
        rm -f "$rpm_key"
        return 1
      fi
      verify_key_fingerprint "$rpm_key" "$MONGODB_KEY_FINGERPRINT" || { rm -f "$rpm_key"; return 1; }
      sudo install -D -m 644 "$rpm_key" "$MONGODB_RPM_KEY" || { rm -f "$rpm_key"; return 1; }
      rm -f "$rpm_key"
      sudo tee "$MONGODB_YUM_REPO" >/dev/null <<REPO
[mongodb-org-${MONGODB_SERIES}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/${release}/mongodb-org/${MONGODB_SERIES}/\$basearch/
gpgcheck=1
enabled=1
gpgkey=file://${MONGODB_RPM_KEY}
REPO
      ;;
    *)
      log_warn "MongoDB publishes no official repository for ${mgr}; install it from https://www.mongodb.com/try/download/community instead."
      return 1
      ;;
  esac
}

# Remove the repository and keyring only when no MongoDB package still needs them.
mongodb_repo_remove_if_unused() {
  local mgr="$1"
  case "$mgr" in
    apt)
      if dpkg-query -W -f='${db:Status-Status}\n' mongodb-org mongodb-atlas-cli 2>/dev/null | grep -qx installed; then
        log_info "Keeping the MongoDB repository: another MongoDB package still uses it."
        return 0
      fi
      sudo rm -f "$MONGODB_APT_LIST" "$MONGODB_KEYRING"
      ;;
    dnf)
      if rpm -q mongodb-org mongodb-atlas-cli 2>/dev/null | grep -qv 'not installed'; then
        log_info "Keeping the MongoDB repository: another MongoDB package still uses it."
        return 0
      fi
      sudo rm -f "$MONGODB_YUM_REPO" "$MONGODB_RPM_KEY"
      ;;
  esac
}

install_mongodb() {
  local mgr="$1"
  mongodb_repo_setup "$mgr" || return 1
  install_pkg "$mgr" mongodb-org mongodb-mongosh || return 1
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now mongod || { log_warn "mongod did not start; check: journalctl -u mongod"; return 1; }
  fi
  # The package default binds 127.0.0.1; distrodeck leaves it that way.
  log_info "mongod listens on 127.0.0.1:27017 only (bindIp in /etc/mongod.conf). Connect with: mongosh"
}

uninstall_mongodb() {
  local mgr="$1"
  case "$mgr" in
    apt|dnf) ;;
    *) log_warn "MongoDB uninstall is not supported for ${mgr}."; return 1;;
  esac
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now mongod 2>/dev/null || true
  fi
  # apt 2.x dropped package-name globs, so apt gets the explicit dependency set
  # of mongodb-org; dnf matches the glob itself.
  local pkgs=(mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos
    mongodb-org-shell mongodb-org-tools mongodb-org-database-tools-extra
    mongodb-database-tools mongodb-mongosh)
  [[ "$mgr" == "dnf" ]] && pkgs=('mongodb-org*' mongodb-database-tools mongodb-mongosh)
  uninstall_pkg "$mgr" "${pkgs[@]}" || return 1
  mongodb_repo_remove_if_unused "$mgr"
  log_info "Kept the MongoDB data in /var/lib/mongodb (dnf: /var/lib/mongo); remove it manually to drop the databases."
}

install_atlas() {
  local mgr="$1"
  mongodb_repo_setup "$mgr" || return 1
  install_pkg "$mgr" mongodb-atlas-cli || return 1
  if command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; then
    log_info "Run a local Atlas deployment (no cloud login needed): atlas deployments setup --type local"
  else
    log_info "atlas deployments setup --type local needs docker or podman; install one of them first."
  fi
}

uninstall_atlas() {
  local mgr="$1"
  case "$mgr" in
    apt|dnf) ;;
    *) log_warn "Atlas CLI uninstall is not supported for ${mgr}."; return 1;;
  esac
  uninstall_pkg "$mgr" mongodb-atlas-cli || return 1
  mongodb_repo_remove_if_unused "$mgr"
}

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall functions for tools that need special handling
# ─────────────────────────────────────────────────────────────────────────────

uninstall_pkg_simple() {
  uninstall_pkg "$1" "$2" || log_warn "Failed to uninstall $2 from repos."
}

uninstall_docker() {
  local mgr="$1"
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl disable --now docker || true
  fi
  case "$mgr" in
    apt) uninstall_pkg "$mgr" docker.io;;
    dnf|pacman|zypper) uninstall_pkg "$mgr" docker;;
    *) log_warn "Docker uninstall not supported for this distro.";;
  esac
}

uninstall_fd() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" fd-find;;
    dnf|pacman|zypper) uninstall_pkg "$mgr" fd;;
    *) log_warn "fd uninstall not supported for this distro.";;
  esac
}

uninstall_adb() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" android-tools-adb;;
    dnf|pacman|zypper) uninstall_pkg "$mgr" android-tools;;
    *) log_warn "adb uninstall not supported for this distro.";;
  esac
}

uninstall_build_tools() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" build-essential;;
    dnf) uninstall_pkg "$mgr" gcc gcc-c++ make;;
    pacman) uninstall_pkg "$mgr" base-devel;;
    zypper) uninstall_pkg "$mgr" gcc gcc-c++ make;;
    *) log_warn "Build tools uninstall not supported for this distro.";;
  esac
}

uninstall_node() {
  local mgr="$1"
  case "$mgr" in
    apt)
      uninstall_pkg "$mgr" nodejs npm || true
      sudo rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
      sudo rm -f /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
      ;;
    dnf)
      uninstall_pkg "$mgr" nodejs npm || true
      sudo rm -f /etc/yum.repos.d/nodesource-nodistro.repo 2>/dev/null || true
      sudo rm -f /etc/pki/rpm-gpg/NODESOURCE-GPG-SIGNING-KEY-EL 2>/dev/null || true
      ;;
    pacman|zypper) uninstall_pkg "$mgr" nodejs npm;;
    *) log_warn "Node uninstall not supported for this distro.";;
  esac

  # Remove the shell wiring distrodeck added, but never ~/.nvm itself: it holds
  # Node versions and global npm packages the user installed by hand.
  unwire_nvm_profile "$HOME/.bashrc"
  unwire_nvm_profile "$HOME/.zshrc"
  if [[ -d "$NVM_INSTALL_DIR" ]]; then
    log_info "Left nvm in place at ${NVM_INSTALL_DIR}; remove it manually to drop nvm-managed Node versions."
  fi
}

uninstall_java() {
  local mgr="$1" version pkg
  # Remove the JDK distrodeck installed, not whatever version is configured now.
  # No state file means an install from before the version choice existed,
  # which used these package names.
  if version="$(cat "$JAVA_STATE_FILE" 2>/dev/null)"; then
    pkg="$(java_package "$mgr" "$version")" || pkg=""
  else
    case "$mgr" in
      apt) pkg="default-jdk";;
      dnf) pkg="java-17-openjdk-devel";;
      pacman) pkg="jdk-openjdk";;
      zypper) pkg="java-17-openjdk";;
      *) pkg="";;
    esac
  fi
  if [[ -z "$pkg" ]]; then
    log_warn "Java uninstall not supported for this distro."
    return 1
  fi
  local remove=("$pkg")
  if [[ "$mgr" == "apt" ]]; then
    # openjdk-N-jdk holds only the GUI bits; the JDK is in -headless. The
    # legacy default-jdk is a metapackage for the release's openjdk-N-jdk.
    local deps
    deps="$(dpkg-query -W -f='${Depends}' "$pkg" 2>/dev/null | tr ',|' '\n\n' | awk '{print $1}' | grep -E '^(default-jdk-headless|openjdk-[0-9]+-jdk(-headless)?)$' || true)"
    mapfile -t remove < <(apt_installed_matching "$pkg" "${pkg}-headless" $deps | sort -u)
    # Second level: default-jdk -> openjdk-N-jdk -> openjdk-N-jdk-headless.
    local extra p
    for p in "${remove[@]}"; do
      [[ "$p" =~ ^openjdk-[0-9]+-jdk$ ]] && extra+=" ${p}-headless"
    done
    if [[ -n "${extra:-}" ]]; then
      # shellcheck disable=SC2086  # package names, no globs
      mapfile -t remove < <(apt_installed_matching "${remove[@]}" $extra | sort -u)
    fi
    [[ ${#remove[@]} -gt 0 ]] || remove=("$pkg")
  fi
  uninstall_pkg "$mgr" "${remove[@]}" || return 1
  rm -f "$JAVA_STATE_FILE"
}

uninstall_rust() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" rustc cargo;;
    dnf) uninstall_pkg "$mgr" rust cargo;;
    pacman) uninstall_pkg "$mgr" rust;;
    zypper) uninstall_pkg "$mgr" rust cargo;;
    *) log_warn "Rust uninstall not supported for this distro.";;
  esac
}

uninstall_go() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" golang;;
    dnf) uninstall_pkg "$mgr" golang;;
    pacman) uninstall_pkg "$mgr" go;;
    zypper) uninstall_pkg "$mgr" go;;
    *) log_warn "Go uninstall not supported for this distro.";;
  esac
}

uninstall_vscode() {
  if command -v snap >/dev/null 2>&1; then
    sudo snap remove code || true
    return
  fi
  local mgr="$1"
  uninstall_pkg "$mgr" code || log_warn "Failed to uninstall VS Code."
}

uninstall_lazygit() {
  local mgr="$1"
  # Try package manager first
  if [[ "$mgr" == "apt" ]]; then
    uninstall_pkg "$mgr" lazygit || true
  else
    uninstall_pkg "$mgr" lazygit || uninstall_pkg "$mgr" lazygit-gm || true
  fi
  # Remove go install version
  rm -f "$HOME/.local/bin/lazygit" 2>/dev/null || true
  # Remove manual install version
  sudo rm -f /usr/local/bin/lazygit 2>/dev/null || true
  # Try snap removal
  if command -v snap >/dev/null 2>&1; then
    sudo snap remove lazygit 2>/dev/null || true
    sudo snap remove lazygit-gm 2>/dev/null || true
  fi
}

uninstall_lazydocker() {
  local mgr="$1"
  uninstall_pkg "$mgr" lazydocker || true
  # Remove manual install version
  rm -f "$HOME/.local/bin/lazydocker" 2>/dev/null || true
  sudo rm -f /usr/local/bin/lazydocker 2>/dev/null || true
}

uninstall_image_view() {
  # Installed via cargo
  if command -v cargo >/dev/null 2>&1; then
    cargo uninstall image-view 2>/dev/null || true
  fi
  rm -f "$HOME/.cargo/bin/image-view" 2>/dev/null || true
}

uninstall_isoforge() {
  local mgr="$1"
  if dpkg -s isoforge >/dev/null 2>&1; then
    sudo dpkg -r isoforge || true
  fi
  uninstall_pkg "$mgr" isoforge || true
}

uninstall_bfg() {
  local mgr="$1"
  # Try package manager first
  case "$mgr" in
    apt) uninstall_pkg "$mgr" bfg || true;;
    pacman) uninstall_pkg "$mgr" bfg || true;;
  esac
  # Remove manual install version
  sudo rm -f /usr/local/bin/bfg 2>/dev/null || true
  sudo rm -rf /usr/local/lib/bfg 2>/dev/null || true
}

uninstall_gh() {
  local mgr="$1"
  case "$mgr" in
    apt)
      uninstall_pkg "$mgr" gh || true
      # Optionally remove the repo
      sudo rm -f /etc/apt/sources.list.d/github-cli.list 2>/dev/null || true
      sudo rm -f /etc/apt/keyrings/githubcli-archive-keyring.gpg 2>/dev/null || true
      ;;
    dnf|zypper)
      uninstall_pkg "$mgr" gh || true
      ;;
    pacman)
      uninstall_pkg "$mgr" github-cli || true
      ;;
    *)
      log_warn "gh CLI uninstall not supported for this distro."
      ;;
  esac
}

uninstall_tldr() {
  local mgr="$1"
  # Try package manager
  uninstall_pkg "$mgr" tldr 2>/dev/null || true
  uninstall_pkg "$mgr" tealdeer 2>/dev/null || true
  # Remove cargo install version
  rm -f "$HOME/.cargo/bin/tldr" 2>/dev/null || true
  # Remove npm global install
  if command -v npm >/dev/null 2>&1; then
    sudo npm uninstall -g tldr 2>/dev/null || true
  fi
  # Remove pip install version
  if command -v pip3 >/dev/null 2>&1; then
    pip3 uninstall -y tldr 2>/dev/null || true
  fi
}

uninstall_bandwhich() {
  local mgr="$1"
  uninstall_pkg "$mgr" bandwhich || true
  # Remove cargo install version
  rm -f "$HOME/.cargo/bin/bandwhich" 2>/dev/null || true
}

uninstall_k9s() {
  local mgr="$1"
  uninstall_pkg "$mgr" k9s || true
  # Remove manual install version
  sudo rm -f /usr/local/bin/k9s 2>/dev/null || true
}

uninstall_podman() {
  uninstall_pkg "$1" podman || log_warn "Failed to uninstall podman."
}

uninstall_tokei() {
  local mgr="$1"
  uninstall_pkg "$mgr" tokei || true
  # Remove cargo install version
  rm -f "$HOME/.cargo/bin/tokei" 2>/dev/null || true
}

uninstall_glow() {
  local mgr="$1"
  uninstall_pkg "$mgr" glow || true
  # Remove manual install version
  sudo rm -f /usr/local/bin/glow 2>/dev/null || true
}

uninstall_delta() {
  local mgr="$1"
  uninstall_pkg "$mgr" git-delta || true
  # Remove manual install version
  sudo rm -f /usr/local/bin/delta 2>/dev/null || true
}

uninstall_meld() {
  uninstall_pkg "$1" meld || log_warn "Failed to uninstall meld."
}

uninstall_ruby() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" ruby ruby-dev || true;;
    dnf) uninstall_pkg "$mgr" ruby ruby-devel || true;;
    pacman) uninstall_pkg "$mgr" ruby || true;;
    zypper) uninstall_pkg "$mgr" ruby ruby-devel || true;;
  esac
}

uninstall_flatpak() {
  uninstall_pkg "$1" flatpak || log_warn "Failed to uninstall flatpak."
}

uninstall_wine() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" wine wine64 wine32 || uninstall_pkg "$mgr" wine || true;;
    dnf|pacman|zypper) uninstall_pkg "$mgr" wine || true;;
  esac
}

uninstall_tor() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" tor torbrowser-launcher || uninstall_pkg "$mgr" tor || true;;
    dnf|zypper) uninstall_pkg "$mgr" tor || true;;
    pacman) uninstall_pkg "$mgr" tor torbrowser-launcher || uninstall_pkg "$mgr" tor || true;;
  esac
}

uninstall_ntfs() {
  uninstall_pkg "$1" ntfs-3g || log_warn "Failed to uninstall ntfs-3g."
}

uninstall_streamcontroller() {
  if command -v flatpak >/dev/null 2>&1; then
    flatpak uninstall -y com.core447.StreamController || log_warn "Failed to uninstall StreamController via Flatpak."
  fi
}

uninstall_rustdesk() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" rustdesk || true;;
    dnf|zypper) uninstall_pkg "$mgr" rustdesk || true;;
    pacman) uninstall_pkg "$mgr" rustdesk || true;;
  esac
  if command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -q "com.rustdesk.RustDesk"; then
    flatpak uninstall -y com.rustdesk.RustDesk || log_warn "Failed to uninstall RustDesk via Flatpak."
  fi
}

uninstall_gimp() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" gimp gimp-plugin-registry gimp-data-extras || uninstall_pkg "$mgr" gimp || true;;
    dnf) uninstall_pkg "$mgr" gimp gimp-data-extras || uninstall_pkg "$mgr" gimp || true;;
    pacman|zypper) uninstall_pkg "$mgr" gimp || true;;
  esac
}

uninstall_bind_tools() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" dnsutils;;
    dnf|pacman|zypper) uninstall_pkg "$mgr" bind-tools;;
    *) log_warn "bind-tools uninstall not supported for this distro.";;
  esac
}

uninstall_cron() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" cron;;
    dnf|pacman) uninstall_pkg "$mgr" cronie;;
    zypper) uninstall_pkg "$mgr" cron;;
    *) log_warn "cron uninstall not supported for this distro.";;
  esac
}

uninstall_npm_global() {
  local package="$1"
  if command -v npm >/dev/null 2>&1; then
    sudo npm uninstall -g "$package" || true
  else
    log_warn "npm not found; cannot uninstall $package automatically."
  fi
}

uninstall_codex() {
  uninstall_npm_global "@openai/codex"
}

uninstall_copilot() {
  uninstall_npm_global "@github/copilot"
}

uninstall_gemini() {
  uninstall_npm_global "@google/gemini-cli"
}

uninstall_claude_code() {
  log_warn "Claude Code does not expose a stable distrodeck uninstall flow yet; remove it using Claude Code's official uninstall instructions."
  return 1
}

uninstall_ollama() {
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop ollama 2>/dev/null || true
    sudo systemctl disable ollama 2>/dev/null || true
    sudo rm -f /etc/systemd/system/ollama.service 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
  else
    sudo rm -f /etc/systemd/system/ollama.service 2>/dev/null || true
  fi
  if command -v ollama >/dev/null 2>&1; then
    sudo rm -f "$(command -v ollama)" 2>/dev/null || true
  fi
  sudo rm -rf /usr/share/ollama /usr/local/lib/ollama /usr/lib/ollama /lib/ollama 2>/dev/null || true
  sudo userdel ollama 2>/dev/null || true
  sudo groupdel ollama 2>/dev/null || true
}

uninstall_cursor() {
  rm -f "$HOME/.local/bin/cursor" "$HOME/.local/bin/cursor-agent" 2>/dev/null || true
  if is_installed_tool cursor; then
    log_warn "Cursor is still installed after the uninstall attempt; remove the remaining cursor binary manually if needed."
    return 1
  fi
}

uninstall_kiro() {
  rm -f "$HOME/.local/bin/kiro" "$HOME/.local/bin/kiro-cli" 2>/dev/null || true
}

uninstall_antigravity() {
  local mgr="$1"
  case "$mgr" in
    apt)
      uninstall_pkg "$mgr" antigravity || true
      sudo rm -f /etc/apt/sources.list.d/antigravity.list 2>/dev/null || true
      sudo rm -f /etc/apt/keyrings/antigravity-repo-key.gpg 2>/dev/null || true
      ;;
    dnf)
      uninstall_pkg "$mgr" antigravity || true
      sudo rm -f /etc/yum.repos.d/antigravity.repo 2>/dev/null || true
      ;;
    zypper)
      uninstall_pkg "$mgr" antigravity || true
      sudo rm -f /etc/zypp/repos.d/antigravity.repo 2>/dev/null || true
      ;;
    *)
      log_warn "Antigravity uninstall is supported by distrodeck on apt, dnf, and zypper systems."
      return 1
      ;;
  esac
}

uninstall_aider() {
  if command -v uv >/dev/null 2>&1; then
    uv tool uninstall aider-chat 2>/dev/null || true
    uv tool uninstall aider 2>/dev/null || true
  fi
  if command -v pipx >/dev/null 2>&1; then
    pipx uninstall aider-chat 2>/dev/null || true
  fi
  rm -f "$HOME/.local/bin/aider" 2>/dev/null || true
}

tool_desc() {
  case "$1" in
    # ── Shell & CLI ──
    bat) echo "[Shell] bat - cat with syntax highlighting";;
    eza) echo "[Shell] eza - modern ls replacement";;
    fd) echo "[Shell] fd - fast find alternative";;
    fzf) echo "[Shell] fzf - fuzzy finder";;
    glow) echo "[Shell] glow - terminal markdown viewer";;
    jq) echo "[Shell] jq - JSON processor";;
    ripgrep) echo "[Shell] ripgrep (rg) - fast grep";;
    tldr) echo "[Shell] tldr - simplified man pages";;
    tree) echo "[Shell] tree - directory listing";;
    yq) echo "[Shell] yq - YAML processor";;
    zoxide) echo "[Shell] zoxide - smart cd command";;
    zsh) echo "[Shell] zsh - Z shell";;
    # ── Editors & Terminal ──
    mc) echo "[Editor] mc - Midnight Commander";;
    meld) echo "[Editor] Meld - visual diff/merge tool";;
    micro) echo "[Editor] micro - terminal text editor";;
    neovim) echo "[Editor] Neovim - vim fork";;
    screen) echo "[Term] screen - terminal multiplexer";;
    tmux) echo "[Term] tmux - terminal multiplexer";;
    # ── System & Monitoring ──
    bandwhich) echo "[System] bandwhich - bandwidth by process";;
    cron) echo "[System] cron - task scheduler";;
    duf) echo "[System] duf - disk usage viewer";;
    htop) echo "[System] htop - process viewer";;
    lm-sensors) echo "[System] lm-sensors - hardware sensors";;
    ncdu) echo "[System] ncdu - disk usage analyzer";;
    pciutils) echo "[System] pciutils - lspci";;
    usbutils) echo "[System] usbutils - lsusb";;
    # ── Networking ──
    bind-tools) echo "[Net] bind-tools - dig/nslookup";;
    curl) echo "[Net] curl - HTTP client";;
    iperf3) echo "[Net] iperf3 - network benchmark";;
    mtr) echo "[Net] mtr - traceroute + ping";;
    net-tools) echo "[Net] net-tools - ifconfig/netstat";;
    nmap) echo "[Net] nmap - network scanner";;
    tcpdump) echo "[Net] tcpdump - packet analyzer";;
    traceroute) echo "[Net] traceroute";;
    wget) echo "[Net] wget - file downloader";;
    ufw) echo "[Net] ufw - firewall";;
    # ── Backup & Storage ──
    borgbackup) echo "[Backup] borgbackup - deduplicating backup";;
    duplicity) echo "[Backup] duplicity - encrypted backup";;
    fdupes) echo "[Backup] fdupes - find duplicate files";;
    lz4) echo "[Backup] lz4 - fast compression";;
    tar) echo "[Backup] tar - archiver";;
    unzip) echo "[Backup] unzip - ZIP extractor";;
    # ── Development ──
    bfg) echo "[Dev] BFG - git repo cleaner";;
    build-tools) echo "[Dev] build-essential / toolchain";;
    composer) echo "[Dev] Composer - PHP package manager";;
    delta) echo "[Dev] delta - better git diff";;
    gh) echo "[Dev] GitHub CLI";;
    git) echo "[Dev] git - version control";;
    git-lfs) echo "[Dev] git-lfs - large file storage";;
    lazygit) echo "[Dev] LazyGit - git TUI";;
    git-lantern) echo "[Dev] git-lantern - local and GitHub repo dashboard";;
    tokei) echo "[Dev] tokei - code statistics";;
    # ── AI tools ──
    aider) echo "[AI] aider - AI pair programming";;
    ai-runner) echo "[AI] ai-runner - pick and run local Ollama models";;
    claude-code) echo "[AI] Claude Code";;
    codex) echo "[AI] OpenAI Codex CLI";;
    copilot) echo "[AI] GitHub Copilot CLI";;
    gemini) echo "[AI] Gemini CLI";;
    ollama) echo "[AI] Ollama local models";;
    # ── Languages & Runtimes ──
    go) echo "[Lang] Go";;
    java) echo "[Lang] Java JDK ${JAVA_VERSION} (17/21/25)";;
    node) echo "[Lang] Node.js 24 LTS + nvm (24/22 switchable)";;
    php) echo "[Lang] PHP";;
    ruby) echo "[Lang] Ruby";;
    rust) echo "[Lang] Rust (rustc/cargo)";;
    # ── DevOps & Containers ──
    ansible) echo "[DevOps] Ansible";;
    docker) echo "[DevOps] Docker Engine";;
    k9s) echo "[DevOps] k9s - Kubernetes TUI";;
    lazydocker) echo "[DevOps] LazyDocker - docker TUI";;
    podman) echo "[DevOps] Podman - container engine";;
    # ── Utilities ──
    adb) echo "[Util] adb - Android Debug Bridge";;
    dialog) echo "[Util] dialog - TUI dialogs";;
    flatpak) echo "[Util] Flatpak - app packaging";;
    nala) echo "[Util] Nala - prettier apt";;
    ntfs) echo "[Util] ntfs-3g - NTFS filesystem";;
    wine) echo "[Util] Wine - Windows compatibility";;
    # ── Networking ── (additional)
    tor) echo "[Net] Tor - anonymous browsing";;
    # ── IDEs ──
    antigravity) echo "[IDE] Antigravity - AI development environment";;
    cursor) echo "[IDE] Cursor IDE / Agent";;
    intellij-idea-community) echo "[IDE] IntelliJ IDEA Community";;
    kiro) echo "[IDE] Kiro IDE / CLI";;
    pycharm-community) echo "[IDE] PyCharm Community";;
    vscode) echo "[IDE] Visual Studio Code";;
    zed) echo "[IDE] Zed editor";;
    # ── Media ──
    audacity) echo "[Media] Audacity - audio editor";;
    ffmpeg) echo "[Media] FFmpeg - audio/video converter";;
    handbrake) echo "[Media] HandBrake - video transcoder";;
    kdenlive) echo "[Media] Kdenlive - video editor";;
    mpv) echo "[Media] mpv - media player";;
    obs-studio) echo "[Media] OBS Studio - recording and streaming";;
    vlc) echo "[Media] VLC - media player";;
    # ── Graphics ──
    blender) echo "[Graphics] Blender - 3D creation";;
    darktable) echo "[Graphics] darktable - photo workflow";;
    gimp) echo "[Graphics] GIMP - image editor";;
    inkscape) echo "[Graphics] Inkscape - vector graphics";;
    krita) echo "[Graphics] Krita - digital painting";;
    # ── Relational ──
    postgresql) echo "[SQL] PostgreSQL server (127.0.0.1)";;
    pgvector) echo "[SQL] pgvector - vector search for PostgreSQL";;
    mysql) echo "[SQL] MySQL server (127.0.0.1)";;
    mariadb) echo "[SQL] MariaDB server (127.0.0.1)";;
    sqlite) echo "[SQL] SQLite CLI";;
    oracle-free) echo "[SQL] Oracle Database Free (container)";;
    # ── NoSQL ──
    redis) echo "[NoSQL] Redis server (127.0.0.1)";;
    valkey) echo "[NoSQL] Valkey server (127.0.0.1)";;
    cassandra) echo "[NoSQL] Apache Cassandra (Apache repo)";;
    couchdb) echo "[NoSQL] Apache CouchDB";;
    neo4j) echo "[NoSQL] Neo4j graph database (Neo4j repo)";;
    # ── Vector ──
    qdrant) echo "[Vector] Qdrant (container)";;
    chroma) echo "[Vector] Chroma (pipx)";;
    milvus) echo "[Vector] Milvus standalone (container)";;
    weaviate) echo "[Vector] Weaviate (container)";;
    # ── Object storage ──
    minio) echo "[Storage] MinIO server (Homebrew; archived upstream)";;
    minio-client) echo "[Storage] MinIO client mcli (brew: conflicts with mc)";;
    seaweedfs) echo "[Storage] SeaweedFS S3 server (container)";;
    rclone) echo "[Storage] rclone - cloud storage sync";;
    s3cmd) echo "[Storage] s3cmd - S3 command line";;
    # ── DB admin ──
    dbeaver-ce) echo "[DBA] DBeaver Community";;
    pgadmin4) echo "[DBA] pgAdmin 4";;
    mongodb-compass) echo "[DBA] MongoDB Compass";;
    sqlitebrowser) echo "[DBA] DB Browser for SQLite";;
    beekeeper-studio) echo "[DBA] Beekeeper Studio";;
    pgcli) echo "[DBA] pgcli - PostgreSQL CLI";;
    mycli) echo "[DBA] mycli - MySQL CLI";;
    litecli) echo "[DBA] litecli - SQLite CLI";;
    usql) echo "[DBA] usql - universal SQL CLI";;
    # ── System admin ──
    cockpit) echo "[Admin] Cockpit web console (127.0.0.1:9090)";;
    btop) echo "[Admin] btop - resource monitor";;
    glances) echo "[Admin] Glances - system monitor";;
    lnav) echo "[Admin] lnav - log navigator";;
    # ── Web ──
    nginx) echo "[Web] nginx (127.0.0.1)";;
    apache2) echo "[Web] Apache httpd (127.0.0.1)";;
    caddy) echo "[Web] Caddy (127.0.0.1)";;
    haproxy) echo "[Web] HAProxy";;
    certbot) echo "[Web] certbot - Let's Encrypt client";;
    mkcert) echo "[Web] mkcert - local TLS certificates";;
    # ── Programming ──
    dotnet-sdk) echo "[Prog] .NET SDK";;
    uv) echo "[Prog] uv - Python package manager";;
    pipx) echo "[Prog] pipx - Python app installer";;
    pyenv) echo "[Prog] pyenv - Python versions";;
    nvm) echo "[Prog] nvm - Node versions";;
    sdkman) echo "[Prog] SDKMAN - JVM SDKs";;
    kotlin) echo "[Prog] Kotlin compiler";;
    cmake) echo "[Prog] CMake";;
    ninja) echo "[Prog] Ninja build";;
    clang) echo "[Prog] Clang/LLVM";;
    gdb) echo "[Prog] GDB debugger";;
    valgrind) echo "[Prog] Valgrind";;
    shellcheck) echo "[Prog] ShellCheck";;
    pre-commit) echo "[Prog] pre-commit";;
    httpie) echo "[Prog] HTTPie - HTTP client";;
    bruno) echo "[Prog] Bruno - API client";;
    # ── Claude Code plugins ──
    plugin-*) echo "[Claude] ${1#plugin-} plugin (claude-plugins-official)";;
    # ── Databases ──
    atlas) echo "[DB] MongoDB Atlas CLI (local deployments)";;
    mongodb) echo "[DB] MongoDB Community server + mongosh";;
    # ── Apps ──
    image-view) echo "[App] image-view - terminal image viewer";;
    isoforge) echo "[App] Isoforge - ISO burner";;
    nemo) echo "[App] Nemo - file manager";;
    rustdesk) echo "[App] RustDesk - remote desktop";;
    streamcontroller) echo "[App] StreamController - Stream Deck";;
    *) echo "$1";;
  esac
}

is_installed_tool() {
  case "$1" in
    bat) command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1;;
    curl) command -v curl >/dev/null 2>&1;;
    eza) command -v eza >/dev/null 2>&1;;
    fd) command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1;;
    fzf) command -v fzf >/dev/null 2>&1;;
    git) command -v git >/dev/null 2>&1;;
    git-lantern) [[ -d "$STATE_DIR/tools/git-lantern/.git" ]];;
    ansible) command -v ansible-pull >/dev/null 2>&1 || command -v ansible >/dev/null 2>&1;;
    adb) command -v adb >/dev/null 2>&1;;
    git-lfs) command -v git-lfs >/dev/null 2>&1;;
    jq) command -v jq >/dev/null 2>&1;;
    ripgrep) command -v rg >/dev/null 2>&1;;
    tree) command -v tree >/dev/null 2>&1;;
    wget) command -v wget >/dev/null 2>&1;;
    yq) command -v yq >/dev/null 2>&1;;
    zoxide) command -v zoxide >/dev/null 2>&1;;
    starship) command -v starship >/dev/null 2>&1;;
    tmux) command -v tmux >/dev/null 2>&1;;
    zsh) command -v zsh >/dev/null 2>&1;;
    duf) command -v duf >/dev/null 2>&1;;
    htop) command -v htop >/dev/null 2>&1;;
    ncdu) command -v ncdu >/dev/null 2>&1;;
    build-tools) command -v make >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1;;
    go) command -v go >/dev/null 2>&1;;
    java) command -v java >/dev/null 2>&1;;
    php) command -v php >/dev/null 2>&1;;
    composer) command -v composer >/dev/null 2>&1;;
    micro) command -v micro >/dev/null 2>&1;;
    neovim) command -v nvim >/dev/null 2>&1;;
    node) command -v node >/dev/null 2>&1 || command -v npm >/dev/null 2>&1;;
    rust) command -v rustc >/dev/null 2>&1 || command -v cargo >/dev/null 2>&1;;
    dialog) command -v dialog >/dev/null 2>&1;;
    docker) command -v docker >/dev/null 2>&1;;
    lazydocker) command -v lazydocker >/dev/null 2>&1;;
    lazygit) command -v lazygit >/dev/null 2>&1 || command -v lazygit-gm >/dev/null 2>&1;;
    nala) command -v nala >/dev/null 2>&1;;
    vscode) command -v code >/dev/null 2>&1;;
    isoforge) command -v isoforge >/dev/null 2>&1;;
    image-view) command -v image-view >/dev/null 2>&1;;
    lm-sensors) command -v sensors >/dev/null 2>&1;;
    usbutils) command -v lsusb >/dev/null 2>&1;;
    pciutils) command -v lspci >/dev/null 2>&1;;
    borgbackup) command -v borg >/dev/null 2>&1;;
    duplicity) command -v duplicity >/dev/null 2>&1;;
    fdupes) command -v fdupes >/dev/null 2>&1;;
    lz4) command -v lz4 >/dev/null 2>&1;;
    tar) command -v tar >/dev/null 2>&1;;
    unzip) command -v unzip >/dev/null 2>&1;;
    mc) command -v mc >/dev/null 2>&1;;
    nmap) command -v nmap >/dev/null 2>&1;;
    iperf3) command -v iperf3 >/dev/null 2>&1;;
    mtr) command -v mtr >/dev/null 2>&1;;
    net-tools) command -v ifconfig >/dev/null 2>&1;;
    tcpdump) command -v tcpdump >/dev/null 2>&1;;
    traceroute) command -v traceroute >/dev/null 2>&1;;
    bind-tools) command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1;;
    screen) command -v screen >/dev/null 2>&1;;
    cron) command -v crontab >/dev/null 2>&1;;
    ufw) command -v ufw >/dev/null 2>&1;;
    bfg) command -v bfg >/dev/null 2>&1;;
    gh) command -v gh >/dev/null 2>&1;;
    aider) command -v aider >/dev/null 2>&1;;
    ai-runner) [[ -d "$STATE_DIR/tools/ai-runner/.git" ]];;
    antigravity) command -v antigravity >/dev/null 2>&1;;
    claude-code) command -v claude >/dev/null 2>&1;;
    codex) command -v codex >/dev/null 2>&1;;
    copilot) command -v copilot >/dev/null 2>&1;;
    cursor) command -v cursor >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1;;
    gemini) command -v gemini >/dev/null 2>&1;;
    kiro) command -v kiro >/dev/null 2>&1 || command -v kiro-cli >/dev/null 2>&1;;
    ollama) command -v ollama >/dev/null 2>&1;;
    mongodb) command -v mongod >/dev/null 2>&1;;
    atlas) command -v atlas >/dev/null 2>&1;;
    tldr) command -v tldr >/dev/null 2>&1;;
    bandwhich) command -v bandwhich >/dev/null 2>&1;;
    k9s) command -v k9s >/dev/null 2>&1;;
    podman) command -v podman >/dev/null 2>&1;;
    tokei) command -v tokei >/dev/null 2>&1;;
    glow) command -v glow >/dev/null 2>&1;;
    delta) command -v delta >/dev/null 2>&1;;
    meld) command -v meld >/dev/null 2>&1;;
    ruby) command -v ruby >/dev/null 2>&1;;
    flatpak) command -v flatpak >/dev/null 2>&1;;
    wine) command -v wine >/dev/null 2>&1;;
    tor) command -v tor >/dev/null 2>&1;;
    ntfs) command -v ntfs-3g >/dev/null 2>&1 || command -v mount.ntfs-3g >/dev/null 2>&1;;
    streamcontroller) command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -q "com.core447.StreamController";;
    gimp) command -v gimp >/dev/null 2>&1;;
    nemo) command -v nemo >/dev/null 2>&1;;
    rustdesk) command -v rustdesk >/dev/null 2>&1 || { command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -q "com.rustdesk.RustDesk"; };;
    *) is_package_tool "$1" && package_tool_installed "$1";;
  esac
}

# ───────────────────────────────────────────────────────────────────────────────
# Tool catalog
# ───────────────────────────────────────────────────────────────────────────────
# Single source of truth: the interactive checklist, --all, and --tools
# validation all read this array. Order defines the checklist order.
managed_source_checkout() {
  # Two locals: bash expands every word of one `local` before assigning any,
  # so dest would have been "$STATE_DIR/tools/" with an empty name.
  local name="$1" url="$2"
  local dest="$STATE_DIR/tools/$name"
  mkdir -p "$STATE_DIR/tools"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only
  elif [[ -e "$dest" ]]; then
    log_warn "$dest exists but is not a managed checkout."
    return 1
  else
    git clone "$url" "$dest"
  fi
}

install_git_lantern() {
  command -v git >/dev/null 2>&1 || install_git "$1" || return 1
  managed_source_checkout git-lantern https://github.com/nikolareljin/git-lantern.git
}

install_ai_runner() {
  command -v git >/dev/null 2>&1 || install_git "$1" || return 1
  managed_source_checkout ai-runner https://github.com/nikolareljin/ai-runner.git
}

# Remove a checkout created by managed_source_checkout. Refuses anything that
# is not a git checkout, so a user's own directory there is never deleted.
uninstall_source_checkout() {
  local name="$1"
  local dest="$STATE_DIR/tools/$name"
  if [[ ! -d "$dest/.git" ]]; then
    log_warn "$dest is not a managed checkout; leaving it alone."
    return 1
  fi
  rm -rf -- "$dest"
}

# Selected in the checklist by default, and part of --all.
DEFAULT_SELECTED_TOOLS=(git-lantern ai-runner)

is_default_selected_tool() {
  local needle="$1" tool
  for tool in "${DEFAULT_SELECTED_TOOLS[@]}"; do
    [[ "$tool" == "$needle" ]] && return 0
  done
  return 1
}

# Categories: "id|label|tools". Single source of truth: the category menu,
# the checklists, --category, --all, --tools validation and --list-catalog all
# read it, and TOOL_CATALOG is derived from it. Order defines display order.
TOOL_CATEGORIES=(
  "shell|Shell & CLI|bat eza fd fzf glow jq ripgrep tldr tree yq zoxide zsh"
  "editors|Editors & Terminal|mc meld micro neovim screen tmux"
  "system|System & Monitoring|bandwhich cron duf htop lm-sensors ncdu pciutils usbutils"
  "network|Networking|bind-tools curl iperf3 mtr net-tools nmap tcpdump tor traceroute ufw wget"
  "backup|Backup & Storage|borgbackup duplicity fdupes lz4 tar unzip"
  "dev|Development|bfg build-tools composer delta gh git git-lantern git-lfs lazygit tokei"
  "ai|AI tools|aider ai-runner claude-code codex copilot gemini ollama"
  "ides|IDEs|antigravity cursor intellij-idea-community kiro pycharm-community vscode zed"
  "lang|Languages & Runtimes|go java node php ruby rust"
  "devops|DevOps & Containers|ansible docker k9s lazydocker podman"
  "media|Media|audacity ffmpeg handbrake kdenlive mpv obs-studio vlc"
  "graphics|Graphics|blender darktable gimp inkscape krita"
  "util|Utilities|adb dialog flatpak nala ntfs wine"
  "db-sql|Relational databases|mariadb mysql oracle-free pgvector postgresql sqlite"
  "db-nosql|NoSQL & graph databases|atlas cassandra couchdb mongodb neo4j redis valkey"
  "db-vector|Vector databases|chroma milvus qdrant weaviate"
  "storage|Object storage|minio minio-client rclone s3cmd seaweedfs"
  "db-admin|Database admin|beekeeper-studio dbeaver-ce litecli mongodb-compass mycli pgadmin4 pgcli sqlitebrowser usql"
  "sysadmin|System admin|btop cockpit glances lnav"
  "web|Web services|apache2 caddy certbot haproxy mkcert nginx"
  "prog|Programming tools|bruno clang cmake dotnet-sdk gdb httpie kotlin ninja nvm pipx pre-commit pyenv sdkman shellcheck uv valgrind"
  "claude-plugins|Claude Code plugins|plugin-claude-md-management plugin-code-review plugin-code-simplifier plugin-commit-commands plugin-feature-dev plugin-frontend-design plugin-hookify plugin-pr-review-toolkit plugin-security-guidance plugin-skill-creator"
  "apps|Apps|image-view isoforge nemo rustdesk streamcontroller"
)

# Print field $2 (1=id, 2=label, 3=tools) of category $1; return 1 if unknown.
category_field() {
  local id="$1" field="$2" entry
  for entry in "${TOOL_CATEGORIES[@]}"; do
    if [[ "${entry%%|*}" == "$id" ]]; then
      cut -d'|' -f"$field" <<< "$entry"
      return 0
    fi
  done
  return 1
}

TOOL_CATALOG=()
for _category in "${TOOL_CATEGORIES[@]}"; do
  read -r -a _category_tools <<< "${_category##*|}"
  TOOL_CATALOG+=("${_category_tools[@]}")
done
unset _category _category_tools

# Tools whose installers fetch and execute upstream scripts. They are held out
# of --all unless DISTRODECK_ALL_INCLUDE_OPT_IN_TOOLS=true, but an explicit
# --tools request counts as consent and installs them.
# Also held out: every IDE, database, server, container, GUI admin tool and
# Claude plugin, which only install when chosen.
OPT_IN_TOOLS=(aider antigravity atlas claude-code codex copilot cursor gemini
  intellij-idea-community kiro mongodb ollama pycharm-community vscode zed
  mariadb mysql oracle-free pgvector postgresql sqlite
  cassandra couchdb neo4j redis valkey
  chroma milvus qdrant weaviate
  minio seaweedfs
  beekeeper-studio dbeaver-ce mongodb-compass pgadmin4 sqlitebrowser
  cockpit apache2 caddy haproxy nginx
  bruno dotnet-sdk sdkman
  plugin-claude-md-management plugin-code-review plugin-code-simplifier plugin-commit-commands plugin-feature-dev plugin-frontend-design plugin-hookify plugin-pr-review-toolkit plugin-security-guidance plugin-skill-creator)

# Return 0 when $1 is a known catalog tool.
is_catalog_tool() {
  local needle="$1" tool
  for tool in "${TOOL_CATALOG[@]}"; do
    [[ "$tool" == "$needle" ]] && return 0
  done
  return 1
}

# Return 0 when $1 requires opt-in for --all runs.
is_opt_in_tool() {
  local needle="$1" tool
  for tool in "${OPT_IN_TOOLS[@]}"; do
    [[ "$tool" == "$needle" ]] && return 0
  done
  return 1
}

# Print the default --all selection: the whole catalog minus opt-in tools,
# and on manager $1 (when given) minus tools that manager cannot install.
default_all_selection() {
  local mgr="${1:-}" tool out=()
  for tool in "${TOOL_CATALOG[@]}"; do
    is_opt_in_tool "$tool" && continue
    [[ -n "$mgr" ]] && ! tool_supported_on "$tool" "$mgr" && continue
    out+=("$tool")
  done
  printf '%s\n' "${out[*]}"
}

# Print the tools of category $1 to show for manager $2, space separated.
# On macOS Linux-only tools are hidden; on Linux every tool is shown and one
# without a package for this manager fails with its own message when picked.
category_tools_for() {
  local tool out=() all_tools
  read -r -a all_tools <<< "$(category_field "$1" 3)"
  for tool in "${all_tools[@]}"; do
    [[ "$2" == "brew" ]] && ! tool_supported_on "$tool" "$2" && continue
    out+=("$tool")
  done
  printf '%s\n' "${out[*]}"
}

usage() {
  cat <<'USAGE'
Usage: install-tools-tui.sh [OPTIONS]

Options:
  --all                 Install every tool without showing the checklist.
                        Opt-in tools are skipped unless
                        DISTRODECK_ALL_INCLUDE_OPT_IN_TOOLS=true.
  --tools LIST          Install only LIST (comma or space separated) without
                        showing the checklist. Repeatable.
  --tools-file PATH     Install only the tools listed in PATH, one per line.
                        Blank lines and lines starting with # are ignored.
                        Use - to read the list from stdin. Repeatable.
  --reconcile           In --tools mode, also uninstall previously tracked
                        tools that are not in the requested set. Off by
                        default: unlisted tools are left alone.
  --java-version N      JDK major for the java tool: 17, 21 (default) or 25.
                        DISTRODECK_JAVA_VERSION sets the same default; an
                        invalid flag exits 2, an invalid variable fails
                        only the java tool.
  --category IDS        Install the default-on tools of these categories
                        (comma separated), one category block at a time.
                        Opt-in tools are never included; name them with
                        --tools. Repeatable.
  --purge               When uninstalling a container tool, also remove its
                        data volume (kept by default).
  --list-tools          Print the tool catalog, one per line, and exit.
  --list-categories     Print "id<TAB>label" per category and exit.
  --list-catalog --format tsv
                        Print one line per tool and exit:
                        category_id, category_label, tool, label,
                        opt_in (0|1), installed (0|1), tab separated.
  -h, --help            Show this help and exit.

Exit codes:
  0  success
  2  invalid usage (unknown option, unknown tool, unreadable tools file)
USAGE
}

# Append comma/whitespace separated tools from $1 into the named array ($2).
# Usage: collect_tools "bat,eza fd" requested
collect_tools() {
  local raw="$1"
  local -n _dest="$2"
  local item
  raw="${raw//,/ }"
  for item in $raw; do
    [[ -n "$item" ]] && _dest+=("$item")
  done
}

# Append tools listed in file $1 (one per line, # comments) into array ($2).
# A path of "-" reads from stdin.
collect_tools_file() {
  local path="$1"
  local -n _dest2="$2"
  local line
  if [[ "$path" != "-" && ! -r "$path" ]]; then
    log_error "Cannot read tools file: ${path}"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//$'\t'/ }"
    collect_tools "$line" _dest2
  done < <(if [[ "$path" == "-" ]]; then cat; else cat "$path"; fi)
}

# Install one catalog tool. Spec-table tools go through their kind; on macOS
# every other tool uses its Homebrew name unless its own installer works there.
install_tool() {
  local choice="$1" mgr="$2" brew_name
  if is_package_tool "$choice"; then
    install_package_tool "$choice" "$mgr"
    return
  fi
  if [[ "$mgr" == "brew" ]]; then
    brew_name="$(legacy_brew_name "$choice")"
    case "$brew_name" in
      "") log_warn "$choice is Linux-only; it is not offered on macOS."; return 1;;
      "=") ;;
      *) install_pkg brew "$brew_name"; return;;
    esac
  fi
    case "$choice" in
      ripgrep) install_ripgrep "$mgr";;
      fd) install_fd "$mgr";;
      bat) install_bat "$mgr";;
      eza) install_eza "$mgr";;
      fzf) install_fzf "$mgr";;
      zoxide) install_zoxide "$mgr";;
      yq) install_yq "$mgr";;
      curl) install_curl "$mgr";;
      wget) install_wget "$mgr";;
      git) install_git "$mgr";;
      git-lantern) install_git_lantern "$mgr";;
      ansible) install_ansible "$mgr";;
      adb) install_adb "$mgr";;
      git-lfs) install_git_lfs "$mgr";;
      zsh) install_zsh "$mgr";;
      starship) install_starship "$mgr";;
      tmux) install_tmux "$mgr";;
      htop) install_htop "$mgr";;
      ncdu) install_ncdu "$mgr";;
      duf) install_duf "$mgr";;
      tree) install_tree "$mgr";;
      bfg) install_bfg "$mgr";;
      gh) install_gh "$mgr";;
      aider) install_aider "$mgr";;
      ai-runner) install_ai_runner "$mgr";;
      antigravity) install_antigravity "$mgr";;
      claude-code) install_claude_code "$mgr";;
      codex) install_codex "$mgr";;
      copilot) install_copilot "$mgr";;
      cursor) install_cursor "$mgr";;
      gemini) install_gemini "$mgr";;
      kiro) install_kiro "$mgr";;
      ollama) install_ollama "$mgr";;
      mongodb) install_mongodb "$mgr";;
      atlas) install_atlas "$mgr";;
      tldr) install_tldr "$mgr";;
      bandwhich) install_bandwhich "$mgr";;
      k9s) install_k9s "$mgr";;
      podman) install_podman "$mgr";;
      tokei) install_tokei "$mgr";;
      glow) install_glow "$mgr";;
      delta) install_delta "$mgr";;
      meld) install_meld "$mgr";;
      build-tools) install_build_tools "$mgr";;
      neovim) install_neovim "$mgr";;
      micro) install_micro "$mgr";;
      docker) install_docker "$mgr";;
      nala) install_nala "$mgr";;
      dialog) install_dialog_pkg "$mgr";;
      jq) install_jq "$mgr";;
      node) install_node "$mgr";;
      lazygit) install_lazygit "$mgr";;
      lazydocker) install_lazydocker "$mgr";;
      java) install_java "$mgr";;
      php) install_php "$mgr";;
      composer) install_composer "$mgr";;
      rust) install_rust "$mgr";;
      go) install_go "$mgr";;
      vscode) install_vscode "$mgr";;
      isoforge) install_isoforge "$mgr";;
      image-view) install_image_view "$mgr";;
      lm-sensors) install_pkg_simple "$mgr" lm-sensors;;
      usbutils) install_pkg_simple "$mgr" usbutils;;
      pciutils) install_pkg_simple "$mgr" pciutils;;
      borgbackup) install_pkg_simple "$mgr" borgbackup;;
      duplicity) install_pkg_simple "$mgr" duplicity;;
      fdupes) install_pkg_simple "$mgr" fdupes;;
      lz4) install_pkg_simple "$mgr" lz4;;
      tar) install_pkg_simple "$mgr" tar;;
      unzip) install_pkg_simple "$mgr" unzip;;
      mc) install_pkg_simple "$mgr" mc;;
      nmap) install_pkg_simple "$mgr" nmap;;
      iperf3) install_pkg_simple "$mgr" iperf3;;
      mtr) install_pkg_simple "$mgr" mtr;;
      net-tools) install_pkg_simple "$mgr" net-tools;;
      tcpdump) install_pkg_simple "$mgr" tcpdump;;
      traceroute) install_pkg_simple "$mgr" traceroute;;
      bind-tools)
        case "$mgr" in
          apt) install_pkg_simple "$mgr" dnsutils;;
          dnf|pacman|zypper) install_pkg_simple "$mgr" bind-tools;;
          *) log_warn "bind-tools install not supported for this distro.";;
        esac
        ;;
      screen) install_pkg_simple "$mgr" screen;;
      cron)
        case "$mgr" in
          apt) install_pkg_simple "$mgr" cron;;
          dnf) install_pkg_simple "$mgr" cronie;;
          pacman) install_pkg_simple "$mgr" cronie;;
          zypper) install_pkg_simple "$mgr" cron;;
          *) log_warn "cron install not supported for this distro.";;
        esac
        ;;
      ufw) install_pkg_simple "$mgr" ufw;;
      ruby) install_ruby "$mgr";;
      flatpak) install_flatpak "$mgr";;
      wine) install_wine "$mgr";;
      tor) install_tor "$mgr";;
      ntfs) install_ntfs "$mgr";;
      streamcontroller) install_streamcontroller "$mgr";;
      gimp) install_gimp "$mgr";;
      nemo) install_pkg_simple "$mgr" nemo;;
      rustdesk) install_rustdesk "$mgr";;
      *) log_error "No installer is wired for $choice."; false;;
    esac
}

uninstall_tool() {
  local tool="$1" mgr="$2" brew_name
  if is_package_tool "$tool"; then
    uninstall_package_tool "$tool" "$mgr"
    return
  fi
  if [[ "$mgr" == "brew" ]]; then
    brew_name="$(legacy_brew_name "$tool")"
    case "$brew_name" in
      "") log_warn "$tool is Linux-only; nothing to remove on macOS."; return 1;;
      "=") ;;
      *) uninstall_pkg brew "$brew_name"; return;;
    esac
  fi
      case "$tool" in
        ripgrep) uninstall_pkg_simple "$mgr" ripgrep;;
        fd) uninstall_fd "$mgr";;
        bat) uninstall_pkg_simple "$mgr" bat;;
        eza) uninstall_pkg_simple "$mgr" eza;;
        fzf) uninstall_pkg_simple "$mgr" fzf;;
        zoxide) uninstall_pkg_simple "$mgr" zoxide;;
        yq) uninstall_pkg_simple "$mgr" yq;;
        curl) uninstall_pkg_simple "$mgr" curl;;
        wget) uninstall_pkg_simple "$mgr" wget;;
        git) uninstall_pkg_simple "$mgr" git;;
        ansible) uninstall_pkg_simple "$mgr" ansible;;
        adb) uninstall_adb "$mgr";;
        git-lfs) uninstall_pkg_simple "$mgr" git-lfs;;
        zsh) uninstall_pkg_simple "$mgr" zsh;;
        starship) uninstall_pkg_simple "$mgr" starship;;
        tmux) uninstall_pkg_simple "$mgr" tmux;;
        htop) uninstall_pkg_simple "$mgr" htop;;
        ncdu) uninstall_pkg_simple "$mgr" ncdu;;
        duf) uninstall_pkg_simple "$mgr" duf;;
        tree) uninstall_pkg_simple "$mgr" tree;;
        bfg) uninstall_bfg "$mgr";;
        gh) uninstall_gh "$mgr";;
        aider) uninstall_aider "$mgr";;
        ai-runner) uninstall_source_checkout ai-runner;;
        git-lantern) uninstall_source_checkout git-lantern;;
        antigravity) uninstall_antigravity "$mgr";;
        claude-code) uninstall_claude_code "$mgr";;
        codex) uninstall_codex "$mgr";;
        copilot) uninstall_copilot "$mgr";;
        cursor) uninstall_cursor "$mgr";;
        gemini) uninstall_gemini "$mgr";;
        kiro) uninstall_kiro "$mgr";;
        ollama) uninstall_ollama "$mgr";;
        mongodb) uninstall_mongodb "$mgr";;
        atlas) uninstall_atlas "$mgr";;
        tldr) uninstall_tldr "$mgr";;
        bandwhich) uninstall_bandwhich "$mgr";;
        k9s) uninstall_k9s "$mgr";;
        podman) uninstall_podman "$mgr";;
        tokei) uninstall_tokei "$mgr";;
        glow) uninstall_glow "$mgr";;
        delta) uninstall_delta "$mgr";;
        meld) uninstall_meld "$mgr";;
        build-tools) uninstall_build_tools "$mgr";;
        neovim) uninstall_pkg_simple "$mgr" neovim;;
        micro) uninstall_pkg_simple "$mgr" micro;;
        docker) uninstall_docker "$mgr";;
        nala) uninstall_pkg_simple "$mgr" nala;;
        dialog) uninstall_pkg_simple "$mgr" dialog;;
        jq) uninstall_pkg_simple "$mgr" jq;;
        node) uninstall_node "$mgr";;
        lazygit) uninstall_lazygit "$mgr";;
        lazydocker) uninstall_lazydocker "$mgr";;
        java) uninstall_java "$mgr";;
        php) uninstall_pkg_simple "$mgr" php;;
        composer) uninstall_pkg_simple "$mgr" composer;;
        rust) uninstall_rust "$mgr";;
        go) uninstall_go "$mgr";;
        vscode) uninstall_vscode "$mgr";;
        isoforge) uninstall_isoforge "$mgr";;
        image-view) uninstall_image_view "$mgr";;
        lm-sensors) uninstall_pkg_simple "$mgr" lm-sensors;;
        usbutils) uninstall_pkg_simple "$mgr" usbutils;;
        pciutils) uninstall_pkg_simple "$mgr" pciutils;;
        borgbackup) uninstall_pkg_simple "$mgr" borgbackup;;
        duplicity) uninstall_pkg_simple "$mgr" duplicity;;
        fdupes) uninstall_pkg_simple "$mgr" fdupes;;
        lz4) uninstall_pkg_simple "$mgr" lz4;;
        tar) uninstall_pkg_simple "$mgr" tar;;
        unzip) uninstall_pkg_simple "$mgr" unzip;;
        mc) uninstall_pkg_simple "$mgr" mc;;
        nmap) uninstall_pkg_simple "$mgr" nmap;;
        iperf3) uninstall_pkg_simple "$mgr" iperf3;;
        mtr) uninstall_pkg_simple "$mgr" mtr;;
        net-tools) uninstall_pkg_simple "$mgr" net-tools;;
        tcpdump) uninstall_pkg_simple "$mgr" tcpdump;;
        traceroute) uninstall_pkg_simple "$mgr" traceroute;;
        bind-tools) uninstall_bind_tools "$mgr";;
        screen) uninstall_pkg_simple "$mgr" screen;;
        cron) uninstall_cron "$mgr";;
        ufw) uninstall_pkg_simple "$mgr" ufw;;
        ruby) uninstall_ruby "$mgr";;
        flatpak) uninstall_flatpak "$mgr";;
        wine) uninstall_wine "$mgr";;
        tor) uninstall_tor "$mgr";;
        ntfs) uninstall_ntfs "$mgr";;
        streamcontroller) uninstall_streamcontroller "$mgr";;
        gimp) uninstall_gimp "$mgr";;
        nemo) uninstall_pkg_simple "$mgr" nemo;;
        rustdesk) uninstall_rustdesk "$mgr";;
        *) log_error "No uninstaller is wired for $tool."; false;;
      esac
}

# Install the selected tools in scope and offer to remove unchecked tracked
# ones. Reads main's locals (bash scoping is dynamic): selected, tools,
# installed, tracked, requested, reconcile, all, mgr, tui. Returns 1 on any
# failure.
process_selection() {
  # Build set of selected tools, keeping the order they were given in, so a
  # block installs in catalog order rather than hash order.
  declare -A selected_set=()
  local ordered=() choice
  if [[ -n "$selected" ]]; then
    local choices_arr=()
    IFS=' ' read -r -a choices_arr <<< "$selected"
    for choice in "${choices_arr[@]}"; do
      choice="${choice//\"/}"
      [[ -z "$choice" || -n "${selected_set[$choice]:-}" ]] && continue
      selected_set["$choice"]="true"
      ordered+=("$choice")
    done
  fi

  # Find tools to uninstall: tracked + currently installed + NOT selected.
  # In --tools mode this is skipped unless --reconcile was passed: removing
  # software the caller never mentioned is not a safe default for integrators.
  local to_uninstall=()
  if [[ ${#requested[@]} -eq 0 ]] || $reconcile; then
    for tool in "${tools[@]}"; do
      if [[ "${tracked[$tool]:-}" == "true" ]] && \
         [[ "${installed[$tool]:-}" == "true" ]] && \
         [[ "${selected_set[$tool]:-}" != "true" ]]; then
        to_uninstall+=("$tool")
      fi
    done
  fi

  # Prompt user about uninstalling unchecked tools
  local do_uninstall=false
  if [[ ${#to_uninstall[@]} -gt 0 ]] && [[ ${#requested[@]} -gt 0 ]] && $reconcile; then
    log_info "Reconciling: uninstalling ${#to_uninstall[@]} tracked tool(s) not in the requested set."
    do_uninstall=true
  elif [[ ${#to_uninstall[@]} -gt 0 ]] && $tui; then
    local uninstall_list=""
    for tool in "${to_uninstall[@]}"; do
      uninstall_list+="  - $(tool_desc "$tool")\n"
    done
    if dialog --stdout --title "Uninstall Tools" \
        --yesno "The following tools were unchecked and are currently installed:\n\n${uninstall_list}\nDo you want to uninstall these tools?" \
        "$DIALOG_HEIGHT" "$DIALOG_WIDTH"; then
      do_uninstall=true
    fi
    # Clear after uninstall dialog closes
    clear
  fi

  # If no selections and no uninstalls, there is nothing to do.
  if [[ -z "$selected" ]] && [[ "$do_uninstall" != "true" ]]; then
    log_warn "No selections made."
    return 0
  fi

  # Track installation/uninstallation results
  local failed_installs=()
  local failed_uninstalls=()
  local successful_installs=()
  local successful_uninstalls=()
  local already_installed=()

  # Install selected tools
  for choice in "${ordered[@]}"; do
    if [[ "${installed[$choice]:-}" == "true" ]]; then
      log_info "Already installed: $choice"
      # Track it if not already tracked
      add_tracked_tool "$choice"
      already_installed+=("$choice")
      continue
    fi
    log_info "Installing: $choice"
    # Run installation in subshell to catch errors without exiting
    if ( install_tool "$choice" "$mgr" ); then
      # Installation command succeeded, verify tool is now installed. The
      # install ran in a subshell, so drop the per-run detection caches first.
      CLAUDE_PLUGIN_LIST_CACHE=""; PIPX_LIST_CACHE=""; CONTAINER_CLI_CACHE=""
      if is_installed_tool "$choice"; then
        add_tracked_tool "$choice"
        successful_installs+=("$choice")
        log_info "Successfully installed: $choice"
      else
        log_warn "Installation command completed but $choice not detected as installed."
        failed_installs+=("$choice")
      fi
    else
      log_error "Failed to install: $choice"
      failed_installs+=("$choice")
    fi
  done

  # Uninstall unchecked tools if user agreed
  if [[ "$do_uninstall" == "true" ]]; then
    for tool in "${to_uninstall[@]}"; do
      log_info "Uninstalling: $tool"
      # Run uninstallation in subshell to catch errors without exiting
      if ( uninstall_tool "$tool" "$mgr" ); then
        # Uninstallation succeeded
        remove_tracked_tool "$tool"
        successful_uninstalls+=("$tool")
        log_info "Successfully uninstalled: $tool"
      else
        log_error "Failed to uninstall: $tool"
        failed_uninstalls+=("$tool")
      fi
    done
  fi

  # Build summary message for dialog
  local summary=""
  local title="Installation Complete"
  local has_failures=false

  # Successfully installed
  if [[ ${#successful_installs[@]} -gt 0 ]]; then
    summary+="INSTALLED SUCCESSFULLY:\n"
    for tool in "${successful_installs[@]}"; do
      summary+="  ✓ $(tool_desc "$tool")\n"
    done
    summary+="\n"
  fi

  # Successfully uninstalled
  if [[ ${#successful_uninstalls[@]} -gt 0 ]]; then
    summary+="UNINSTALLED SUCCESSFULLY:\n"
    for tool in "${successful_uninstalls[@]}"; do
      summary+="  ✓ $(tool_desc "$tool")\n"
    done
    summary+="\n"
  fi

  # Already installed (skipped)
  if [[ ${#already_installed[@]} -gt 0 ]]; then
    summary+="ALREADY INSTALLED (skipped):\n"
    for tool in "${already_installed[@]}"; do
      summary+="  • $(tool_desc "$tool")\n"
    done
    summary+="\n"
  fi

  # Failed to install
  if [[ ${#failed_installs[@]} -gt 0 ]]; then
    has_failures=true
    summary+="FAILED TO INSTALL:\n"
    for tool in "${failed_installs[@]}"; do
      summary+="  ✗ $(tool_desc "$tool")\n"
    done
    summary+="\n"
  fi

  # Failed to uninstall
  if [[ ${#failed_uninstalls[@]} -gt 0 ]]; then
    has_failures=true
    summary+="FAILED TO UNINSTALL:\n"
    for tool in "${failed_uninstalls[@]}"; do
      summary+="  ✗ $(tool_desc "$tool")\n"
    done
    summary+="\n"
  fi

  # Set appropriate title based on results
  if [[ "$has_failures" == "true" ]]; then
    title="Installation Complete (with warnings)"
  fi

  # No changes made
  if [[ ${#successful_installs[@]} -eq 0 ]] && [[ ${#successful_uninstalls[@]} -eq 0 ]] && \
     [[ ${#failed_installs[@]} -eq 0 ]] && [[ ${#failed_uninstalls[@]} -eq 0 ]]; then
    summary="All selected tools are already installed.\nNo changes were made."
    title="No Changes"
  fi

  # Show results in dialog (TUI mode) or log (non-TUI mode)
  # Only the checklist run opened dialog (and set DIALOG_HEIGHT); --tools and
  # --all print the summary, which also keeps them usable without a terminal.
  if $tui; then
    dialog --stdout --title "$title" --msgbox "$summary" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" || true
    clear
  else
    # Fallback to console output
    log_info "===== $title ====="
    echo -e "$summary"
  fi

  # Return non-zero if there were failures (but don't exit early)
  if [[ ${#failed_installs[@]} -gt 0 ]] || [[ ${#failed_uninstalls[@]} -gt 0 ]]; then
    return 1
  fi
}

# Print the catalog for scripts: one tab-separated line per tool,
#   category_id  category_label  tool  label  opt_in(0|1)  installed(0|1)
# No colour, no dialog, no root. The column order is a contract (NikOS parses
# it; tests/test_install_tools_args.sh pins it): only ever append columns.
print_catalog_tsv() {
  local entry id label tools tool desc opt inst
  for entry in "${TOOL_CATEGORIES[@]}"; do
    id="${entry%%|*}"
    label="$(cut -d'|' -f2 <<< "$entry")"
    read -r -a tools <<< "${entry##*|}"
    for tool in "${tools[@]}"; do
      desc="$(tool_desc "$tool")"
      desc="${desc#\[*\] }"
      desc="${desc//$'\t'/ }"
      opt=0; is_opt_in_tool "$tool" && opt=1
      inst=0; is_installed_tool "$tool" >/dev/null 2>&1 && inst=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$tool" "$desc" "$opt" "$inst"
    done
  done
}

# Run the checklist for one category; returns process_selection's status.
run_category_block() {
  local category="$1" label tool
  # Detection caches are per run; a block may have just changed what is installed.
  CLAUDE_PLUGIN_LIST_CACHE=""; PIPX_LIST_CACHE=""; CONTAINER_CLI_CACHE=""
  label="$(category_field "$category" 2)"
  read -r -a tools <<< "$(category_tools_for "$category" "$mgr")"
  for tool in "${tools[@]}"; do
    if is_installed_tool "$tool"; then installed["$tool"]="true"; else installed["$tool"]="false"; fi
  done
  local items=() desc status
  for tool in "${tools[@]}"; do
    desc="$(tool_desc "$tool")"
    status="off"
    if [[ "${installed[$tool]}" == "true" ]]; then
      desc+=" (installed)"
      status="on"
    elif is_default_selected_tool "$tool" && [[ ! -f "$INSTALLED_TOOLS_FILE" ]]; then
      # Preselected only before distrodeck has tracked anything, so a tool
      # the user unchecked and removed is not offered back every run.
      status="on"
    fi
    is_opt_in_tool "$tool" && desc+=" [opt-in]"
    items+=("$tool" "$desc" "$status")
  done
  local list_height=$((DIALOG_HEIGHT - 8))
  (( list_height < 10 )) && list_height=10
  if ! selected=$(dialog --stdout --title "$label" --scrollbar \
      --checklist "Checked tools are installed or kept; unchecking an installed tool offers to remove it:" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$list_height" "${items[@]}"); then
    clear
    return 0  # Cancel/Esc returns to the category menu without changes.
  fi
  clear
  process_selection
}

# Category menu: open one category, install that block, come back. Quit ends.
run_category_menu() {
  local status=0 choice entry id label total count tool menu_items cat_tools
  while true; do
    menu_items=()
    for entry in "${TOOL_CATEGORIES[@]}"; do
      id="${entry%%|*}"
      label="$(cut -d'|' -f2 <<< "$entry")"
      read -r -a cat_tools <<< "$(category_tools_for "$id" "$mgr")"
      total=${#cat_tools[@]}; count=0
      # Linux-only categories (and tools) are hidden on macOS, not listed as failures.
      [[ "$total" -eq 0 ]] && continue
      for tool in "${cat_tools[@]}"; do
        is_installed_tool "$tool" && count=$((count + 1))
      done
      menu_items+=("$id" "$label ($count/$total installed)")
    done
    local note="Pick a category. Each one is installed as its own block."
    [[ "$mgr" == "brew" ]] && note+=" Linux-only tools are hidden on macOS."
    choice=$(dialog --stdout --title "Distrodeck Installer" --cancel-label "Quit" \
      --menu "$note" \
      "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$((DIALOG_HEIGHT - 8))" "${menu_items[@]}") || break
    clear
    run_category_block "$choice" || status=1
  done
  clear
  return "$status"
}

main() {

  local selected=""
  local all=false
  local reconcile=false
  local java_flag=false
  local tui=false
  local list_catalog=false
  local format=""
  local categories=()
  local requested=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=true;;
      --tools)
        [[ $# -ge 2 ]] || { log_error "--tools requires a value."; usage; exit 2; }
        collect_tools "$2" requested
        shift
        ;;
      --tools=*) collect_tools "${1#*=}" requested;;
      --tools-file)
        [[ $# -ge 2 ]] || { log_error "--tools-file requires a path."; usage; exit 2; }
        collect_tools_file "$2" requested || exit 2
        shift
        ;;
      --tools-file=*) collect_tools_file "${1#*=}" requested || exit 2;;
      --reconcile) reconcile=true;;
      --purge) export DISTRODECK_PURGE=1;;
      --java-version)
        [[ $# -ge 2 ]] || { log_error "--java-version requires a value."; usage; exit 2; }
        JAVA_VERSION="$2"
        java_flag=true
        shift
        ;;
      --java-version=*) JAVA_VERSION="${1#*=}"; java_flag=true;;
      --list-tools)
        printf '%s\n' "${TOOL_CATALOG[@]}"
        exit 0
        ;;
      --list-categories)
        local entry
        for entry in "${TOOL_CATEGORIES[@]}"; do
          printf '%s\t%s\n' "${entry%%|*}" "$(cut -d'|' -f2 <<< "$entry")"
        done
        exit 0
        ;;
      --list-catalog) list_catalog=true;;
      --format)
        [[ $# -ge 2 ]] || { log_error "--format requires a value."; usage; exit 2; }
        format="$2"
        shift
        ;;
      --format=*) format="${1#*=}";;
      --category)
        [[ $# -ge 2 ]] || { log_error "--category requires a value."; usage; exit 2; }
        collect_tools "$2" categories
        shift
        ;;
      --category=*) collect_tools "${1#*=}" categories;;
      -h|--help) usage; exit 0;;
      *) log_error "Unknown option: $1"; usage; exit 2;;
    esac
    shift
  done

  if $list_catalog; then
    if [[ "$format" != "tsv" ]]; then
      log_error "--list-catalog needs --format tsv."
      exit 2
    fi
    print_catalog_tsv
    exit 0
  elif [[ -n "$format" ]]; then
    log_error "--format only applies to --list-catalog."
    exit 2
  fi

  # --category installs the default-on tools of each named category, one
  # block per category, in the order given. Opt-in tools need --tools.
  if [[ ${#categories[@]} -gt 0 ]]; then
    if $all || [[ ${#requested[@]} -gt 0 ]] || $reconcile; then
      log_error "--category cannot be combined with --all, --tools, --tools-file or --reconcile."
      exit 2
    fi
    local category bad_categories=()
    for category in "${categories[@]}"; do
      category_field "$category" 1 >/dev/null || bad_categories+=("$category")
    done
    if [[ ${#bad_categories[@]} -gt 0 ]]; then
      log_error "Unknown category: ${bad_categories[*]}"
      log_error "Run with --list-categories to see them."
      exit 2
    fi
  fi

  # A bad --java-version flag is a usage error and exits 2 whatever is selected.
  # A bad DISTRODECK_JAVA_VERSION only fails the java tool, in install_java,
  # so a stale environment does not block installing anything else.
  if $java_flag && ! is_supported_java_version "$JAVA_VERSION"; then
    log_error "Unsupported Java version '$JAVA_VERSION'; choose one of: $JAVA_SUPPORTED_VERSIONS."
    exit 2
  fi

  # Validate the requested set before touching the system, so a typo cannot
  # half-install a machine.
  if [[ ${#requested[@]} -gt 0 ]]; then
    if $all; then
      log_error "--all cannot be combined with --tools/--tools-file."
      exit 2
    fi
    local unknown=() tool
    for tool in "${requested[@]}"; do
      is_catalog_tool "$tool" || unknown+=("$tool")
    done
    if [[ ${#unknown[@]} -gt 0 ]]; then
      log_error "Unknown tool(s): ${unknown[*]}"
      log_error "Run with --list-tools to see the catalog."
      exit 2
    fi
  elif $reconcile; then
    log_error "--reconcile only applies to --tools/--tools-file runs."
    exit 2
  fi
  # Informational and validation-only modes above deliberately work without a
  # package manager. Detect one only once an install or TUI run is required.
  local mgr
  mgr="$(detect_pkg_mgr)"
  if [[ "$mgr" == "unknown" ]]; then
    log_error "No supported package manager found."
    exit 1
  fi


  # Load previously tracked tools (installed via distrodeck)
  declare -A tracked=()
  load_tracked_tools tracked

  declare -A installed=()
  local tools=()

  if [[ ${#categories[@]} -gt 0 ]]; then
    [[ -t 0 ]] || export DISTRODECK_NONINTERACTIVE=true
    local block_status=0 skipped
    for category in "${categories[@]}"; do
      read -r -a tools <<< "$(category_tools_for "$category" "$mgr")"
      if [[ ${#tools[@]} -eq 0 ]]; then
        log_warn "Category $category has no tools for ${mgr}; skipping it."
        continue
      fi
      selected=""; skipped=""
      local unsupported=""
      for tool in "${tools[@]}"; do
        if ! tool_supported_on "$tool" "$mgr"; then unsupported+=" $tool"; continue; fi
        if is_opt_in_tool "$tool"; then skipped+=" $tool"; else selected+=" $tool"; fi
        if is_installed_tool "$tool"; then installed["$tool"]="true"; else installed["$tool"]="false"; fi
      done
      selected="${selected# }"
      log_info "== Category: $(category_field "$category" 2) =="
      [[ -n "$skipped" ]] && log_info "Opt-in, install with --tools:${skipped}"
      [[ -n "$unsupported" ]] && log_info "No ${mgr} package, skipped:${unsupported}"
      if [[ -z "$selected" ]]; then
        log_warn "Category $category has only opt-in tools; name them with --tools."
        continue
      fi
      # A request, so this block never considers uninstalling anything.
      read -r -a requested <<< "$selected"
      process_selection || block_status=1
    done
    return "$block_status"
  fi

  if [[ ${#requested[@]} -eq 0 ]] && ! $all; then
    # Interactive: the category menu, one block at a time. Without a terminal
    # dialog cannot draw it, and a silent exit 0 would read as "done".
    # DISTRODECK_FORCE_TUI=1 exists for tests that stub dialog.
    if [[ "${DISTRODECK_FORCE_TUI:-}" != "1" ]] && ! { [[ -t 0 ]] && [[ -t 1 ]]; }; then
      log_error "The category menu needs a terminal. Use --category, --tools or --all instead."
      exit 2
    fi
    tui=true
    ensure_dialog
    dialog_init
    run_category_menu
    return
  fi

  tools=("${TOOL_CATALOG[@]}")
  for tool in "${tools[@]}"; do
    if is_installed_tool "$tool"; then
      installed["$tool"]="true"
    else
      installed["$tool"]="false"
    fi
  done
  if [[ ${#requested[@]} -gt 0 ]]; then
    selected="${requested[*]}"
    # Naming a tool explicitly is consent to install it, opt-in or not; but its
    # installer must not block on prompts when there is no terminal attached.
    if [[ ! -t 0 ]]; then
      export DISTRODECK_NONINTERACTIVE=true
    fi
  else
    # Derived from the catalog so a new tool is never silently missing here.
    selected="$(default_all_selection "$mgr")"
    include_opt_in_tools="${DISTRODECK_ALL_INCLUDE_OPT_IN_TOOLS:-${DISTRODECK_ALL_INCLUDE_REMOTE_SCRIPT_TOOLS:-false}}"
    if [[ "$include_opt_in_tools" == "true" && -t 0 ]]; then
      unset DISTRODECK_NONINTERACTIVE
      # Same filter as the default set: no Linux-only tools on macOS.
      for tool in "${OPT_IN_TOOLS[@]}"; do
        if tool_supported_on "$tool" "$mgr"; then selected+=" $tool"; fi
      done
    else
      export DISTRODECK_NONINTERACTIVE=true
      if [[ "$include_opt_in_tools" == "true" ]]; then
        log_warn "Skipping opt-in tools in --all mode because no interactive terminal is available."
      fi
    fi
  fi

  process_selection
}

# Allow tests to source this file and exercise individual helpers without
# running the installer.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
