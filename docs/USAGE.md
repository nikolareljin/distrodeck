# distrodeck usage

## Overview

distrodeck exports a snapshot of installed packages and sources, then re-installs them after a distro upgrade.

Running with no arguments opens the TUI menu:

```
distrodeck
```

## Commands

### export

Export installed packages and sources to a file.

```
distrodeck export --output backup.txt
```

Options:
- `--output FILE`: export destination (default: `~/.local/state/distrodeck/exports/distrodeck-export-<host>-<timestamp>.txt`)
- `--appimage-dirs DIRS`: colon-separated AppImage search dirs
- `--include-config`: include a config snapshot of selected system directories
- `--config-dirs DIRS`: colon-separated config dirs (default: `/etc:/etc/apt:/etc/dnf:/etc/pacman.d`)
- `--config-exclude PATTERN`: exclude pattern for config snapshot (repeatable)
- `--config-archive PATH`: override config snapshot archive path
- `--include-config-files`: include key config files as entries
- `--config-files FILES`: colon-separated config files (default: `/etc/hosts:/etc/fstab:~/.ssh/config`)
- `--include-user-tools`: include pipx, npm globals, composer globals, nuget globals, cargo installs, gem installs, and go binaries
- `--include-services`: include enabled/active systemd services

Opt-in user-level tools export:

```
distrodeck export --output backup.txt --include-user-tools
```

Opt-in config snapshot with filters:

```
distrodeck export --output backup.txt --include-config \
  --config-dirs /etc:/etc/apt \
  --config-exclude "*.bak" \
  --config-exclude "*/cache/*"
```

### import

Import packages and sources from a file. Dry-run by default.

```
distrodeck import --input backup.txt --apply --update-sources
```

Import automatically creates a backup of the sections being restored (saved as
`distrodeck-backup-<hostname>-<timestamp>.txt` next to the input file). If the
import fails, it prompts to revert using the backup.

Dry-run shows a diff (desired vs current) and highlights missing/extra entries.

Options:
- `--input FILE`: export file to import
- `--apply`: perform installs (default: dry-run)
- `--update-sources`: replace old distro codename with the current one
- `--appimage-dirs DIRS`: colon-separated AppImage search dirs
- `--apply-config`: restore config snapshot from the export file
- `--config-archive PATH`: override config snapshot archive path
- `--apply-services`: enable services captured in the export
- `--sections`: comma-separated sections to restore (e.g., `apt_manual,snap,flatpak`)
- `--cleanup-extras`: remove snap/flatpak extras not present in the export
- `--apply-config-files`: restore exported config files to their paths

### update

Update and upgrade installed packages across apt/nala, snap, and flatpak.

```
distrodeck update
```

### upgrade

Run a distro upgrade. On Ubuntu this uses `do-release-upgrade`.

```
distrodeck upgrade
```

### security

Apply security updates when supported.

```
distrodeck security
```

### repo-repair

Detect apt repo errors, optionally disable broken sources, and refresh missing keys.

```
distrodeck repo-repair
```

### doctor

Check availability of package managers and upgrade tools.

```
distrodeck doctor
distrodeck doctor --verbose
```

### preflight

Run preflight checks (disk space, OS, connectivity, reboot requirement).

```
distrodeck preflight
```

### logs

View run logs.

```
distrodeck logs
distrodeck logs --latest
distrodeck logs --tail 50
```

### clear-logs

Delete all previous logs.

```
distrodeck clear-logs
```

### Docker test suite (Ubuntu 24.04)

Run the full automated test suite in a privileged Ubuntu 24.04 container with
the repo mounted from the host:

```
scripts/test-docker.sh
```

### sysinfo

Show full system info (CPU/GPU/memory/disks/network/public IP/ports/USB, plus speed test if available).

```
distrodeck sysinfo
```

### config-edit

Edit common system config files or repository sources in a TUI editor (nginx/apache/ssh/network/php, apt/yum/zypper/pacman sources).

```
distrodeck config-edit
```

### automate (TUI)

Run an `ansible-pull` automation from the TUI, including auth prompts and playbook/inventory selection.

```
distrodeck  # open TUI, choose "Automate"
```

Requires `ansible-pull` (install via `distrodeck install-tools`).

### net-tools

Run installed network tools from a TUI menu (nmap, mtr, iperf3, traceroute, tcpdump).

```
distrodeck net-tools
```

### install-tools

Install optional developer tools via a TUI checklist. Supports 64 tools organized by category.

