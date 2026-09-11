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

Note: deb822 `.sources` conversion preserves Architectures and Signed-By options only; other deb822 fields are ignored.
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

### diff

Compare an export file against the current system without changing anything.
Read-only: it never installs, removes, or touches package sources.

```
distrodeck diff --input backup.txt
distrodeck diff --input backup.txt --detailed
distrodeck diff --input backup.txt --sections apt_manual,snap --json
```

For each section it reports:
- `missing`: present in the export but not installed on this system
- `extra`: installed on this system but absent from the export

Options:
- `--input FILE`: export file to compare (required)
- `--sections`: comma-separated sections to compare (default: all comparable
  sections). Valid values: `apt_manual`, `apt_hold`, `ppas`, `apt_sources`,
  `snap`, `flatpak`, `pacman`, `dnf`, `zypper`, `appimage`
- `--detailed`: list the differing entries instead of only counts
- `--json`: emit a machine-readable report (schema version 1)
- `--exit-code`: exit 1 when differences are found, 0 when in sync
- `--appimage-dirs DIRS`: colon-separated AppImage search dirs

Output is sorted, so repeated runs against unchanged inputs produce identical
output and can be diffed or checksummed. Snap and flatpak entries are compared
on the package name alone, so a channel or remote change is not reported as an
add plus a remove.

Without `--exit-code`, the command exits 0 whether or not differences exist;
`--exit-code` is the opt-in for CI-style checks:

```
distrodeck diff --input backup.txt --exit-code || echo "system has drifted"
```

JSON shape:

```json
{
  "schema": 1,
  "file": "backup.txt",
  "export_distro_id": "ubuntu",
  "current_distro_id": "ubuntu",
  "codename": "noble",
  "sections": {
    "apt_manual": { "missing": ["curl"], "extra": ["vim"] }
  },
  "summary": { "missing": 1, "extra": 1 }
}
```

Config snapshots, service state, and config files are not comparable as lists
and are therefore outside the scope of `diff`.

### self-update / self-upgrade

Update distrodeck itself through its native package manager or from a clean source checkout.

```
distrodeck self-update
distrodeck self-upgrade
```

Package-managed installs use their native updater and require sudo except Homebrew. Source checkouts must be clean and fast-forwardable. They reinstall with sudo unless the detected prefix is under the current home directory; distrodeck refreshes recursive submodules, builds, and reinstalls with the detected prefix (or `PREFIX` when set). A dirty or non-fast-forwardable checkout is refused without installation.

### update

Update and upgrade installed packages across apt/nala, snap, and flatpak.
Old kernel cleanup is opt-in and keeps the running kernel plus one previous kernel by default.

```
distrodeck update
distrodeck update --cleanup-kernels
```

Options:
- `--cleanup-kernels`: clean old auto-installed kernels after a successful update
- `--keep-kernels N`: previous kernel versions to keep when cleanup is enabled

### reclaim

Report, and with `--apply` remove, build output under a workspace of checkouts.
A workspace is mostly not source: measured on one machine, 60.0 GB of 90 GB was
regenerable output in `build/`, `target/`, `.dart_tool/` and `node_modules/`.

```
distrodeck reclaim                            # report on ~/Projects
distrodeck reclaim ~/work --list 10           # a different workspace, name the ten largest
distrodeck reclaim --older-than 30            # only what has not been touched in a month
distrodeck reclaim --older-than 30 --apply    # and reclaim it
```

Options:
- `--apply`: actually delete. Without it nothing is removed, which is the
  reverse of `cleanup-kernels` on purpose: this can remove tens of gigabytes
  across a hundred repositories in a second, so the safe direction is the
  default and acting is the flag.
- `--older-than DAYS`: only directories untouched for this many days. Protects
  work in progress. A negative value is refused. On the measured machine the
  default 60.0 GB falls to 46.4 GB at seven days and 29.6 GB at
  thirty. A tree's age is the newest mtime of **anything inside it, file or
  directory** -- so creating or removing even an empty directory in a build tree
  makes it recent. That is deliberate: it is activity, and the mistake it causes
  is refusing to delete something, not deleting something in use. A directory is
  only absorbed into an ancestor that itself survives this filter, so an old
  `build/node_modules` is still offered when `build` is rejected for something
  fresh elsewhere inside it.
