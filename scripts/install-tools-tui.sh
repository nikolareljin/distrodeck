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

tool_desc() {
  case "$1" in
    bat) echo "bat (cat alternative)";;
    curl) echo "curl";;
    eza) echo "eza (ls alternative)";;
    fd) echo "fd (find alternative)";;
    fzf) echo "fzf (fuzzy finder)";;
    git) echo "git";;
    ansible) echo "Ansible (ansible-pull)";;
    adb) echo "adb (Android Debug Bridge)";;
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
    php) echo "PHP";;
    composer) echo "Composer (PHP)";;
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
    isoforge) echo "Isoforge (burn-iso)";;
    image-view) echo "image-view (Rust image viewer)";;
    lm-sensors) echo "lm-sensors (hardware sensors)";;
    usbutils) echo "usbutils (lsusb)";;
    pciutils) echo "pciutils (lspci)";;
    borgbackup) echo "borgbackup";;
    duplicity) echo "duplicity";;
    fdupes) echo "fdupes";;
    lz4) echo "lz4";;
    tar) echo "tar";;
    unzip) echo "unzip";;
    mc) echo "mc (Midnight Commander)";;
    nmap) echo "nmap";;
    iperf3) echo "iperf3";;
    mtr) echo "mtr";;
    net-tools) echo "net-tools";;
    tcpdump) echo "tcpdump";;
    traceroute) echo "traceroute";;
    bind-tools) echo "bind-tools (dig/nslookup)";;
    screen) echo "screen";;
    cron) echo "cron";;
    ufw) echo "ufw firewall";;
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
    # Shell UX
    bat eza fd fzf jq ripgrep tree yq zoxide
    # Editors/terminal
    mc micro neovim screen tmux zsh
    # System/monitoring
    cron duf htop lm-sensors ncdu pciutils usbutils
    # Networking
    bind-tools curl iperf3 mtr net-tools nmap tcpdump traceroute wget
    # Storage/backup
    borgbackup duplicity fdupes lz4 tar unzip
    # Dev/tooling
    build-tools composer git ansible adb git-lfs go java node php rust
    # Containers/tools
    dialog docker lazydocker lazygit nala ufw vscode
    # Apps
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
      --checklist "Select tools to install:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" "$list_height" \
      "${items[@]}")
  else
    selected="bat eza fd fzf jq ripgrep tree yq zoxide mc micro neovim screen tmux zsh cron duf htop lm-sensors ncdu pciutils usbutils bind-tools curl iperf3 mtr net-tools nmap tcpdump traceroute wget borgbackup duplicity fdupes lz4 tar unzip build-tools composer git ansible adb git-lfs go java node php rust dialog docker lazydocker lazygit nala ufw vscode image-view isoforge"
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
  done
}

main "$@"
