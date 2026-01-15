# Changelog

This project follows Keep a Changelog and Semantic Versioning.

## [0.2.0]

### Added
- TUI main menu when running `distrodeck` with no arguments.
- TUI-driven flows for export/import/update/upgrade/security/doctor/install-tools.
- Install-tools enhancements: grouped options, installed detection, `--all`, lazygit/lazygit-gm fallback, lazydocker fallback install.
- Packaging support for DEB/PPA/RPM/Homebrew with CI integration.

### Changed
- Security updates now prefer `unattended-upgrade` and fall back safely when unavailable.
- TUI update/upgrade/security now fall back to CLI when interactive output is needed.
- TUI install-tools opens the checklist directly; removed the “install all” prompt from the TUI.
- Added Ctrl+C handler to cleanly exit the TUI.
- TUI import uses a file picker for the import file.
- `install-tools` supports `--all` in CLI mode and adds PHP/Composer to the list.
- Export can optionally include pipx, npm globals, composer globals, nuget globals, cargo installs, gem installs, and Go binaries.
- Export shows a progress gauge in the TUI.
- Export/import can optionally include config snapshots for key system directories.
- Export can optionally include enabled/active systemd services; import can restore enablement.
- Import supports selective sections, dry-run diffs, and optional snap/flatpak cleanup.
- Export/import can optionally include key config files (hosts/fstab/ssh config).
- Export uses host/timestamp filenames by default and logs config snapshot archive paths.
- Added preflight checks (disk, OS, connectivity, reboot requirement).
- Added per-run logs and a `logs` command for viewing them.
- Added a `sysinfo` command with full system diagnostics (CPU/GPU/memory/storage/network/USB/ports/public IP/speed where available).

## [0.1.0]

### Added
- Export/import of installed packages, PPAs, sources, snaps, flatpaks, and AppImages.
- Update, upgrade, security, and doctor CLI commands for Ubuntu/Debian-first flows.
- Documentation and man page scaffolding.
