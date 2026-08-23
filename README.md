# distrodeck

One CLI to snapshot and restore your installed packages before a distro upgrade.

Primary target: Ubuntu. Should work on other Debian-based distros with apt, and partially on any distro with snap/flatpak installed.

<img width="1237" height="622" alt="image" src="https://github.com/user-attachments/assets/fdddb54a-573f-43c1-b5a7-8feae14e2b15" />


## Features

- Export installed packages and package sources (including PPAs)
- Import and reinstall from the export file
- Diff an export against the current system before importing (text or JSON)
- Import makes an automatic backup and offers a revert prompt on failures
- Update/upgrade system packages (uses Nala)
- Trigger distro upgrades on Ubuntu
- Apply security updates
- Repair apt repo issues (disable broken sources, refresh keys)
- Run automation via `ansible-pull` from the TUI
- Track snaps, flatpaks, and AppImages
- Install 85 developer tools via TUI, or noninteractively with `--tools`, with uninstall support
- Includes an `About` entry in the TUI with GitHub and LinkedIn profile links

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

Default exports are saved under `~/.local/state/distrodeck/exports` (or
`$XDG_STATE_HOME/distrodeck/exports` when set).

distrodeck diff --input backup.txt

distrodeck diff --input backup.txt --detailed

distrodeck diff --input backup.txt --json

distrodeck import --input backup.txt --apply --update-sources

distrodeck import --input backup.txt --apply-config

distrodeck import --input backup.txt --apply-config-files

distrodeck update
distrodeck self-update
distrodeck self-upgrade

distrodeck update --cleanup-kernels

distrodeck upgrade
(On Debian, pass `--target-codename` or set `DISTRODECK_TARGET_CODENAME`.)

distrodeck upgrade --cleanup-kernels

distrodeck cleanup-kernels --dry-run

distrodeck cleanup-kernels

distrodeck security

distrodeck repo-repair

distrodeck doctor

distrodeck doctor --json

distrodeck preflight

distrodeck logs

distrodeck clear-logs

distrodeck install-tools

distrodeck git-status set

distrodeck git-status unset

distrodeck git-aliases set

distrodeck git-aliases unset

distrodeck git-aliases show

Recommended git aliases (prefixed with `d`):
- `git df`  -> fetch
- `git dp`  -> pull
- `git dfp` -> fetch --all; pull --all
- `git dl`  -> history (graph, oneline, all, colored)
- `git dpr` -> create PR (requires `gh`)
- `git dis` -> list repository issues (number/title/state, requires `gh`)
- `git dprs` -> list repository pull requests (number/title/state, requires `gh`)
- `git dup` -> push current branch and set upstream to `origin/<branch>`
- `git ds`  -> short status
- `git db`  -> verbose branches
- `git dbr` -> all branches (local + remote)
- `git dd`  -> diff
- `git dds` -> diff staged
- `git dco` -> checkout
- `git dcb` -> create branch
- `git dlr` -> latest 3 branches and latest 3 tags (newest first)
- `git dhelp` -> list distrodeck aliases

distrodeck sysinfo

distrodeck config-edit
Includes distrodeck config files if present (user and system).

distrodeck net-tools

distrodeck  # use the TUI "Automate" action

distrodeck install-tools --all

distrodeck install-tools --tools bat,eza,gh

distrodeck install-tools --tools-file tools.txt

distrodeck install-tools --list-tools
```

### Install-tools categories

The `install-tools` command offers tools organized by category:

| Category | Examples |
|----------|----------|
| `[Shell]` | bat, eza, fd, fzf, glow, jq, ripgrep, tldr, tree, yq, zoxide |
| `[Editor]` | mc, meld, micro, neovim, vscode |
| `[System]` | bandwhich, duf, htop, ncdu |
| `[Net]` | curl, nmap, mtr, tcpdump, tor, wget |
| `[Dev]` | bfg, delta, gh, git, lazygit, tokei |
| `[AI]` | aider, antigravity, codex, copilot, claude-code, gemini, ollama, cursor, kiro |
| `[Lang]` | go, java, node (24 LTS + nvm), php, ruby, rust |
| `[DevOps]` | ansible, docker, k9s, lazydocker, podman |
| `[Util]` | flatpak, ntfs-3g, wine |
| `[App]` | gimp, nemo, rustdesk, streamcontroller |

Unchecking a previously installed tool prompts to uninstall it. Installed tools are tracked in `~/.local/state/distrodeck/installed-tools.txt`.

For scripts and external integrators, `--tools LIST` and `--tools-file PATH` install a named set without opening the checklist. Unknown tool names exit 2 before anything is installed, and tools outside the requested set are left alone unless `--reconcile` is passed. `--list-tools` prints the catalog.

Selecting `node` installs Node 24 from the system repository and nvm (Node 24 and 22, default 24), so versions can be switched per shell with `nvm use 22`.

`distrodeck install-tools --all` installs the default non-interactive tool set. Tools that require downloaded installer confirmation or hosted account CLIs are skipped unless you run from an interactive terminal with `DISTRODECK_ALL_INCLUDE_OPT_IN_TOOLS=true`. The older `DISTRODECK_ALL_INCLUDE_REMOTE_SCRIPT_TOOLS=true` name is also accepted for compatibility.

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
- Docker test runner: `scripts/test-docker.sh`

## Scripts

This repo includes the `nikolareljin/script-helpers` git submodule under `scripts/script-helpers`.

```bash
git submodule update --init --recursive
```

When building Debian packages, `scripts/install-tools-tui.sh` and `scripts/script-helpers` are bundled so `distrodeck install-tools` works on fresh installs without initializing submodules.

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
- `apt_sources` captures non-PPA entries from `/etc/apt/sources.list` and `/etc/apt/sources.list.d`, excluding official repos.
- `--update-sources` replaces the old distro codename with the current one for `apt_sources` entries.
- AppImages are discovered in `~/Applications`, `~/AppImage`, `~/AppImages`, or `DISTRODECK_APPIMAGE_DIRS`.
- Import is dry-run by default. Use `--apply` to install.

## Configuration

Optional config file: `~/.config/distrodeck/config.ini` (or `/etc/distrodeck/config.ini`).

Example:

```
[apt]
official_hosts_common = mirrors.example.org
official_hosts_ubuntu = archive.ubuntu.com, security.ubuntu.com
official_hosts_debian = deb.debian.org, security.debian.org
# To fully override defaults:
# official_hosts_ubuntu_override = archive.ubuntu.com, security.ubuntu.com
```

Sample file: `examples/config.ini`.

## Development

Enable lightweight pre-commit checks:

```bash
git config core.hooksPath .githooks
```

## Compatibility

- Ubuntu: full support (apt, PPA, do-release-upgrade, snap, flatpak)
- Debian: apt + snap/flatpak, upgrade via `apt-get full-upgrade` with target codename
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

---

## Clone traffic

![Clone traffic](https://raw.githubusercontent.com/nikolareljin/stats/main/charts/distrodeck.svg)

_Updated daily. Total and unique cloners over the last 14 days._
