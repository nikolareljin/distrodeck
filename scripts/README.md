# Scripts

This directory hosts local helper scripts and the `script-helpers` submodule.

Build helpers:
- `scripts/build-deb.sh`
- `scripts/build-fpm.sh`
- `scripts/build-deb-artifacts.sh` (delegates to `scripts/script-helpers/scripts/build_deb_artifacts.sh`)
- `scripts/ppa-upload.sh` (delegates to `scripts/script-helpers/scripts/ppa_upload.sh`)

Installers:
- `scripts/install-tools-tui.sh` (TUI checklist for common tools, supports `--all`)

For usage and project documentation, see `docs/USAGE.md` and the rest of `docs/`.
