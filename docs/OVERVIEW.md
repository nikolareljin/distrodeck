# What distrodeck does

Distrodeck is a Python command-line tool and optional terminal UI for preparing a Linux machine for an operating-system upgrade, then rebuilding the installed software and selected local state afterward. It creates a plain-text snapshot, lets you compare that snapshot with the current machine, and restores only after you explicitly request an apply operation.

## Snapshot and restore

An export records the software sources and installed applications that define a machine:

- manually installed and held apt packages;
- Launchpad PPAs and non-official apt sources;
- Snap packages, including channel and classic-confinement metadata;
- Flatpak applications and their remotes;
- native package lists for pacman, dnf, and zypper;
- AppImages found in standard application directories.

An export can additionally include pipx, npm global, Composer global, NuGet global, Cargo, Ruby, and Go user tools; enabled and active systemd services; configuration-directory archives; and selected individual configuration files. The export format is readable plain text, so it can be reviewed, versioned, or stored beside a release-upgrade backup.

`distrodeck import` is a dry run unless `--apply` is provided. The dry run shows the required changes before installation. Applied imports create a backup beside the supplied export and offer a revert if a restore fails. You can restore specific sections only, re-enable recorded services, restore optional configuration data, or reconcile extra Snap/Flatpak applications when that is explicitly requested.

## Compare system drift

`distrodeck diff` compares a snapshot to the current system without changing packages, sources, or files. It reports entries that are missing from the machine and entries that are extra relative to the snapshot. Use `--detailed` for individual entries, `--json` for a stable machine-readable report, and `--exit-code` when a nonzero result should signal drift to a script or CI job.

## Upgrade, maintenance, and recovery

Distrodeck can maintain a machine in addition to capturing it:

- `update` updates installed packages through the available package manager and can clean old automatically installed kernels after success.
- `upgrade` runs Ubuntu release upgrades; Debian upgrades require an explicit target codename. Other platforms retain package snapshot/restore support but do not receive automated release-upgrade orchestration.
- `security` applies security updates when the platform supports them.
- `doctor` reports system and repository health with severity and remediation hints; `preflight` checks disk capacity, OS support, connectivity, and reboot state.
- `repo-repair` detects apt repository errors, can disable broken sources, and refreshes missing keys.

## Workstation setup utilities

The terminal UI also exposes tools that are useful before or after a migration:

- `install-tools` offers a categorized checklist of shell, editor, monitoring, networking, developer, language, DevOps, desktop, and utility software. `--tools` and `--tools-file` make the same installer scriptable, while `--reconcile` is required before removing previously tracked tools outside the requested set.
- `sysinfo` presents CPU, GPU, memory, storage, network, public-IP, port, and attached-device information, plus a speed test when available.
- `net-tools` opens a menu for installed networking utilities.
- `config-edit` offers a terminal editor for common system and repository configuration files.
- The TUI's **Automate** action runs `ansible-pull` with selected playbook and inventory inputs.
- `git-status` configures a Git-aware shell prompt, while `git-aliases` manages optional global Git aliases.

## Typical workflow

```bash
# Snapshot installed software and sources before upgrading.
distrodeck export --output pre-upgrade.txt

# Include optional personal tools and service state when needed.
distrodeck export --output pre-upgrade.txt --include-user-tools --include-services

# Inspect differences without modifying the system.
distrodeck diff --input pre-upgrade.txt --detailed

# Upgrade, then preview the recovery plan before applying it.
distrodeck upgrade
distrodeck import --input pre-upgrade.txt
distrodeck import --input pre-upgrade.txt --apply --update-sources
```

Default exports are saved under `~/.local/state/distrodeck/exports`, or `$XDG_STATE_HOME/distrodeck/exports` when that environment variable is set. Commands that change packages, system sources, services, or system configuration use the normal privilege-elevation flow.

## Platform support

| Platform | Supported capability |
| --- | --- |
| Ubuntu | Full workflow: apt, PPAs, `do-release-upgrade`, Snap, and Flatpak |
| Debian | apt/Snap/Flatpak plus target-codename upgrade workflow |
| Other Debian-based systems | apt, Snap, and Flatpak snapshots; no automated release upgrade |
| Fedora/RHEL | dnf package export/import; no automated distro upgrade |
| Arch | pacman package export/import; no automated distro upgrade |
| openSUSE | zypper package export/import; no automated distro upgrade |
