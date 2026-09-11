# Changelog

This project follows Keep a Changelog and Semantic Versioning.

## [Unreleased]


### Added
- **`distrodeck reclaim`: disk that a build can make again.** A workspace of
  development checkouts is mostly not source. Measured on one machine, 90 GB
  across roughly a hundred repositories: **33.8 GB of `build/`, 15.5 GB of Rust
  `target/`, 5.2 GB of `.dart_tool/`, 3.1 GB of `node_modules/`** -- 59.5 GB in
  total, about two thirds of the workspace, none of it authored by anybody.
  Reports by default and deletes only with `--apply`. That is the reverse of its
  sibling `cleanup-kernels`, deliberately: this command can remove tens of
  gigabytes across a hundred repositories in a second, so the safe direction is
  the default and acting is the flag.
  The distinction it is built around is **regenerable versus
  reproducible-at-a-cost**. A `target/` is the output of a command that runs
  again offline in minutes. A virtualenv is also "rebuildable", and rebuilding
  one holding torch and whisper is a multi-gigabyte download that fails entirely
  without a network -- so virtualenvs are behind `--include-environments` rather
  than offered as free.
  `--older-than DAYS` protects work in progress. Measured on the same machine and
  the same default set as the 59.5 GB above: **59.5 GB falls to 46.1 GB at seven
  days and 29.4 GB at thirty**, the difference being projects actively being
  built. (`--include-environments` is the flag that raises the baseline, to
  69.0 GB -- an earlier draft of this entry quoted figures from that wider set
  against the default total, which cannot be compared.)
  A candidate must be **ignored by the Git repository that contains it**. The
  name is not evidence: `build/` and `target/` are ordinary names for authored
  code, and on the measured machine 8 of 101 `build/` directories were tracked
  or unignored -- including a `scripts/build` and a `src/.../build`. Git already
  knows which is which, because somebody wrote it in `.gitignore`. A directory
  outside any worktree is not offered either; `--any-directory` waives the
  requirement explicitly.

  A candidate that *contains* a repository is refused too: an outer repository
  can ignore `build/` while `build/vendor` is itself a clone, and filtering
  `.git` out of the walk is the opposite containment -- it would not have saved
  that history from `rmtree`. A `.git` file counts as well as a directory, since
  that is how submodules and linked worktrees appear, and a **bare** repository
  counts as well: `git clone --bare` has no `.git` entry at all, which made the
  kind of repository somebody vendors into a build directory invisible to the
  check meant to protect it.

  A directory with **a filesystem mounted inside it is refused**, as is one that
  is itself a mount point. `shutil.rmtree` walks through a mount point like any
  other directory, so a bind mount, an NFS share or a mounted image inside an
  ignored `build/` would have had its contents deleted -- data that is not the
  candidate's to free, that no build reproduces, and whose space does not come
  back to this disk. Three signals, because each sees something the others cannot:
  a change of device number **inside** the tree catches a filesystem mounted under
  the candidate; a device number differing from the **parent's** catches the
  candidate being a mount point itself, which nothing inside it can see because
  everything under a mount is one device; and `/proc/self/mountinfo` catches a bind
  mount of the *same* filesystem, whose device number is its parent's and which
  `os.path.ismount` cannot see either. Only the third needs `/proc`, so an
  unreadable mount table loses the same-device bind mount case and nothing else --
  refusing everything instead would make the command useless in a container. A path
  whose own device cannot be read is refused. The table is re-read immediately
  before each deletion, so a mount that appears during a minutes-long scan is still
  caught.

  Deciding which repository a candidate belongs to no longer costs a subprocess
  per candidate. `git rev-parse --show-toplevel` ran once per match: on the
  measured workspace that is **8,523 git processes for 8,373 candidates across 75
  repositories, now 225** -- three per repository, which is what batching the
  ignore and index questions was for in the first place. Deciding which repository
  each candidate belonged to had cost 37 times more than the questions it was
  batching. Whole-workspace scan: 40.3s to 29.6s. The directory chain
  is climbed with `stat` until a `.git` entry appears, `git` confirms that one
  answer, and every directory climbed past is cached with it. Still `git` that
  decides, because `GIT_DIR`, `.git` files for submodules and linked worktrees and
  `core.worktree` all mean the first `.git` on the way up is evidence rather than
  proof; and a tree with no `.git` anywhere above it is refused without asking,
  which costs a directory that is not reclaimed rather than one deleted unchecked.

  A tree it **could not read in full is refused**, not treated as empty. Both
  walks over a candidate -- the nested-repository search and the measurement --
  used to discard `scandir` failures, which turned "could not look" into "looked
  and found nothing": one unreadable subtree is enough to hide a clone, and under
  `--older-than` it is enough to hide the fresh file whose whole job is to say
  somebody is working in there, leaving the tree reading as stale for weeks. It
  is also a tree `rmtree` would abandon half-done, so the refusal does not depend
  on a day count being given, and the skipped path is named on stderr.

  Every one of those questions is asked **again immediately before each
  deletion**, and any refusal or unanswered git call skips the directory.
  Everything learned during a scan is minutes old by the time deletion starts on
  a large workspace: a build can resume, a file can be force-added, a clone can
  appear -- and `--older-than`, whose whole purpose is to protect work in
  progress, was evaluated before that work restarted.

  With `--apply` a failed removal now **exits nonzero**, after every remaining
  candidate has been attempted. It printed `could not remove ...` and exited 0
  before, so anything scripting this -- a cron entry, a CI step -- was told the
  disk had been freed when it had not. A *skip* stays a success: it is the
  pre-delete re-check working, and counting it as an error would make a caller
  choose between reading the exit status and keeping the protection.

  Matching directories are **not pruned before eligibility is known**. An
  authored `scripts/build/` can hold an ignored `target/`; pruning at the match
  rejected the outer candidate while never visiting the reclaimable inner one.
  Containment de-duplication happens **after** the age filter for the same
  reason: a candidate absorbs what is inside it only if it is itself going to be
  deleted, so an old `build/node_modules` is still offered when `build` is
  rejected for a fresh file elsewhere inside it. The cost is that a nested
  candidate is traversed as well as its ancestor -- tens of seconds rather than a
  few on a hundred-repository workspace, and the alternative is reporting less
  than is reclaimable.

  `--apply` reports **the size it measures at deletion**, not the one the scan
  printed. The pre-delete re-check already walks the tree, so it hands its
  measurement back rather than the total being accumulated from figures that can
  be minutes old -- a `target/` that kept compiling in between was not the size
  it was found at.

  Age comes from the **newest file anywhere inside**, not the directory's own
  mtime, which changes only when its immediate entries do -- so an actively
  compiling `target/` whose root entry is weeks old is no longer mistaken for
  stale. Size is **allocated blocks**, not apparent length, and **hard-linked
  content is excluded rather than counted once**: removing one name for an inode
  frees nothing while another survives, and proving every name is inside the
  deletion set would mean indexing the filesystem. 3.3 GB fell out of the
  measured total that way, and the command now says so -- the figure is a floor.
  That excluded figure is de-duplicated by inode, and the ledger records a
  candidate only **after** it survives every filter: a tree the age filter
  rejects used to consume the inodes it shared on its way out, so an accepted
  candidate sharing them reported them as already counted and they vanished from
  every figure.
  `--older-than` and `--list` both refuse a negative value; the first would put
  the cutoff in the future and disable the protection, the second would quietly
  print every entry but the smallest.

  It never enters `.git` -- a repository's history is not build output however
  large it grows. It does **not** prune matched trees from the walk: eligibility
  cannot be known without asking Git, so the scan descends through them and
  de-duplicates accepted candidates afterwards, which keeps a `node_modules`
  inside an accepted `build` counted once. Correctness over a single pass.
