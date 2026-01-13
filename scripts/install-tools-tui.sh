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
  install_pkg "$1" lazygit || log_warn "Failed to install lazygit from repos."
}

install_lazydocker() {
  install_pkg "$1" lazydocker || log_warn "Failed to install lazydocker from repos."
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

  if ! $all; then
    ensure_dialog
    dialog_init
    selected=$(dialog --stdout --title "Distrodeck Installer" \
      --checklist "Select tools to install:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 \
      "bat" "bat (cat alternative)" off \
      "curl" "curl" off \
      "eza" "eza (ls alternative)" off \
      "fd" "fd (find alternative)" off \
      "fzf" "fzf (fuzzy finder)" off \
      "git" "git" off \
      "git-lfs" "git-lfs" off \
      "jq" "jq (JSON CLI)" off \
      "ripgrep" "ripgrep (rg)" off \
      "tree" "tree" off \
      "wget" "wget" off \
      "yq" "yq (YAML CLI)" off \
      "zoxide" "zoxide (smart cd)" off \
      "starship" "starship prompt" off \
      "tmux" "tmux" off \
      "zsh" "zsh" off \
      "duf" "duf (disk space)" off \
      "htop" "htop" off \
      "ncdu" "ncdu (disk usage)" off \
      "build-tools" "build-essential / toolchain" off \
      "go" "Go" off \
      "java" "Java (JDK)" off \
      "micro" "micro editor" off \
      "neovim" "Neovim" off \
      "node" "Node.js + npm" off \
      "rust" "Rust (rustc/cargo)" off \
      "dialog" "dialog (TUI)" off \
      "docker" "Docker Engine" off \
      "lazygit" "LazyGit" off \
      "lazydocker" "LazyDocker" off \
      "nala" "Nala (apt UI)" off \
      "vscode" "VS Code (code)" off)
  else
    selected="bat curl eza fd fzf git git-lfs jq ripgrep tree wget yq zoxide starship tmux zsh duf htop ncdu build-tools go java micro neovim node rust dialog docker lazydocker lazygit nala vscode"
  fi

  if [[ -z "$selected" ]]; then
    log_warn "No selections made."
    exit 0
  fi

  IFS=' ' read -r -a choices <<< "$selected"
  for choice in "${choices[@]}"; do
    choice="${choice//\"/}"
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
