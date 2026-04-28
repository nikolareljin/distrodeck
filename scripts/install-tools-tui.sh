#!/usr/bin/env bash
# SCRIPT: install-tools-tui.sh
# DESCRIPTION: TUI installer for common developer tools.
# USAGE: ./install-tools-tui.sh [--all]
# PARAMETERS: Optional flag --all installs all tools without interactive selection.
# EXAMPLE: ./install-tools-tui.sh --all
# ----------------------------------------------------
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
#   - lazygit: https://github.com/jesseduffield/lazygit/releases
#   - k9s:     https://github.com/derailed/k9s/releases
#   - glow:    https://github.com/charmbracelet/glow/releases
#   - delta:   https://github.com/dandavison/delta/releases
#   - bfg:     https://github.com/rtyley/bfg-repo-cleaner/releases
#
# Last updated: 2025-01-22
FALLBACK_VERSION_LAZYGIT="0.44.1"
FALLBACK_VERSION_K9S="v0.50.18"
FALLBACK_VERSION_GLOW="2.1.1"
FALLBACK_VERSION_DELTA="0.18.2"
FALLBACK_VERSION_BFG="1.15.0"

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
  if command -v apt-get >/dev/null 2>&1; then
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
          log_warn "Failed to install NodeSource apt repository key."
          return 1
        fi
        rm -f "$tmp_key"
        echo "deb [signed-by=$keyring] https://deb.nodesource.com/node_${node_major}.x nodistro main" | \
          sudo tee /etc/apt/sources.list.d/nodesource.list > /dev/null
        if ! sudo apt-get update; then
          log_warn "apt-get update reported errors after adding NodeSource; continuing with Node.js installation attempt."
        fi
        install_pkg "$mgr" nodejs || return 1
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return 0
        fi
        log_warn "NodeSource did not provide Node.js ${node_major}+."
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
        install_pkg "$mgr" nodejs || return 1
        if [[ "$(node_major_version)" -ge "$node_major" ]]; then
          return 0
        fi
        log_warn "NodeSource did not provide Node.js ${node_major}+."
        return 1
      else
        rm -f "$tmp_key"
        log_warn "Failed to download NodeSource GPG key."
        return 1
      fi
      ;;
    pacman) install_pkg "$mgr" nodejs npm;;
    zypper)
      if [[ "$node_major" -ge 22 ]]; then
        install_pkg "$mgr" nodejs22 npm22 || install_pkg "$mgr" nodejs npm
      else
        install_pkg "$mgr" nodejs20 npm20 || install_pkg "$mgr" nodejs npm
      fi
      ;;
    *) log_warn "Node install not supported for this distro.";;
  esac
}

install_node() {
  install_node_major_version "$1" 20
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

install_java() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" default-jdk;;
    dnf) install_pkg "$mgr" java-17-openjdk-devel;;
    pacman) install_pkg "$mgr" jdk-openjdk;;
    zypper) install_pkg "$mgr" java-17-openjdk;;
    *) log_warn "Java install not supported for this distro.";;
  esac
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
    repo_dir="$HOME/Projects/burn-iso"
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
  local answer
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) return 0;;
    *) log_warn "Skipped downloaded installer: $url"; return 1;;
  esac
}

run_downloaded_script() {
  local url="$1"
  local tmp_file
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
  bash "$tmp_file"
  local rc=$?
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
        sudo gpg --dearmor --yes -o /etc/apt/keyrings/antigravity-repo-key.gpg "$tmp_key"
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
}