- `distrodeck diff --input FILE` compares an export file against the current
  system without changing anything. Reports `missing` (in the export, not
  installed here) and `extra` (installed here, not in the export) per section,
  with `--detailed`, `--sections`, `--json` (schema version 1), and
  `--exit-code` for CI-style drift checks. Available from the TUI as
  "Packages: Diff export vs current system". Output is sorted, so repeated runs
  on unchanged inputs are byte-identical.
- `install-tools` gained a noninteractive selected-tool mode for scripts and
  external integrators: `--tools LIST`, `--tools-file PATH` (`-` reads stdin),
  `--list-tools`, and `--reconcile`. Unknown tools are rejected with exit code
  2 before anything is installed, and tools outside the requested set are left
  alone unless `--reconcile` is passed.
- RustDesk (open-source remote desktop) joins the Apps category, installed from
  upstream deb/rpm/pkg.tar.zst releases with a Flatpak fallback.
- `git dlr` alias lists the three most recently updated branches and the three
  most recent tags, newest first. Repo-local and offline.
- Selecting the `node` tool now also installs nvm, cloned at a pinned tag, with
  Node 24 and 22 installed and 24 as the default alias, so versions can be
  switched per shell.
- The PR CI gate now runs the test suite (pytest plus the installer argument
  tests); previously only `py_compile` ran, so tests never gated a PR.
