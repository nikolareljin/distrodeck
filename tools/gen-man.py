#!/usr/bin/env python3
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Tuple


def run(cmd, env=None):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, env=env)


def parse_commands(help_text: str) -> List[Tuple[str, str]]:
    lines = help_text.splitlines()
    commands = []
    in_section = False
    for line in lines:
        if line.strip() in {"positional arguments:", "commands:"}:
            in_section = True
            continue
        if in_section and not line.strip():
            break
        if in_section and line.startswith("                        "):
            if commands:
                name, desc = commands[-1]
                commands[-1] = (name, f"{desc} {line.strip()}".strip())
            continue
        if in_section and not line.startswith("    "):
            continue
        if in_section:
            parts = line.strip().split(None, 1)
            if not parts:
                continue
            name = parts[0]
            desc = parts[1] if len(parts) > 1 else ""
            if name.startswith("{"):
                continue
            commands.append((name, desc))
    return commands


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    script = repo_root / "distrodeck"
    man_dir = repo_root / "docs" / "man"
    man_dir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    env["LC_ALL"] = "C"

    help_text = run([str(script), "--help"], env=env).stdout
    version = run([str(script), "--version"], env=env).stdout.strip()
    commands = parse_commands(help_text)

    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [
        f'.TH DISTRODECK 1 "{date}" "distrodeck {version}" "User Commands"',
        ".SH NAME",
        "distrodeck \\- Export and restore packages before distro upgrades.",
        ".SH SYNOPSIS",
        ".B distrodeck",
        "\\fIcommand\\fR [options]",
        ".SH DESCRIPTION",
        "distrodeck exports installed packages and sources, then re-installs them after a distro upgrade.",
        ".SH CONFIGURATION",
        "distrodeck reads optional config files from \\fI/etc/distrodeck/config.ini\\fR and \\fI$XDG_CONFIG_HOME/distrodeck/config.ini\\fR, or \\fI~/.config/distrodeck/config.ini\\fR when \\fIXDG_CONFIG_HOME\\fR is unset.",
        ".PP",
        "The \\fB[apt]\\fR section can define \\fIofficial_hosts_common\\fR, \\fIofficial_hosts_ubuntu\\fR, \\fIofficial_hosts_debian\\fR, or distro-specific \\fIofficial_hosts_<id>_override\\fR entries as comma-separated host lists.",
        ".PP",
        "See \\fIexamples/config.ini\\fR for a sample configuration.",
        ".SH COMMANDS",
    ]
    for name, desc in commands:
        lines.append(".TP")
        lines.append(f".B {name}")
        if desc:
            lines.append(desc)
    lines.extend(
        [
            ".SH GIT ALIAS HELP",
            "After running \\fBdistrodeck git-aliases set\\fR, run \\fBgit dhelp\\fR for a detailed reference of every distrodeck Git alias.",
            ".PP",
            "The interactive output uses color when supported; set \\fBNO_COLOR\\fR or pipe it for plain text.",
        ]
    )
    lines.append(".SH COMMAND HELP")
    for name, _ in commands:
        cmd_help = run([str(script), name, "--help"], env=env).stdout
        lines.append(f".SS {name}")
        lines.append(".nf")
        lines.extend(cmd_help.splitlines())
        lines.append(".fi")

    man_path = man_dir / "distrodeck.1"
    man_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {man_path}")


if __name__ == "__main__":
    main()
