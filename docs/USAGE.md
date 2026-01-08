# distrodeck usage

## Overview

distrodeck exports a snapshot of installed packages and sources, then re-installs them after a distro upgrade.

## Commands

### export

Export installed packages and sources to a file.

```
distrodeck export --output backup.txt
```

Options:
- `--output FILE`: export destination (default: `distrodeck-export.txt`)
- `--appimage-dirs DIRS`: colon-separated AppImage search dirs

### import

Import packages and sources from a file. Dry-run by default.

```
distrodeck import --input backup.txt --apply --update-sources
```

Options:
- `--input FILE`: export file to import
- `--apply`: perform installs (default: dry-run)
- `--update-sources`: replace old distro codename with the current one
- `--appimage-dirs DIRS`: colon-separated AppImage search dirs

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

### doctor

Check availability of package managers and upgrade tools.

```
distrodeck doctor
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
```

## AppImage discovery

Defaults to `~/Applications`, `~/AppImage`, `~/AppImages`.

Override with:
- `DISTRODECK_APPIMAGE_DIRS` or `APPIMAGE_DIRS` environment variables
- `--appimage-dirs` option