```
distrodeck install-tools        # opens TUI checklist
distrodeck install-tools --all  # installs all tools non-interactively
```

**Features:**
- Tools are grouped by category with prefixes: `[Shell]`, `[Editor]`, `[System]`, `[Net]`, `[Backup]`, `[Dev]`, `[Lang]`, `[DevOps]`, `[Util]`, `[App]`
- Already installed tools are pre-checked and marked "(installed)"
- **Uninstall support**: Unchecking a tool prompts to uninstall it
- State tracking: Installed tools are tracked in `~/.local/state/distrodeck/installed-tools.txt`

**Available tools by category:**

| Category | Tools |
|----------|-------|
| Shell & CLI | bat, eza, fd, fzf, glow, jq, ripgrep, tldr, tree, yq, zoxide, zsh |
| Editors & Terminal | mc, meld, micro, neovim, screen, tmux, vscode |
| System & Monitoring | bandwhich, cron, duf, htop, lm-sensors, ncdu, pciutils, usbutils |
| Networking | bind-tools, curl, iperf3, mtr, net-tools, nmap, tcpdump, tor, traceroute, ufw, wget |
| Backup & Storage | borgbackup, duplicity, fdupes, lz4, tar, unzip |
| Development | bfg, build-tools, composer, delta, gh, git, git-lfs, lazygit, tokei |
| Languages | go, java, node (20 LTS), php, ruby, rust |
| DevOps & Containers | ansible, docker, k9s, lazydocker, podman |
| Utilities | adb, dialog, flatpak, nala, ntfs-3g, wine |
| Apps | gimp, image-view, isoforge, streamcontroller |

**Notable tools:**
- `bfg` - BFG Repo-Cleaner for removing large files from git history
- `gh` - GitHub CLI for working with GitHub from the terminal
- `delta` - Syntax-highlighting pager for git diffs
- `k9s` - Kubernetes cluster management TUI
- `podman` - Daemonless container engine (Docker alternative)
- `streamcontroller` - Control Elgato Stream Decks on Linux (via Flatpak)
- `gimp` - GNU Image Manipulation Program with web export plugins
- `wine` - Windows compatibility layer for running Windows applications
- `tor` - Anonymous communication network with Tor Browser

### git-status

Enable or disable git branch status in your shell prompt.
Branch name stays green; status shows as:
- `≡` green when up to date with remote
- `N↑` yellow when ahead by N commits
- `N↓` red when behind by N commits
- `A↑B↓` red when diverged (ahead by A, behind by B)
- `*` yellow when there are local uncommitted changes
Defaults to bash, but uses the active shell when available (bash, zsh, fish).

```
distrodeck git-status set
distrodeck git-status unset
```

Example prompt segment:

```
user@host ~/repo(main 2↑)$
user@host ~/repo(main 3↓)$
user@host ~/repo(main ≡)$
user@host ~/repo(main 2↑1↓)$
user@host ~/repo(main * 2↑)$
```

## Export file sections

```
[apt_manual]   # manually installed apt packages
[apt_hold]     # held apt packages
[ppas]         # Launchpad PPAs (ppa:user/name)
[apt_sources]  # non-PPA apt sources
[snap]         # snap packages with channel/classic info
[flatpak]      # flatpak apps with remote info
[pacman]       # pacman packages (Arch)
[dnf]          # dnf packages (Fedora/RHEL)
[zypper]       # zypper packages (openSUSE)
[appimage]     # discovered AppImages by path
[config_snapshot] # config snapshot archive and metadata
[config_files]    # individual config file entries (base64 content)
[services_enabled] # systemd enabled services
[services_active] # running services at export time
[pipx]         # pipx-installed apps
[npm_global]   # npm global packages
[composer_global] # composer global packages
[nuget_global] # dotnet global tools
[cargo]        # cargo-installed apps
[gem]          # ruby gems
[go]           # Go binaries
```

`config_snapshot` entries include:
- `archive=...` path to the tar.gz snapshot
- `dirs=...` colon-separated source dirs
- `exclude=...` exclude patterns (optional, repeatable)

`config_files` entries include:
- `path=...` file path to restore
- `content_b64=...` base64-encoded file contents

## AppImage discovery

Defaults to `~/Applications`, `~/AppImage`, `~/AppImages`.

Override with:
- `DISTRODECK_APPIMAGE_DIRS` or `APPIMAGE_DIRS` environment variables
- `--appimage-dirs` option