### Changed
- `burn-iso` was renamed to `iso-forge` on GitHub. The IsoForge installer now
  looks for `~/Projects/iso-forge` first and still accepts an older
  `~/Projects/burn-iso` checkout, and the tool-suite Pages links point at the
  new site. The `ISOFORGE_*` and legacy `BURN_ISO_*` environment overrides are
  unchanged, as is the `isoforge` package name.

## [0.10.2]

### Changed
- Released the current packaging CI fixes as a patch version.

## [0.10.1]

### Fixed
- Prevented recursive Debian and RPM package builds in CI.


## [0.9.0]

### Changed
- Default Node.js major installed by the `node` tool is now 24. Node 20 reached
  end-of-life in April 2026, so the previous default installed an unsupported
  runtime.
- Refreshed the fallback versions used when the GitHub API is unavailable or
  rate-limited: lazygit 0.44.1 -> 0.64.1, k9s v0.50.18 -> v0.51.0, glow 2.1.1 ->
  3.0.0, delta 0.18.2 -> 0.19.2. These are the versions that get installed on a
  rate-limited or offline run, so stale pins silently installed old binaries.
- The `--all` tool selection is derived from the tool catalog instead of a
  duplicated hardcoded list that had already drifted from it.
- The openSUSE Node.js branch derives its package name from the requested major
  rather than hardcoding one branch per version.

### Fixed
- The import dry-run now reports the `pacman`, `dnf`, and `zypper` sections. It
  collected them but never printed them, so package differences on those
  distros were invisible in a dry run.

## [0.8.1]

### Fixed
- `upgrade` no longer crashes with a Python traceback when `do-release-upgrade`
  exits non-zero. On Ubuntu it now pre-checks for an available release and, when
  none is on offer (exit code 1, the normal case under the default `Prompt=lts`
  policy), reports "No new Ubuntu release is available" and exits cleanly instead
  of running a useless pre-upgrade export. An unexpected probe error (any other
  non-zero exit code, e.g. a transient network failure) is surfaced as a warning
  and the upgrade is still attempted rather than being masked as "nothing to
  upgrade". A genuine `do-release-upgrade` failure is reported as a warning with
  the kept export path rather than an unhandled exception.

## [0.8.0]

### Added
- Added an `About` entry to the TUI with GitHub and LinkedIn profile links.
- Added `cleanup-kernels` to preview or purge old auto-installed apt kernels while keeping the running kernel plus one previous version by default.
- Added opt-in old-kernel cleanup after successful `update` and `upgrade` runs in both CLI and TUI flows.
- Added install-tools options for aider, OpenAI Codex CLI, GitHub Copilot CLI, Claude Code, Gemini CLI, Ollama, Antigravity, Cursor, and Kiro.

### Changed
- `install-tools` now includes a dedicated AI tools category and shared helpers for npm/script/zip based installers.
- `image-view` installation now fails visibly when its required Cargo install command fails.