- `--list N`: also list the N largest candidates individually.
- `--include-environments`: also Python virtualenvs. Off by default because
  restoring one needs a network and a `pip install`, and a virtualenv holding
  large machine-learning wheels is a multi-gigabyte download -- which is exactly
  the situation where somebody most wants the disk back.
- `--any-directory`: offer matching directories even when Git does not consider
  them ignored. Off by default, and the most important default here:

What it will not offer, ever -- no flag lifts these:
- a directory containing a repository. An outer repository can ignore `build/`
  while `build/vendor` is itself a clone, and deleting it would take that
  history. A `.git` file counts as well as a directory, since that is how
  submodules and linked worktrees appear, and a bare clone counts too: it has no
  `.git` entry at all, only `HEAD`, `objects` and `refs` at its root.
- anything inside a bare repository, and any scan rooted inside `.git` or inside a
  bare repository -- at its root or below it. A loose ref is a path: a branch called
  `build/main` is a directory named `build` under `refs/heads`, so deleting it would
  delete the branch. The workspace's own ancestors are checked before the scan
  begins, and again immediately before each deletion, because `git init --bare` in
  an existing directory is enough to turn an ancestor into one mid-scan. A workspace
  of `repo.git/refs/heads` never walks past the entries that identify the repository
  above it, and those entries are probed by path rather than listed, so a repository
  that allows directories to be traversed but not listed is still recognised.
  Refused whatever the flags say, since a repository's own storage is not build
  output.
- a symlink, however it is named. `os.walk` lists a symlink to a directory among
  directories, so one called `build` was offered and measured as its target --
  space that removing the link would not free. Removing it would free only the
  link, and somebody made it deliberately.
- a directory with a filesystem mounted inside it, or which is itself a mount
  point. `rm -r` walks through a mount like any other directory, so a bind mount,
  an NFS share or a mounted image inside an ignored `build/` would have its
  *contents* deleted -- data no build reproduces, whose space does not return to
  this disk anyway. Three signals: a device number that changes inside the tree, a
  device number differing from the parent's (which is the only way to notice that
  the candidate is a mount point itself -- everything under a mount is one device),
  and the mount table, which is what catches a bind mount of the *same* filesystem.
  Only the last needs `/proc`, so where it cannot be read the same-device bind
  mount is the one case that goes undetected. The first two are checked before the
  candidate is read at all, so a slow or dead mount is skipped rather than measured,
  and the scan stops at a device boundary rather than descending through one.
- a directory it could not read in full. A subtree the scan cannot enter is
  "could not look", not "looked and found nothing" -- it could hold a clone, and
  with `--older-than` it could hold the very file that says somebody is working
  in there. It is also a tree `rm` would abandon half-done, so it is refused
  whether or not a day count was given, and the skip is reported on stderr.

What it will not offer by default, where `--any-directory` is the flag that
lifts both:
- a directory the containing repository does not ignore. `build/` and `target/`
  are ordinary names for authored code, and being gitignored is the evidence
  that a directory is output rather than source. On the measured machine, 8 of
  101 `build/` directories were tracked or unignored.
- anything at all in a worktree where `git` could not be consulted. Both the
  ignore check and the index check must succeed, or nothing there is offered.

With `--apply`, a removal that fails is reported on stderr and the command exits
**nonzero** once every other candidate has been attempted -- one unreadable tree
does not cost the rest of the run, and a cron entry or CI step can tell that the
disk was not actually freed. A *skip* is not a failure: that is the pre-delete
re-check doing its job, and the exit status stays zero for it.

Reported sizes are **allocated blocks**, not apparent file length -- directories
  included, since each is an allocation of its own and a `node_modules` is mostly
  directories -- and
hard-linked content is excluded from the total and reported separately: removing
one name for an inode frees nothing while another survives, so the figure is a
floor rather than an estimate.

### upgrade

Run a distro upgrade. On Ubuntu this uses `do-release-upgrade`.
On Debian you must specify the target codename (or set `DISTRODECK_TARGET_CODENAME`).

```
distrodeck upgrade
distrodeck upgrade --cleanup-kernels
```

Options:
- `--target-codename CODE`: target codename for Debian upgrades
- `--cleanup-kernels`: clean old auto-installed kernels after a successful distro upgrade
- `--keep-kernels N`: previous kernel versions to keep when cleanup is enabled