uninstall_java() {
  local mgr="$1"
  case "$mgr" in
    apt) uninstall_pkg "$mgr" default-jdk;;
    dnf) uninstall_pkg "$mgr" java-17-openjdk-devel;;
    pacman) uninstall_pkg "$mgr" jdk-openjdk;;
    zypper) uninstall_pkg "$mgr" java-17-openjdk;;
    *) log_warn "Java uninstall not supported for this distro.";;
  esac
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
  rm -f "$HOME/.local/bin/cursor-agent" 2>/dev/null || true
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
    vscode) echo "[Editor] VS Code";;
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
    tokei) echo "[Dev] tokei - code statistics";;
    # ── AI tools ──
    aider) echo "[AI] aider - AI pair programming";;
    antigravity) echo "[AI] Antigravity - AI development environment";;
    claude-code) echo "[AI] Claude Code";;
    codex) echo "[AI] OpenAI Codex CLI";;
    copilot) echo "[AI] GitHub Copilot CLI";;
    cursor) echo "[AI] Cursor IDE / Agent";;
    gemini) echo "[AI] Gemini CLI";;
    kiro) echo "[AI] Kiro IDE / CLI";;
    ollama) echo "[AI] Ollama local models";;
    # ── Languages & Runtimes ──
    go) echo "[Lang] Go";;
    java) echo "[Lang] Java (JDK)";;
    node) echo "[Lang] Node.js 20 LTS";;
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
    # ── Apps ──
    gimp) echo "[App] GIMP - image editor";;
    image-view) echo "[App] image-view - terminal image viewer";;
    isoforge) echo "[App] Isoforge - ISO burner";;
    nemo) echo "[App] Nemo - file manager";;
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
    antigravity) command -v antigravity >/dev/null 2>&1;;
    claude-code) command -v claude >/dev/null 2>&1;;
    codex) command -v codex >/dev/null 2>&1;;
    copilot) command -v copilot >/dev/null 2>&1;;
    cursor) command -v cursor >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1;;
    gemini) command -v gemini >/dev/null 2>&1;;
    kiro) command -v kiro >/dev/null 2>&1 || command -v kiro-cli >/dev/null 2>&1;;
    ollama) command -v ollama >/dev/null 2>&1;;
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
    *) return 1;;
  esac
}