## [0.7.1]

### Fixed
- `install-tools` now resolves `script-helpers` from installed package locations (`/usr/local/share`, `/usr/share`, `/usr/lib`) and a parent-relative fallback, so running from an installed directory no longer incorrectly requires `./scripts/update.sh`.

## [0.7.0]

### Added
- Added `distrodeck doctor --json` for machine-readable diagnostics in automation workflows.
- Added repository health checks to `doctor`, including APT host resolution and metadata/key validation probes.

### Changed
- `doctor` now emits structured severity checks (`ok`, `warn`, `blocker`) with remediation hints.
- `doctor` now exits non-zero when blocker-level issues are detected.
- `doctor` now reports disk, network, package-manager, reboot, and repository checks in a consolidated summary.
- APT deb822 `.sources` handling now skips stanzas with `Enabled: no|false|0|off`, affecting `doctor` repository checks and `export_apt_sources` / `active_apt_sources` flows.

## [0.6.1]

### Added
- New `git do` alias to open the remote origin URL in the default browser; converts SSH remote URLs to HTTPS and strips `.git` suffix automatically.

## [0.6.0]

### Added
- New `git dis` alias to list repository issues via `gh` with number, title, and state.
- New `git dprs` alias to list repository pull requests via `gh` with number, title, and state.
- New `git dup` alias to push the current branch and set upstream to `origin/<current-branch>`.

## [0.5.0]

### Added
- New `git-aliases` command (and TUI action) to set/unset/show recommended git aliases.
- Git aliases now include simplified `d*` shortcuts for common git operations, plus `dhelp` to list them.
- Config editor now includes git config files when present.
- Debian upgrade support via `apt-get full-upgrade` with a target codename parameter.
- Support for apt deb822 `.sources` files, including handling and conversion alongside traditional `deb` entries.
- New config system for customizing official repository hosts and related behavior.

### Changed
- TUI git-aliases flow now validates alias names against existing git commands.
- Debian packages now bundle the install-tools TUI and script-helpers so `distrodeck install-tools` works without git submodules on first run.
- `apt_sources` exports now exclude official distribution repository hosts; only non-official/custom APT sources are included in exports.
- CLI git-aliases now checks for conflicts with git commands and aborts with guidance to use the TUI.
- `git dfp` now runs `fetch --all; pull --all` to match docs.
- Debian upgrade warns on unexpected codename formats; cdrom sources are detected more robustly.
- Removed LazyDocker curl|bash fallback; only distro packages are used.

## [0.4.0]

### Added
- New `git-status` command (and TUI action) to enable/disable git status in the shell prompt.
- Prompt shows branch name plus compact status symbols: `≡` (up to date), `N↑` (ahead), `N↓` (behind), and `A↑B↓` (diverged).
- Dirty working tree indicator (`*`) for uncommitted changes.
- Auto-detection of bash/zsh/fish and safe prompt injection with automatic removal.
- Prompt color rules: branch name stays green; status color reflects state (green/yellow/red).
- Examples and legend added to README, USAGE, and man page.
- Import now creates an automatic backup of the sections being restored and offers a revert prompt on failure.
- New `clear-logs` command and TUI action to delete all previous logs.
- Action start/end entries added to logs for easier troubleshooting.
- Import shows section-level progress in the TUI with an indeterminate progress bar.
- Docker-based Ubuntu 24.04 test suite with automated CLI + TUI coverage.
- **Uninstall support for install-tools**: Unchecking a previously installed tool now prompts to uninstall it.
- **State tracking**: Tools installed via distrodeck are tracked in `~/.local/state/distrodeck/installed-tools.txt`.
- **18 new tools** in install-tools: bfg (git repo cleaner), gh (GitHub CLI), tldr (simplified man pages), bandwhich (bandwidth monitor), k9s (Kubernetes TUI), podman (container engine), tokei (code statistics), glow (markdown viewer), delta (git diff viewer), meld (visual diff/merge), ruby, flatpak, wine (Windows compatibility), tor (anonymous browsing), ntfs-3g (NTFS filesystem), streamcontroller (Stream Deck via Flatpak), gimp (image editor with plugins).
- **Reorganized tool categories** in the TUI with clear category prefixes (`[Shell]`, `[Editor]`, `[System]`, `[Net]`, `[Dev]`, `[Lang]`, `[DevOps]`, etc.) for easier navigation.