### cleanup-kernels

Preview or remove old auto-installed apt kernels. The running kernel is never removed.

```
distrodeck cleanup-kernels --dry-run
distrodeck cleanup-kernels
```

Options:
- `--dry-run`: show packages that would be purged
- `--keep N`, `--keep-kernels N`: previous kernel versions to keep in addition to the running kernel

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

Run system and repository health diagnostics with severity levels and remediation hints.
On apt-based systems with many repositories, `doctor` can take longer because it performs a repository metadata probe.

```
distrodeck doctor
distrodeck doctor --verbose
distrodeck doctor --json
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
Includes git config files when present.

Includes distrodeck config files if present (user and system).

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

Install optional developer tools via a TUI checklist. Tools are organized by category.

```
distrodeck install-tools                      # opens TUI checklist
distrodeck install-tools --all                # installs the default non-interactive tool set
distrodeck install-tools --tools bat,eza,gh   # installs only these, no checklist
distrodeck install-tools --tools-file tools.txt
distrodeck install-tools --list-tools         # prints the catalog, one per line
```

Options:
- `--all`: install every tool without showing the checklist
- `--tools LIST`: install only `LIST` (comma or space separated; repeatable)
- `--tools-file PATH`: install the tools listed in `PATH`, one per line; blank
  lines and `#` comments are ignored, and `-` reads from stdin
- `--reconcile`: with `--tools`, also uninstall previously tracked tools that
  are not in the requested set
- `--list-tools`: print the tool catalog and exit

`--tools` and `--tools-file` are the noninteractive entry points for scripts and
external integrators. Unknown tool names are rejected with exit code 2 *before*
anything is installed, so a typo cannot half-configure a machine. Tools not in
the requested set are left alone unless `--reconcile` is passed: removing
software the caller never mentioned is not a safe default. Tracked state in
`~/.local/state/distrodeck/installed-tools.txt` is updated exactly as it is in
the interactive flow.

Exit codes: `0` success, `2` invalid usage (unknown option, unknown tool,
unreadable tools file).

`--all` skips tools that require downloaded installer confirmation or hosted account CLIs. To include those tools, run from an interactive terminal with `DISTRODECK_ALL_INCLUDE_OPT_IN_TOOLS=true`. The older `DISTRODECK_ALL_INCLUDE_REMOTE_SCRIPT_TOOLS=true` name is also accepted for compatibility.

**Features:**
- Tools are grouped by category with prefixes: `[Shell]`, `[Editor]`, `[System]`, `[Net]`, `[Backup]`, `[Dev]`, `[AI]`, `[Lang]`, `[DevOps]`, `[Util]`, `[App]`
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
| AI | aider, antigravity, claude-code, codex, copilot, cursor, gemini, kiro, ollama |
| Languages | go, java, node (24 LTS + nvm), php, ruby, rust |
| DevOps & Containers | ansible, docker, k9s, lazydocker, podman |
| Utilities | adb, dialog, flatpak, nala, ntfs-3g, wine |
| Apps | gimp, image-view, isoforge, nemo, rustdesk, streamcontroller |

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
- `rustdesk` - Open-source remote desktop and remote support (deb/rpm from
  upstream releases, Flatpak fallback)
- `node` - Installs Node 24 from the system/NodeSource repository *and* nvm
  (cloned at a pinned tag) with Node 24 and 22 available. `nvm use 22` and
  `nvm use 24` switch between them; 24 is the default alias. The system package
  keeps Node available to `sudo`, cron, and package dependencies, which never
  see `~/.nvm`. Open a new shell after installing before using nvm.
  Uninstalling `node` removes the system package and the shell wiring but
  leaves `~/.nvm` in place, since it holds versions and global packages
  distrodeck did not create.

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

### git-aliases

Manage recommended git aliases in your global git config.

```
distrodeck git-aliases set
distrodeck git-aliases unset
distrodeck git-aliases show
```

Recommended aliases (all prefixed with `d`):
- `git df`  -> `fetch`
- `git dp`  -> `pull`
- `git dfp` -> `fetch --all; pull --all`
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
[apt_sources]  # non-PPA apt sources (excluding official repos)
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
