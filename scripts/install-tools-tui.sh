#!/usr/bin/env bash
# SCRIPT: install-tools-tui.sh
# DESCRIPTION: TUI installer for common developer tools.
# USAGE: ./install-tools-tui.sh [--all]
# EXAMPLE: ./install-tools-tui.sh --all
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${SCRIPT_DIR}/script-helpers}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging dialog

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
  if install_pkg "$1" lazygit; then
    return
  fi
  install_pkg "$1" lazygit-gm || log_warn "Failed to install lazygit (tried lazygit and lazygit-gm)."
}

install_lazydocker() {
  if install_pkg "$1" lazydocker; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    log_warn "Failed to install lazydocker from repos, and curl is missing for fallback install."
    return
  fi

  local os arch url tmp_dir bin_path
  os="$(uname -s)"
  case "$os" in
    Linux) os="Linux";;
    Darwin) os="Darwin";;
    *) log_warn "Fallback lazydocker install not supported for OS: $os"; return;;
  esac

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64";;
    aarch64|arm64) arch="arm64";;
    armv7l|armv7) arch="armv7";;
    i386|i686) arch="386";;
    *) log_warn "Fallback lazydocker install not supported for arch: $arch"; return;;
  esac

  url="https://github.com/jesseduffield/lazydocker/releases/latest/download/lazydocker_${os}_${arch}.tar.gz"
  tmp_dir="$(mktemp -d)"
  bin_path="$tmp_dir/lazydocker"
  if curl -fsSL "$url" -o "$tmp_dir/lazydocker.tar.gz"; then
    if tar -xzf "$tmp_dir/lazydocker.tar.gz" -C "$tmp_dir"; then
      if [[ -f "$bin_path" ]]; then
        sudo install -m 0755 "$bin_path" /usr/local/bin/lazydocker
        log_info "Installed lazydocker to /usr/local/bin/lazydocker"
      else
        log_warn "Fallback lazydocker install failed: binary not found in archive."
      fi
    else
      log_warn "Fallback lazydocker install failed: unable to extract archive."
    fi
  else
    log_warn "Fallback lazydocker install failed: download error."
  fi
  rm -rf "$tmp_dir"
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

tool_desc() {
  case "$1" in
    bat) echo "bat (cat alternative)";;
    curl) echo "curl";;
    eza) echo "eza (ls alternative)";;
    fd) echo "fd (find alternative)";;
    fzf) echo "fzf (fuzzy finder)";;
    git) echo "git";;
    git-lfs) echo "git-lfs";;
    jq) echo "jq (JSON CLI)";;
    ripgrep) echo "ripgrep (rg)";;
    tree) echo "tree";;
    wget) echo "wget";;
    yq) echo "yq (YAML CLI)";;
    zoxide) echo "zoxide (smart cd)";;
    starship) echo "starship prompt";;
    tmux) echo "tmux";;
    zsh) echo "zsh";;
    duf) echo "duf (disk space)";;
    htop) echo "htop";;
    ncdu) echo "ncdu (disk usage)";;
    build-tools) echo "build-essential / toolchain";;
    go) echo "Go";;
    java) echo "Java (JDK)";;
    micro) echo "micro editor";;
    neovim) echo "Neovim";;
    node) echo "Node.js + npm";;
    rust) echo "Rust (rustc/cargo)";;
    dialog) echo "dialog (TUI)";;
    docker) echo "Docker Engine";;
    lazydocker) echo "LazyDocker";;
    lazygit) echo "LazyGit";;
    nala) echo "Nala (apt UI)";;
    vscode) echo "VS Code (code)";;
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

  declare -A installed=()
  local tools=(
    bat curl eza fd fzf git git-lfs jq ripgrep tree wget yq zoxide
    starship tmux zsh duf htop ncdu
    build-tools go java micro neovim node rust
    dialog docker lazydocker lazygit nala vscode
  )

  if ! $all; then
    ensure_dialog
    dialog_init
    dialog --stdout --title "Distrodeck Installer" \
      --infobox "Checking installed tools..." "$DIALOG_HEIGHT" "$DIALOG_WIDTH"
    for tool in "${tools[@]}"; do
      if is_installed_tool "$tool"; then
        installed["$tool"]="true"
      else
        installed["$tool"]="false"
      fi
    done
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
    selected=$(dialog --stdout --title "Distrodeck Installer" \
      --checklist "Select tools to install:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 \
      "${items[@]}")
  else
    for tool in "${tools[@]}"; do
      if is_installed_tool "$tool"; then
        installed["$tool"]="true"
      else
        installed["$tool"]="false"
      fi
    done
    selected="bat curl eza fd fzf git git-lfs jq ripgrep tree wget yq zoxide starship tmux zsh duf htop ncdu build-tools go java micro neovim node rust dialog docker lazydocker lazygit nala vscode"
  fi

  if [[ -z "$selected" ]]; then
    log_warn "No selections made."
    exit 0
  fi

  IFS=' ' read -r -a choices <<< "$selected"
  for choice in "${choices[@]}"; do
    choice="${choice//\"/}"
    if [[ "${installed[$choice]}" == "true" ]]; then
      log_info "Already installed: $choice"
      continue
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
      git-lfs) install_git_lfs "$mgr";;
      zsh) install_zsh "$mgr";;
      starship) install_starship "$mgr";;
      tmux) install_tmux "$mgr";;
      htop) install_htop "$mgr";;
      ncdu) install_ncdu "$mgr";;
      duf) install_duf "$mgr";;
      tree) install_tree "$mgr";;
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
      rust) install_rust "$mgr";;
      go) install_go "$mgr";;
      vscode) install_vscode "$mgr";;
    esac
  done
}

main "$@"
