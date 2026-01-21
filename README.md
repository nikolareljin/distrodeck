# distrodeck

One CLI to snapshot and restore your installed packages before a distro upgrade.

Primary target: Ubuntu. Should work on other Debian-based distros with apt, and partially on any distro with snap/flatpak installed.

<img width="1237" height="622" alt="image" src="https://github.com/user-attachments/assets/fdddb54a-573f-43c1-b5a7-8feae14e2b15" />


## Features

- Export installed packages and package sources (including PPAs)
- Import and reinstall from the export file
- Import makes an automatic backup and offers a revert prompt on failures
- Update/upgrade system packages (uses Nala)
- Trigger distro upgrades on Ubuntu
- Apply security updates
- Repair apt repo issues (disable broken sources, refresh keys)
- Run automation via `ansible-pull` from the TUI
- Track snaps, flatpaks, and AppImages

## Install

Requires Python 3 (installed by default on Ubuntu).

Clone into your projects folder and run from the repo root:

```bash
./distrodeck --help
```

Optionally add to PATH:

```bash
sudo ln -s "$PWD/distrodeck" /usr/local/bin/distrodeck
```

## Usage

```bash
distrodeck  # opens the TUI menu

distrodeck export --output backup.txt

distrodeck export --output backup.txt --include-user-tools

distrodeck export --output backup.txt --include-config

distrodeck export --output backup.txt --include-services

distrodeck export --output backup.txt --include-config-files

distrodeck import --input backup.txt --apply --update-sources

distrodeck import --input backup.txt --apply-config

distrodeck import --input backup.txt --apply-config-files

distrodeck update

distrodeck upgrade

distrodeck security

distrodeck repo-repair

distrodeck doctor

distrodeck preflight

distrodeck logs

distrodeck clear-logs

distrodeck install-tools

distrodeck git-status set

distrodeck git-status unset

distrodeck sysinfo

distrodeck config-edit

distrodeck net-tools

distrodeck  # use the TUI "Automate" action

distrodeck install-tools --all
```

Example prompt segment after `git-status set`:

```
user@host ~/repo(main 2↑)$
user@host ~/repo(main 3↓)$
user@host ~/repo(main ≡)$
user@host ~/repo(main 2↑1↓)$
```

Legend:
- `≡` green: up to date with remote
- `N↑` yellow: ahead by N commits
- `N↓` red: behind by N commits
- `A↑B↓` red: diverged (ahead by A, behind by B)
- `*` yellow: local uncommitted changes

## Documentation

- Usage guide: `docs/USAGE.md`
- Man page: `docs/man/distrodeck.1` (regenerate with `make man`)
- CI guide: `docs/CI.md`
- Installer TUI: `scripts/install-tools-tui.sh`

## Scripts

This repo includes the `nikolareljin/script-helpers` git submodule under `scripts/script-helpers`.

```bash
git submodule update --init --recursive
```

## Export file format

The export is a plain text file with sections:

```
# distrodeck export v1
exported_at=...
distro_id=ubuntu
codename=jammy

[apt_manual]
...

[apt_hold]
...

[ppas]
ppa:graphics-drivers/ppa

[apt_sources]
deb [signed-by=/usr/share/keyrings/foo.gpg] https://example.com stable main

[snap]
firefox channel=latest/stable classic=false

[flatpak]
remote=flathub app=org.gimp.GIMP

[pacman]
neovim

[dnf]
htop

[zypper]
git

[appimage]
/home/user/Applications/Some.AppImage
```

## Notes

- `export` prefers manually installed apt packages and captures held packages.
- PPAs are captured as `ppa:user/name` entries and re-added on import.
- `apt_sources` captures non-PPA entries under `/etc/apt/sources.list.d`.
- `--update-sources` replaces the old distro codename with the current one for `apt_sources` entries.
- AppImages are discovered in `~/Applications`, `~/AppImage`, `~/AppImages`, or `DISTRODECK_APPIMAGE_DIRS`.
- Import is dry-run by default. Use `--apply` to install.

## Compatibility

- Ubuntu: full support (apt, PPA, do-release-upgrade, snap, flatpak)
- Other Debian-based distros: apt + flatpak + snap (no `do-release-upgrade`)
- Fedora/RHEL: export/import via `dnf` (no distro-upgrade automation)
- Arch: export/import via `pacman` (no distro-upgrade automation)
- openSUSE: export/import via `zypper` (no distro-upgrade automation)

## Packaging (Ubuntu PPA)

Standard Debian packaging is included. Build a `.deb` locally with:

```bash
make man
dpkg-buildpackage -us -uc
```

Optional: build a `.deb` with `fpm` (requires `fpm`):

```bash
make fpm
```

Before publishing to a PPA, update `debian/changelog` and `debian/control` with your maintainer name and target series.

## Packaging (RPM/Homebrew)

- Build `.rpm`: `./tools/build-rpm.sh`
- Homebrew tarball + formula: `./tools/build-brew-tarball.sh && ./tools/gen-brew-formula.sh`
- Publish Homebrew formula: `./tools/publish-homebrew.sh`
- Install from tap: `brew install <tap>/distrodeck`

## Contributing

Keep the script POSIX-friendly where possible and avoid adding heavy dependencies.
