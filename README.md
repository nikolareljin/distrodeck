# distrodeck

One CLI to snapshot and restore your installed packages before a distro upgrade.

Primary target: Ubuntu. Should work on other Debian-based distros with apt, and partially on any distro with snap/flatpak installed.

For a complete overview of the application, its safety model, and supported workflows, see [What distrodeck does](docs/OVERVIEW.md).

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

distrodeck reclaim
(Reports regenerable build output under the configured developer workspace.
Deletes nothing without `--apply`.)

distrodeck reclaim --older-than 30 --apply

distrodeck reclaim ~/work

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
- `git dhelp` -> detailed distrodeck alias reference (purpose, parameters, requirements, examples)

distrodeck sysinfo

distrodeck config-edit
Includes distrodeck config files if present (user and system).

distrodeck net-tools

distrodeck ollama models list
distrodeck ollama models pull coding
distrodeck ollama models remove vision

distrodeck  # use the TUI "Automate" action

distrodeck install-tools --all

distrodeck install-tools --tools bat,eza,gh

distrodeck install-tools --tools-file tools.txt

distrodeck install-tools --list-tools
```

### Install-tools categories

`distrodeck install-tools` opens a category menu. Pick a category, check the
tools you want in its own checklist, install that block, and come back to the
menu for the next one; Quit ends. Nothing is preselected in bulk.

| Id | Category | Tools (opt-in marked *) |
|----|----------|-------|
| `shell` | Shell & CLI | bat, eza, fd, fzf, glow, jq, ripgrep, tldr, tree, yq, zoxide, zsh |
| `editors` | Editors & Terminal | mc, meld, micro, neovim, screen, tmux |
| `system` | System & Monitoring | bandwhich, cron, duf, htop, lm-sensors, ncdu, pciutils, usbutils |
| `network` | Networking | bind-tools, curl, iperf3, mtr, net-tools, nmap, tcpdump, tor, traceroute, ufw, wget |
| `backup` | Backup & Storage | borgbackup, duplicity, fdupes, lz4, tar, unzip |
| `dev` | Development | bfg, build-tools, composer, delta, gh, git, git-lantern, git-lfs, lazygit, tokei |
| `ai` | AI tools | aider*, ai-runner, claude-code*, codex*, copilot*, gemini*, ollama* |
| `ides` | IDEs | antigravity*, cursor*, intellij-idea-community*, kiro*, pycharm-community*, vscode*, zed* |
| `lang` | Languages & Runtimes | go, java (JDK 17/21/25, default 21), node (24 LTS + nvm), php, ruby, rust |
| `devops` | DevOps & Containers | ansible, docker, k9s, lazydocker, podman |
| `media` | Media | audacity, ffmpeg, handbrake, kdenlive, mpv, obs-studio, vlc |
| `graphics` | Graphics | blender, darktable, gimp, inkscape, krita |
| `util` | Utilities | adb, dialog, flatpak, nala, ntfs-3g, wine |
| `db-sql` | Relational databases | mariadb*, mysql*, oracle-free* (container), pgvector*, postgresql*, sqlite* |
| `db-nosql` | NoSQL & graph databases | atlas*, cassandra* (Apache repo), couchdb*, mongodb*, neo4j* (Neo4j repo), redis*, valkey* |
| `db-vector` | Vector databases | chroma* (pipx), milvus* (container), qdrant* (container), weaviate* (container) |
| `storage` | Object storage | minio* (macOS only, archived upstream), minio-client, rclone, s3cmd, seaweedfs* (container) |
| `db-admin` | Database admin | beekeeper-studio*, dbeaver-ce*, litecli, mongodb-compass*, mycli, pgadmin4*, pgcli, sqlitebrowser*, usql |
| `sysadmin` | System admin | btop, cockpit* (127.0.0.1:9090), glances, lnav |
| `web` | Web services | apache2*, caddy*, certbot, haproxy*, mkcert, nginx* |
| `prog` | Programming tools | bruno*, clang, cmake, dotnet-sdk*, gdb, httpie, kotlin, ninja, nvm, pipx, pre-commit, pyenv, sdkman*, shellcheck, uv, valgrind |
| `claude-plugins` | Claude Code plugins | plugin-claude-md-management*, plugin-code-review*, plugin-code-simplifier*, plugin-commit-commands*, plugin-feature-dev*, plugin-frontend-design*, plugin-hookify*, plugin-pr-review-toolkit*, plugin-security-guidance*, plugin-skill-creator* |
| `apps` | Apps | image-view, isoforge, nemo, rustdesk, streamcontroller |

Unchecking a previously installed tool prompts to uninstall it. Installed tools are tracked in `~/.local/state/distrodeck/installed-tools.txt`.

For scripts and external integrators, `--tools LIST` and `--tools-file PATH` install a named set without opening the checklist. Unknown tool names exit 2 before anything is installed, and tools outside the requested set are left alone unless `--reconcile` is passed. `--list-tools` prints the catalog. `--category media,graphics` installs the default-on tools of those categories, one block each; opt-in tools (*) install only when named with `--tools`. `--list-categories` prints the ids, and `--list-catalog --format tsv` prints one line per tool: `category_id`, `category_label`, `tool`, `label`, `opt_in` (0/1), `installed` (0/1), tab separated, with no colour, no dialog and no root.

Media, Graphics and the JetBrains/Zed IDEs install from the distro package where one exists and fall back to the Flathub Flatpak where it does not (for example HandBrake on Fedora and openSUSE, Zed on Ubuntu). A tool with neither fails on its own with a message.

**Servers** (databases, web servers, Cockpit) are opt-in. They are enabled
with systemd (or `brew services` on macOS) and bound to 127.0.0.1: nginx,
Apache and Caddy listen directives are rewritten, MySQL/MariaDB get a
`bind-address = 127.0.0.1` drop-in, Cockpit's socket listens on
127.0.0.1:9090; PostgreSQL, Redis, Valkey, CouchDB, Neo4j and Cassandra already
default to localhost. On apt every server installs under a temporary
`/usr/sbin/policy-rc.d` that answers 101, so its postinst cannot start it on
0.0.0.0 before the bind is rewritten; the file is removed after the install,
also on failure, and an existing policy-rc.d that distrodeck did not write is
left alone. Uninstall stops the service, removes the concrete server
packages behind a metapackage (resolved from dpkg at that moment, e.g.
`postgresql-17` and `postgresql-17-pgvector`, `mysql-server-8.0`,
`mariadb-server` for Debian's `default-mysql-server`, `apache2-bin`,
`redis-tools`), never runs autoremove, and keeps the data directory.

The MongoDB and Neo4j repository keys are pinned to their full fingerprints
(MongoDB 8.0 `4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05`, Neo4j
`1EEFB8767D4924B86EAD08A459D700E4D37F5F19`); a download holding any other key
is refused. On dnf the verified MongoDB key is installed locally instead of
letting dnf fetch it. Cassandra's KEYS file is not pinned (it is the changing
set of release managers' keys); it must hold at least one key and every
fingerprint is logged.

Debian ships no `mysql-server`: there the `mysql` tool installs
`default-mysql-server`, which is MariaDB, and says so (use the MySQL APT
repository for Oracle MySQL). Debian bookworm has no `valkey-server` either;
the tool stops with the `bookworm-backports` command to run instead.

MinIO archived its open-source server: dl.min.io answers 410 Gone for the
server and client binaries, so distrodeck installs nothing for it on Linux and
`seaweedfs` is the S3 server to use. On macOS the deprecated `minio` formula
still installs, but it is not started, because its `brew services` definition
listens on every interface; the installer prints a loopback `minio server`
command instead.

**Containers** (oracle-free, qdrant, milvus, weaviate, seaweedfs) need docker
or podman. Each runs a pinned image tag as `distrodeck-<tool>` with a named
volume `distrodeck-<tool>`, publishes its ports on 127.0.0.1 only and restarts
unless stopped. A port another process holds is refused with that process's
name. Uninstall removes the container and keeps the volume; `--purge` removes
it too. The Oracle password is generated once into
`~/.local/state/distrodeck/oracle-free.password` (mode 600); `--purge`
removes it with the volume. Milvus runs as milvus `scripts/standalone_embed.sh`
runs it at the pinned tag (embedded etcd, its config under
`~/.local/state/distrodeck/milvus`, `seccomp:unconfined`), with 19530 and 9091
on 127.0.0.1 and etcd's 2379 not published. Qdrant has no Homebrew formula, so
like the other containers it is hidden on macOS.

**Claude Code plugins** need the `claude` CLI and come only from the public
`anthropics/claude-plugins-official` marketplace, which is added when missing.
They install at user scope with stdin closed and a 300 s limit
(`DISTRODECK_PLUGIN_TIMEOUT`), so a `--tools` or `--all` run never waits on a
prompt. A plugin that needs a confirmed command fails and is installed by hand.

**macOS**: the installer re-execs under Homebrew bash 5 (`brew install bash`
if it is missing) and installs with `brew` / `brew install --cask`. Tools with
no Homebrew formula or cask (ufw, cockpit, flatpak, nala, ntfs-3g, ...) are
hidden from the menu, `--category` and `--all`.


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

[developer]
# Developer-only reclaim workspace. The default is ~/Projects.
# Set this from the TUI's Settings entry, or override it per command:
# distrodeck reclaim ~/work
# workspace = ~/Projects
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
