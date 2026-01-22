#!/usr/bin/env bash
# SCRIPT: install-tools-tui.sh
# DESCRIPTION: TUI installer for common developer tools.
# USAGE: ./install-tools-tui.sh [--all]
# EXAMPLE: ./install-tools-tui.sh --all
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${SCRIPT_DIR}/script-helpers}"

# Check if script-helpers directory exists
if [[ ! -d "$SCRIPT_HELPERS_DIR" ]]; then
  # Prompt to run update.sh to fetch submodules
  echo "The script-helpers directory is missing."
  echo "Please run the update.sh script to initialize submodules:"
  echo "  ./scripts/update.sh"
  exit 1
fi

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging dialog

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
    apt) sudo apt-get update && sudo apt-get install -y "$@";;
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

install_node() {
  local mgr="$1"
  case "$mgr" in
    apt) install_pkg "$mgr" nodejs npm;;
    dnf|pacman|zypper) install_pkg "$mgr" nodejs npm;;
    *) log_warn "Node install not supported for this distro.";;
  esac
}

install_lazygit() {
  local mgr="$1"
  if [[ "$mgr" == "apt" ]]; then
    if ! command -v add-apt-repository >/dev/null 2>&1; then
      install_pkg "$mgr" software-properties-common || true
    fi
    if command -v add-apt-repository >/dev/null 2>&1; then
      sudo add-apt-repository -y ppa:lazygit-team/release || true
      sudo apt update || true
      if sudo apt install -y lazygit; then
        return
      fi
    fi
  else
    if install_pkg "$mgr" lazygit; then
      return
    fi
    if install_pkg "$mgr" lazygit-gm; then
      return
    fi
  fi
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
    log_warn "go install failed; falling back to release tarball."
  fi

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log_warn "curl or wget is required for lazygit fallback download."
    return
  fi
  local os arch url tmp_dir bin_path
  os="$(uname -s)"
  case "$os" in
    Linux) os="Linux";;
    Darwin) os="Darwin";;
    *) log_warn "Fallback lazygit install not supported for OS: $os"; return;;
  esac

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64";;
    aarch64|arm64) arch="arm64";;
    armv7l|armv7) arch="armv7";;
    i386|i686) arch="386";;
    *) log_warn "Fallback lazygit install not supported for arch: $arch"; return;;
  esac

  url="https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${os}_${arch}.tar.gz"
  tmp_dir="$(mktemp -d)"
  bin_path="$tmp_dir/lazygit"
  if ! download_file "$url" "$tmp_dir/lazygit.tar.gz"; then
    local version api_url
    api_url="https://api.github.com/repos/jesseduffield/lazygit/releases/latest"
    if download_file "$api_url" "$tmp_dir/lazygit-release.json"; then
      version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/lazygit-release.json" | head -n1)"
    fi
    if [[ -n "$version" ]]; then
      version="${version#v}"
      url="https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_${os}_${arch}.tar.gz"
      download_file "$url" "$tmp_dir/lazygit.tar.gz"
    fi
  fi
  if [[ -f "$tmp_dir/lazygit.tar.gz" ]]; then
    if tar -xzf "$tmp_dir/lazygit.tar.gz" -C "$tmp_dir"; then
      if [[ -f "$bin_path" ]]; then
        sudo install -m 0755 "$bin_path" /usr/local/bin/lazygit
        log_info "Installed lazygit to /usr/local/bin/lazygit"
      else
        log_warn "Fallback lazygit install failed: binary not found in archive."
      fi
    else
      log_warn "Fallback lazygit install failed: unable to extract archive."
    fi
  else
    log_warn "Fallback lazygit install failed: download error."
  fi
  rm -rf "$tmp_dir"

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
}

install_lazydocker() {
  if install_pkg "$1" lazydocker; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_warn "Failed to install lazydocker from repos, and curl is missing for fallback install."
    return
  fi
  if [[ "$(uname -s)" != "Linux" ]]; then
    log_warn "Fallback lazydocker install is only supported on Linux."
    return
  fi
  log_info "Installing lazydocker via upstream install script..."
  curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash || \
    log_warn "Fallback lazydocker install failed."
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
  if ! command -v cargo >/dev/null 2>&1; then
    log_warn "cargo is required to install image-view; installing Rust..."
    install_rust "$mgr" || true
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    log_warn "cargo still missing; cannot install image-view."
    return 1
  fi
  cargo install --git https://github.com/nikolareljin/image-view --bin image-view || \
    log_warn "Failed to install image-view via cargo."
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
  case "$mgr" in
    apt) install_pkg "$mgr" tldr;;
    dnf) install_pkg "$mgr" tldr;;
    pacman) install_pkg "$mgr" tldr;;
    zypper) install_pkg "$mgr" tldr;;
    *) log_warn "tldr install not supported for this distro.";;
  esac
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
        version="v0.32.4"  # Fallback
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
        x86_64|amd64) arch="amd64";;
        aarch64|arm64) arch="arm64";;
        i386|i686) arch="386";;
        *) log_warn "glow install not supported for arch: $arch"; return 1;;
      esac
      if download_file "https://api.github.com/repos/charmbracelet/glow/releases/latest" "$tmp_dir/release.json"; then
        version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"v\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
      fi
      if [[ -z "$version" ]]; then
        version="1.5.1"  # Fallback
      fi
      url="https://github.com/charmbracelet/glow/releases/download/v${version}/glow_${version}_Linux_${arch}.tar.gz"
      if download_file "$url" "$tmp_dir/glow.tar.gz"; then
        tar -xzf "$tmp_dir/glow.tar.gz" -C "$tmp_dir"
        sudo install -m 0755 "$tmp_dir/glow" /usr/local/bin/glow
        log_info "Installed glow to /usr/local/bin/glow"
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
          x86_64|amd64) arch="amd64";;
          aarch64|arm64) arch="arm64";;
          *) log_warn "delta install not supported for arch: $arch"; return 1;;
        esac
        if download_file "https://api.github.com/repos/dandavison/delta/releases/latest" "$tmp_dir/release.json"; then
          version="$(sed -n 's/.*\"tag_name\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p' "$tmp_dir/release.json" | head -n1)"
        fi
        if [[ -z "$version" ]]; then
          version="0.16.5"  # Fallback
        fi
        url="https://github.com/dandavison/delta/releases/download/${version}/delta-${version}-x86_64-unknown-linux-gnu.tar.gz"
        if [[ "$arch" == "arm64" ]]; then
          url="https://github.com/dandavison/delta/releases/download/${version}/delta-${version}-aarch64-unknown-linux-gnu.tar.gz"
        fi
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

