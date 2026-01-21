# Changelog

This project follows Keep a Changelog and Semantic Versioning.

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

### Changed
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