### Changed
- Install-tools TUI now offers 64 tools (up from 47), grouped by category.
- Node.js installation now uses NodeSource to install Node.js 20 LTS instead of distro default version.
- Tool installation errors no longer stop the entire process; failures are collected and reported at the end.
- git-status install now overwrites the generated script on each set, ensures executable permissions, and instructs users to reload the shell config.
- Export/import warnings and errors are captured in the per-run log file.
- TUI export uses an indeterminate progress bar with per-section status text.
- TUI logs view shows log contents instead of the log filename.
- `distrodeck logs` now prints to stdout instead of writing into the log file.
- Default exports/backups now go to the state exports directory instead of the repo root.

### Fixed
- Export progress dialog now renders reliably in TUI flows (no dialog flag errors).
- Suppressed missing config-dir warnings when the corresponding package manager is not installed.


## [0.3.0]

### Added
- Export can optionally include pipx, npm globals, composer globals, nuget globals, cargo installs, gem installs, and Go binaries.
- Export/import can optionally include config snapshots for key system directories.
- Export can optionally include enabled/active systemd services; import can restore enablement.
- Import supports selective sections, dry-run diffs, and optional snap/flatpak cleanup.
- Export/import can optionally include key config files (hosts/fstab/ssh config).
- Added preflight checks (disk, OS, connectivity, reboot requirement).
- Added per-run logs and a `logs` command for viewing them.
- Added a `sysinfo` command with full system diagnostics (CPU/GPU/memory/storage/network/USB/ports/public IP/speed where available).
- Added a global `--verbose` flag; doctor now shows detailed explanations and versions.
- Added a `config-edit` TUI for common system config files (nginx/apache/ssh/network/php).
- Added a `net-tools` TUI to run installed network tools with auto-detected networks.
- Added a TUI automation action that runs `ansible-pull` with URL/auth prompts.
- Added a `repo-repair` action to disable broken apt sources and refresh missing keys.
- Install-tools now offers Ansible and adb (Android Debug Bridge).
- Config editor now lists repository source files for quick editing.

### Changed
- Security updates now prefer `unattended-upgrade` and fall back safely when unavailable.
- TUI update/upgrade/security now fall back to CLI when interactive output is needed.
- TUI install-tools opens the checklist directly; removed the “install all” prompt from the TUI.
- Added Ctrl+C handler to cleanly exit the TUI.
- TUI import uses a file picker for the import file.
- `install-tools` supports `--all` in CLI mode and adds PHP/Composer to the list.
- Export shows a progress gauge in the TUI.
- Export uses host/timestamp filenames by default and logs config snapshot archive paths.
- Upgrade/import re-enable commented apt sources that still reference the previous codename.
- LazyGit install now prefers the LazyGit PPA on apt-based systems with multiple fallbacks.
- LazyDocker fallback install now uses the upstream Linux install script.
- CI packaging now relies on ci-helpers bootstrap to locate `script-helpers`.

## [0.2.0]

### Added
- TUI main menu when running `distrodeck` with no arguments.
- TUI-driven flows for export/import/update/upgrade/security/doctor/install-tools.
- Install-tools enhancements: grouped options, installed detection, `--all`, lazygit/lazygit-gm fallback, lazydocker fallback install.
- Packaging support for DEB/PPA/RPM/Homebrew with CI integration.

## [0.1.0]

### Added
- Export/import of installed packages, PPAs, sources, snaps, flatpaks, and AppImages.
- Update, upgrade, security, and doctor CLI commands for Ubuntu/Debian-first flows.
- Documentation and man page scaffolding.