install_gh() {
  local mgr="$1"
  case "$mgr" in
    apt)
      # Add GitHub CLI official repo for apt
      if ! command -v gh >/dev/null 2>&1; then
        if ! command -v curl >/dev/null 2>&1; then
          install_pkg "$mgr" curl || true
        fi
        (type -p wget >/dev/null || sudo apt-get install wget -y) \
          && sudo mkdir -p -m 755 /etc/apt/keyrings \
          && out=$(mktemp) && wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
          && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
          && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
          && sudo apt update \
          && sudo apt install gh -y
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
    version="1.14.0"  # Fallback version
  fi

  url="https://repo1.maven.org/maven2/com/madgag/bfg/${version}/bfg-${version}.jar"
  jar_path="$tmp_dir/bfg.jar"

  if download_file "$url" "$jar_path"; then
    sudo mkdir -p "$install_dir"
    sudo cp "$jar_path" "$install_dir/bfg.jar"
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
    apt|dnf|pacman|zypper) uninstall_pkg "$mgr" nodejs npm;;
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
  uninstall_pkg "$1" tldr || log_warn "Failed to uninstall tldr."
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
    # ── Languages & Runtimes ──
    go) echo "[Lang] Go";;
    java) echo "[Lang] Java (JDK)";;
    node) echo "[Lang] Node.js + npm";;
    php) echo "[Lang] PHP";;
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
    nala) echo "[Util] Nala - prettier apt";;
    # ── Apps ──
    image-view) echo "[App] image-view - terminal image viewer";;
    isoforge) echo "[App] Isoforge - ISO burner";;
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
    tldr) command -v tldr >/dev/null 2>&1;;
    bandwhich) command -v bandwhich >/dev/null 2>&1;;
    k9s) command -v k9s >/dev/null 2>&1;;
    podman) command -v podman >/dev/null 2>&1;;
    tokei) command -v tokei >/dev/null 2>&1;;
    glow) command -v glow >/dev/null 2>&1;;
    delta) command -v delta >/dev/null 2>&1;;
    meld) command -v meld >/dev/null 2>&1;;
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
    bind-tools curl iperf3 mtr net-tools nmap tcpdump traceroute ufw wget
    # ── Backup & Storage ──
    borgbackup duplicity fdupes lz4 tar unzip
    # ── Development ──
    bfg build-tools composer delta gh git git-lfs lazygit tokei
    # ── Languages & Runtimes ──
    go java node php rust
    # ── DevOps & Containers ──
    ansible docker k9s lazydocker podman
    # ── Utilities ──
    adb dialog nala
    # ── Apps ──
    image-view isoforge
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
      "${items[@]}")
  else
    selected="bat eza fd fzf glow jq ripgrep tldr tree yq zoxide zsh mc meld micro neovim screen tmux vscode bandwhich cron duf htop lm-sensors ncdu pciutils usbutils bind-tools curl iperf3 mtr net-tools nmap tcpdump traceroute ufw wget borgbackup duplicity fdupes lz4 tar unzip bfg build-tools composer delta gh git git-lfs lazygit tokei go java node php rust ansible docker k9s lazydocker podman adb dialog nala image-view isoforge"
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
    if [[ "${tracked[$tool]}" == "true" ]] && \
       [[ "${installed[$tool]}" == "true" ]] && \
       [[ "${selected_set[$tool]}" != "true" ]]; then
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
  fi

  # If no selections and no uninstalls, exit
  if [[ -z "$selected" ]] && [[ "$do_uninstall" != "true" ]]; then
    log_warn "No selections made."
    exit 0
  fi

  # Install selected tools
  for choice in "${!selected_set[@]}"; do
    if [[ "${installed[$choice]}" == "true" ]]; then
      log_info "Already installed: $choice"
      # Track it if not already tracked
      add_tracked_tool "$choice"
      continue
    fi
    log_info "Installing: $choice"
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
    esac
    # Track successfully installed tools
    if is_installed_tool "$choice"; then
      add_tracked_tool "$choice"
    fi
  done

  # Uninstall unchecked tools if user agreed
  if [[ "$do_uninstall" == "true" ]]; then
    for tool in "${to_uninstall[@]}"; do
      log_info "Uninstalling: $tool"
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
      esac
      # Remove from tracked list
      remove_tracked_tool "$tool"
    done
  fi

  log_info "Tool installation/removal complete."
}

main "$@"