main() {
  local mgr
  mgr="$(detect_pkg_mgr)"
  if [[ "$mgr" == "unknown" ]]; then
    log_error "No supported package manager found."
    exit 1
  fi

  local selected=""
  local all=false

  if [[ "${1:-}" == "--all" ]]; then
    all=true
  fi

  # Load previously tracked tools (installed via distrodeck)
  declare -A tracked=()
  load_tracked_tools tracked

  declare -A installed=()
  local tools=(
    # ── Shell & CLI ──
    bat eza fd fzf glow jq ripgrep tldr tree yq zoxide zsh
    # ── Editors & Terminal ──
    mc meld micro neovim screen tmux vscode
    # ── System & Monitoring ──
    bandwhich cron duf htop lm-sensors ncdu pciutils usbutils
    # ── Networking ──
    bind-tools curl iperf3 mtr net-tools nmap tcpdump tor traceroute ufw wget
    # ── Backup & Storage ──
    borgbackup duplicity fdupes lz4 tar unzip
    # ── Development ──
    bfg build-tools composer delta gh git git-lfs lazygit tokei
    # ── AI tools ──
    aider antigravity claude-code codex copilot cursor gemini kiro ollama
    # ── Languages & Runtimes ──
    go java node php ruby rust
    # ── DevOps & Containers ──
    ansible docker k9s lazydocker podman
    # ── Utilities ──
    adb dialog flatpak nala ntfs wine
    # ── Apps ──
    gimp image-view isoforge nemo streamcontroller
  )

  for tool in "${tools[@]}"; do
    if is_installed_tool "$tool"; then
      installed["$tool"]="true"
    else
      installed["$tool"]="false"
    fi
  done
  if ! $all; then
    ensure_dialog
    dialog_init
    dialog --stdout --title "Distrodeck Installer" \
      --infobox "Checking installed tools..." "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    dialog --clear

    local items=()
    for tool in "${tools[@]}"; do
      local desc status
      desc="$(tool_desc "$tool")"
      status="off"
      if [[ "${installed[$tool]}" == "true" ]]; then
        desc+=" (installed)"
        status="on"
      fi
      items+=("$tool" "$desc" "$status")
    done
    local list_height=$((DIALOG_HEIGHT - 8))
    (( list_height < 10 )) && list_height=10
    selected=$(dialog --stdout --title "Distrodeck Installer" \
      --scrollbar \
      --checklist "Select tools to install/keep:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$list_height" \
      "${items[@]}") || true  # User may cancel/escape
    # Clear the screen after dialog closes before showing installation output
    clear
  else
    export DISTRODECK_NONINTERACTIVE=true
    selected="bat eza fd fzf glow jq ripgrep tldr tree yq zoxide zsh mc meld micro neovim screen tmux vscode bandwhich cron duf htop lm-sensors ncdu pciutils usbutils bind-tools curl iperf3 mtr net-tools nmap tcpdump tor traceroute ufw wget borgbackup duplicity fdupes lz4 tar unzip bfg build-tools composer delta gh git git-lfs lazygit tokei go java node php ruby rust ansible docker k9s lazydocker podman adb dialog flatpak nala ntfs wine gimp image-view isoforge nemo streamcontroller"
    remote_script_tools="aider antigravity claude-code codex copilot cursor gemini kiro ollama"
    if [[ "${DISTRODECK_ALL_INCLUDE_REMOTE_SCRIPT_TOOLS:-false}" == "true" ]]; then
      selected+=" ${remote_script_tools}"
    fi
  fi

  # Build set of selected tools
  declare -A selected_set=()
  if [[ -n "$selected" ]]; then
    IFS=' ' read -r -a choices_arr <<< "$selected"
    for choice in "${choices_arr[@]}"; do
      choice="${choice//\"/}"
      selected_set["$choice"]="true"
    done
  fi

  # Find tools to uninstall: tracked + currently installed + NOT selected
  local to_uninstall=()
  for tool in "${tools[@]}"; do
    if [[ "${tracked[$tool]:-}" == "true" ]] && \
       [[ "${installed[$tool]:-}" == "true" ]] && \
       [[ "${selected_set[$tool]:-}" != "true" ]]; then
      to_uninstall+=("$tool")
    fi
  done

  # Prompt user about uninstalling unchecked tools
  local do_uninstall=false
  if [[ ${#to_uninstall[@]} -gt 0 ]] && ! $all; then
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

  # If no selections and no uninstalls, exit
  if [[ -z "$selected" ]] && [[ "$do_uninstall" != "true" ]]; then
    log_warn "No selections made."
    exit 0
  fi

  # Track installation/uninstallation results
  local failed_installs=()
  local failed_uninstalls=()
  local successful_installs=()
  local successful_uninstalls=()
  local already_installed=()

  # Install selected tools
  for choice in "${!selected_set[@]}"; do
    if [[ "${installed[$choice]:-}" == "true" ]]; then
      log_info "Already installed: $choice"
      # Track it if not already tracked
      add_tracked_tool "$choice"
      already_installed+=("$choice")
      continue
    fi
    log_info "Installing: $choice"
    # Run installation in subshell to catch errors without exiting
    if (
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
      antigravity) install_antigravity "$mgr";;
      claude-code) install_claude_code "$mgr";;
      codex) install_codex "$mgr";;
      copilot) install_copilot "$mgr";;
      cursor) install_cursor "$mgr";;
      gemini) install_gemini "$mgr";;
      kiro) install_kiro "$mgr";;
      ollama) install_ollama "$mgr";;
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
    esac
    ); then
      # Installation command succeeded, verify tool is now installed
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
      if (
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
        antigravity) uninstall_antigravity "$mgr";;
        claude-code) uninstall_claude_code "$mgr";;
        codex) uninstall_codex "$mgr";;
        copilot) uninstall_copilot "$mgr";;
        cursor) uninstall_cursor "$mgr";;
        gemini) uninstall_gemini "$mgr";;
        kiro) uninstall_kiro "$mgr";;
        ollama) uninstall_ollama "$mgr";;
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
      esac
      ); then
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
  if ! $all && command -v dialog >/dev/null 2>&1; then
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

main "$@"
