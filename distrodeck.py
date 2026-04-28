#!/usr/bin/env python3
import argparse
import base64
import configparser
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import shutil
from functools import lru_cache
from datetime import datetime, timezone
from pathlib import Path
from glob import glob
from shutil import get_terminal_size
from typing import Dict, List, Optional, Set, Tuple
from urllib.parse import urlparse

VERSION = "0.8.0"
SCRIPT_FILE = Path(__file__).resolve()


def _runtime_share_root(script_path: Path) -> Optional[Path]:
    # Installed and dist layouts place distrodeck.py under <prefix>/bin.
    if script_path.parent.name == "bin":
        return script_path.parent.parent / "share" / "distrodeck"
    return None


runtime_share_root = _runtime_share_root(SCRIPT_FILE)
version_candidates = []
if runtime_share_root is not None:
    # Installed/dist layout should prefer the share-root VERSION.
    version_candidates.append(runtime_share_root / "VERSION")
else:
    # Source-tree layout uses VERSION adjacent to distrodeck.py.
    version_candidates.append(SCRIPT_FILE.with_name("VERSION"))
version_candidates.extend(
    [
        Path("/usr/local/share/distrodeck/VERSION"),
        Path("/usr/share/distrodeck/VERSION"),
    ]
)
for path in version_candidates:
    if path.exists():
        try:
            file_version = path.read_text(encoding="utf-8").strip()
        except OSError:
            file_version = ""
        if file_version:
            VERSION = file_version
        break
DEFAULT_EXPORT_FILE = "distrodeck-export.txt"
LOG_PATH: Optional[Path] = None
VERBOSE = False

OFFICIAL_APT_HOSTS = {
    "ubuntu": {
        "archive.ubuntu.com",
        "security.ubuntu.com",
        "ports.ubuntu.com",
        "old-releases.ubuntu.com",
        "esm.ubuntu.com",
        "esm-infra.ubuntu.com",
        "esm-apps.ubuntu.com",
    },
    "debian": {
        "deb.debian.org",
        "security.debian.org",
        "ftp.debian.org",
        "archive.debian.org",
        "cdn-fastly.deb.debian.org",
        "snapshot.debian.org",
    },
}
DEBIAN_CODENAME_PATTERN = re.compile(r"[a-z]+")
MAX_ALIAS_NAME_ATTEMPTS = 3
MAX_ALIAS_GENERATION_ATTEMPTS = 100
DOCTOR_DNS_TIMEOUT_SECONDS = 5
DOCTOR_REPO_METADATA_TIMEOUT_SECONDS = 120
KERNEL_PACKAGE_PREFIXES = (
    "linux-image-",
    "linux-image-unsigned-",
    "linux-headers-",
    "linux-modules-",
    "linux-modules-extra-",
)


def require_python_version() -> None:
    if sys.version_info >= (3, 8):
        return
    os_id = get_os_id()
    hints = {
        "ubuntu": "sudo apt-get update && sudo apt-get install -y python3",
        "debian": "sudo apt-get update && sudo apt-get install -y python3",
        "fedora": "sudo dnf install -y python3",
        "rhel": "sudo dnf install -y python3",
        "centos": "sudo dnf install -y python3",
        "arch": "sudo pacman -S --noconfirm python",
        "manjaro": "sudo pacman -S --noconfirm python",
        "opensuse": "sudo zypper install -y python3",
        "opensuse-leap": "sudo zypper install -y python3",
        "opensuse-tumbleweed": "sudo zypper install -y python3",
    }
    hint = hints.get(os_id, "Install Python 3.8+ using your package manager.")
    fail(
        "Python 3.8+ is required.\n"
        f"Detected: {sys.version.split()[0]}\n"
        f"Upgrade: {hint}"
    )


def log(message: str) -> None:
    write_log("info", message)
    print(message)


def warn(message: str) -> None:
    write_log("warn", message)
    print(f"warning: {message}", file=sys.stderr)


def fail(message: str) -> None:
    write_log("error", message)
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def config_paths() -> List[Path]:
    paths = []
    paths.append(Path("/etc/distrodeck/config.ini"))
    config_home = os.getenv("XDG_CONFIG_HOME")
    if config_home:
        paths.append(Path(config_home) / "distrodeck" / "config.ini")
    else:
        paths.append(Path.home() / ".config" / "distrodeck" / "config.ini")
    return paths


@lru_cache(maxsize=1)
def load_config() -> configparser.ConfigParser:
    cfg = configparser.ConfigParser()
    for path in config_paths():
        try:
            if path.exists():
                cfg.read(path, encoding="utf-8")
        except (OSError, UnicodeDecodeError, configparser.Error) as exc:
            if path.exists():
                warn(f"Failed to read config file '{path}': {exc}")
            continue
    return cfg


def parse_csv_list(value: Optional[str]) -> List[str]:
    """Parse comma-delimited lists (whitespace around commas is ignored)."""
    if not value:
        return []
    items: List[str] = []
    for chunk in value.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        items.append(chunk)
    return items


def get_official_apt_hosts(os_id: str) -> Set[str]:
    default_hosts = set(OFFICIAL_APT_HOSTS.get(os_id, set()))
    cfg = load_config()
    if not cfg.has_section("apt"):
        return default_hosts
    override_key = f"official_hosts_{os_id}_override"
    if cfg.has_option("apt", override_key):
        override = {item.lower() for item in parse_csv_list(cfg.get("apt", override_key))}
        return override
    combined = set(default_hosts)
    common = {item.lower() for item in parse_csv_list(cfg.get("apt", "official_hosts_common", fallback=""))}
    specific = {item.lower() for item in parse_csv_list(cfg.get("apt", f"official_hosts_{os_id}", fallback=""))}
    combined.update(common)
    combined.update(specific)
    return combined


def run(
    cmd, check=True, capture_output=False, text=True, input_text=None, env=None, **kwargs
):
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture_output,
        text=text,
        input=input_text,
        env=env,
        **kwargs,
    )


def run_logged(
    cmd,
    title: str,
    check: bool = False,
    echo: bool = False,
    input_text: Optional[str] = None,
    env: Optional[dict] = None,
) -> subprocess.CompletedProcess:
    result = run(
        cmd,
        check=False,
        capture_output=True,
        input_text=input_text,
        env=env,
    )
    stderr = (result.stderr or "").strip()
    stdout = (result.stdout or "").strip()
    if stderr:
        write_log("warn", f"{title} stderr:\n{stderr}")
    if result.returncode != 0:
        details = stderr or stdout or "no output"
        write_log("error", f"{title} failed (exit {result.returncode}):\n{details}")
        if check:
            raise subprocess.CalledProcessError(
                result.returncode, cmd, output=result.stdout, stderr=result.stderr
            )
    if echo:
        if stdout:
            print(stdout)
        if stderr:
            print(stderr, file=sys.stderr)
    return result


def run_warn(cmd, title: str) -> subprocess.CompletedProcess:
    result = run(cmd, check=False, capture_output=True)
    if result.returncode != 0:
        details = (result.stderr or result.stdout or "").strip()
        if details:
            warn(f"{title} failed:\n{details}")
        else:
            warn(f"{title} failed.")
    return result


def run_warn_live(cmd, title: str) -> subprocess.CompletedProcess:
    if in_dialog_mode():
        write_log("info", f"{title}...")
        result = run(cmd, check=False)
        if result.returncode != 0:
            write_log("warn", f"{title} failed.")
        return result
    log(f"{title}...")
    result = run(cmd, check=False)
    if result.returncode != 0:
        warn(f"{title} failed.")
    return result


def get_log_dir() -> Path:
    state_home = os.getenv("XDG_STATE_HOME")
    if state_home:
        base = Path(state_home)
    else:
        base = Path.home() / ".local" / "state"
    log_dir = base / "distrodeck" / "logs"
    try:
        log_dir.mkdir(parents=True, exist_ok=True)
        return log_dir
    except OSError:
        fallback = Path("/tmp") / "distrodeck-logs"
        fallback.mkdir(parents=True, exist_ok=True)
    return fallback


def get_export_dir() -> Path:
    state_home = os.getenv("XDG_STATE_HOME")
    if state_home:
        base = Path(state_home)
    else:
        base = Path.home() / ".local" / "state"
    export_dir = base / "distrodeck" / "exports"
    try:
        export_dir.mkdir(parents=True, exist_ok=True)
        return export_dir
    except OSError:
        fallback = Path("/tmp") / "distrodeck-exports"
        fallback.mkdir(parents=True, exist_ok=True)
        return fallback


def init_logging() -> None:
    global LOG_PATH
    log_dir = get_log_dir()
    hostname = socket.gethostname().split(".")[0]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    LOG_PATH = log_dir / f"distrodeck-{hostname}-{stamp}.log"
    LOG_PATH.write_text(
        f"distrodeck log {stamp} host={hostname}\n",
        encoding="utf-8",
    )


def write_log(level: str, message: str) -> None:
    if not LOG_PATH:
        return
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(f"{stamp} [{level}] {message}\n")


def log_action_start(name: str) -> None:
    write_log("info", f"action start: {name}")


def log_action_end(name: str, status: str = "ok") -> None:
    write_log("info", f"action end: {name} status={status}")


def cmd_exists(name: str) -> bool:
    return subprocess.call(
        ["bash", "-lc", f"command -v {name} >/dev/null 2>&1"]
    ) == 0


@lru_cache(maxsize=1)
def git_command_names() -> Set[str]:
    if not cmd_exists("git"):
        return set()
    result = run(
        ["git", "--list-cmds=main,others"],
        check=False,
        capture_output=True,
    )
    names: Set[str] = set()
    if result.returncode == 0 and result.stdout:
        for token in result.stdout.split():
            names.add(token.strip())
    if names:
        return names
    result = run(["git", "help", "-a"], check=False, capture_output=True)
    if result.returncode != 0:
        return names
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.splitlines():
        if line.startswith("  "):
            for token in line.strip().split():
                if token and token[0].isalnum():
                    names.add(token)
    return names


def require_dialog() -> None:
    if not cmd_exists("dialog"):
        fail("dialog not found. Install it or run distrodeck with CLI arguments.")


def detect_pkg_mgr() -> str:
    if cmd_exists("apt-get"):
        return "apt"
    if cmd_exists("dnf"):
        return "dnf"
    if cmd_exists("pacman"):
        return "pacman"
    if cmd_exists("zypper"):
        return "zypper"
    return "unknown"


def install_dialog_cli() -> bool:
    mgr = detect_pkg_mgr()
    if mgr == "unknown":
        warn("No supported package manager found to install dialog.")
        return False
    if mgr == "apt":
        run_warn(["sudo", "apt-get", "update"], "apt-get update")
        result = run_warn(["sudo", "apt-get", "install", "-y", "dialog"], "apt-get install dialog")
        return result.returncode == 0
    if mgr == "dnf":
        result = run_warn(["sudo", "dnf", "install", "-y", "dialog"], "dnf install dialog")
        return result.returncode == 0
    if mgr == "pacman":
        result = run_warn(["sudo", "pacman", "-S", "--noconfirm", "dialog"], "pacman install dialog")
        return result.returncode == 0
    if mgr == "zypper":
        result = run_warn(["sudo", "zypper", "install", "-y", "dialog"], "zypper install dialog")
        return result.returncode == 0
    return False


def dialog_size(height_ratio: float = 0.6, width_ratio: float = 0.7) -> Tuple[int, int]:
    size = get_terminal_size(fallback=(80, 24))
    width = max(60, min(120, int(size.columns * width_ratio)))
    height = max(12, min(30, int(size.lines * height_ratio)))
    return height, width


def dialog_menu(title: str, prompt: str, items: List[tuple]) -> Optional[str]:
    height, width = dialog_size(0.7, 0.8)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--menu",
        prompt,
        str(height),
        str(width),
        "0",
    ]
    for tag, desc in items:
        args.extend([tag, desc])
    result = run(args, check=False, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def dialog_input(title: str, prompt: str, default: str = "") -> Optional[str]:
    height, width = dialog_size(0.4, 0.8)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--inputbox",
        prompt,
        str(height),
        str(width),
        default,
    ]
    result = run(args, check=False, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def dialog_fselect(title: str, prompt: str, path: str) -> Optional[str]:
    height, width = dialog_size(0.6, 0.8)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--fselect",
        path,
        str(height),
        str(width),
    ]
    result = run(args, check=False, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def dialog_checklist(title: str, prompt: str, items: List[tuple]) -> List[str]:
    height, width = dialog_size(0.7, 0.85)
    list_height = max(10, height - 8)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--scrollbar",
        "--checklist",
        prompt,
        str(height),
        str(width),
        str(list_height),
    ]
    for tag, desc, status in items:
        args.extend([tag, desc, status])
    result = run(args, check=False, capture_output=True)
    if result.returncode != 0:
        return []
    raw = result.stdout.strip()
    if not raw:
        return []
    return [item.strip('"') for item in raw.split()]


def dialog_yesno(title: str, prompt: str) -> bool:
    height, width = dialog_size(0.35, 0.7)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--yesno",
        prompt,
        str(height),
        str(width),
    ]
    result = run(args, check=False)
    return result.returncode == 0


def dialog_password(title: str, prompt: str) -> Optional[str]:
    height, width = dialog_size(0.4, 0.7)
    args = [
        "dialog",
        "--stdout",
        "--title",
        title,
        "--insecure",
        "--passwordbox",
        prompt,
        str(height),
        str(width),
    ]
    result = run(args, check=False, capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def dialog_msgbox(title: str, message: str) -> None:
    height, width = dialog_size(0.4, 0.7)
    run(
        [
            "dialog",
            "--stdout",
            "--title",
            title,
            "--msgbox",
            message,
            str(height),
            str(width),
        ],
        check=False,
    )


def dialog_textbox(title: str, content: str) -> None:
    height, width = dialog_size(0.85, 0.9)
    temp = Path(tempfile.mkstemp(prefix="distrodeck-textbox-")[1])
    temp.write_text(content + "\n", encoding="utf-8")
    run(
        [
            "dialog",
            "--title",
            title,
            "--textbox",
            str(temp),
            str(height),
            str(width),
        ],
        check=False,
    )
    try:
        temp.unlink()
    except OSError:
        # Temporary file cleanup is best-effort; failure to delete is non-fatal.
        pass


def show_about_dialog() -> None:
    dialog_msgbox(
        "About distrodeck",
        "distrodeck snapshots and restores package selections, sources, and related system state before distro maintenance.\n\n"
        "Author profiles\n"
        "GitHub: https://github.com/nikolareljin\n"
        "LinkedIn: https://www.linkedin.com/in/nikolareljin",
    )


def confirm_risky_extract(archive: str) -> bool:
    message = (
        "About to extract a config snapshot to the root filesystem (/).\n"
        "This can overwrite system files. Only continue if you trust the archive.\n\n"
        f"Archive: {archive}\n\n"
        "Continue?"
    )
    if in_dialog_mode() and cmd_exists("dialog"):
        return dialog_yesno("Config Snapshot Warning", message)
    if sys.stdin.isatty():
        try:
            response = input(f"warning: {message}\n[y/N]: ")
        except EOFError:
            return False
        return response.strip().lower() in {"y", "yes"}
    warn("Non-interactive session; skipping config snapshot extraction.")
    return False


def edit_config_file(path: Path) -> None:
    if not path.exists() or not path.is_file():
        dialog_msgbox("Config Editor", f"File not found: {path}")
        return
    editor = os.getenv("EDITOR") or ""
    if not editor:
        for candidate in ("nano", "micro", "vi", "vim"):
            if cmd_exists(candidate):
                editor = candidate
                break
    if not editor:
        dialog_msgbox("Config Editor", "No editor found (set $EDITOR or install nano/vim/vi).")
        return
    needs_sudo = not str(path.resolve()).startswith(str(Path.home().resolve()))
    run(["dialog", "--clear"], check=False)
    if needs_sudo:
        if not ensure_sudo():
            return
        run(["sudo", editor, str(path)], check=False)
    else:
        run([editor, str(path)], check=False)


def config_edit_targets() -> List[Tuple[str, str]]:
    candidates = [
        ("Nginx", "/etc/nginx/nginx.conf"),
        ("Apache (Debian)", "/etc/apache2/apache2.conf"),
        ("Apache (RHEL)", "/etc/httpd/conf/httpd.conf"),
        ("SSH server", "/etc/ssh/sshd_config"),
        ("SSH client", "/etc/ssh/ssh_config"),
        ("Fstab", "/etc/fstab"),
        ("Network (interfaces)", "/etc/network/interfaces"),
        ("Network (netplan)", "/etc/netplan/*.yaml"),
        ("Network (ifcfg)", "/etc/sysconfig/network-scripts/ifcfg-*"),
        ("PHP (cli)", "/etc/php/*/cli/php.ini"),
        ("PHP (fpm)", "/etc/php/*/fpm/php.ini"),
        ("PHP (apache2)", "/etc/php/*/apache2/php.ini"),
        ("PHP (system)", "/etc/php.ini"),
    ]
    items: List[Tuple[str, str]] = []
    for label, pattern in candidates:
        matches = glob(pattern)
        if not matches and "*" not in pattern:
            if Path(pattern).exists():
                items.append((label, pattern))
            continue
        for match in matches:
            items.append((f"{label}: {match}", match))
    return items


def git_config_targets() -> List[Tuple[str, str]]:
    candidates = [
        ("Git config (user ~/.gitconfig)", str(Path.home() / ".gitconfig")),
        ("Git config (user ~/.config/git/config)", str(Path.home() / ".config" / "git" / "config")),
        ("Git config (system)", "/etc/gitconfig"),
    ]
    items: List[Tuple[str, str]] = []
    for label, path in candidates:
        if Path(path).exists():
            items.append((label, path))
    return items


def repo_source_targets() -> List[Tuple[str, str]]:
    candidates = [
        ("Apt sources", "/etc/apt/sources.list"),
        ("Apt sources", "/etc/apt/sources.list.d/*.list"),
        ("Apt sources (deb822)", "/etc/apt/sources.list.d/*.sources"),
        ("DNF/Yum repos", "/etc/yum.repos.d/*.repo"),
        ("Zypper repos", "/etc/zypp/repos.d/*.repo"),
        ("Pacman config", "/etc/pacman.conf"),
        ("Pacman repos", "/etc/pacman.d/*.conf"),
    ]
    items: List[Tuple[str, str]] = []
    for label, pattern in candidates:
        matches = glob(pattern)
        if not matches and "*" not in pattern:
            if Path(pattern).exists():
                items.append((f"{label}: {pattern}", pattern))
            continue
        for match in matches:
            items.append((f"{label}: {match}", match))
    return items


def apt_source_files() -> List[Path]:
    files = [Path("/etc/apt/sources.list")]
    sources_dir = Path("/etc/apt/sources.list.d")
    if sources_dir.exists():
        files.extend(sorted(sources_dir.glob("*.list")))
    return [path for path in files if path.exists()]


def apt_deb822_files() -> List[Path]:
    sources_dir = Path("/etc/apt/sources.list.d")
    if not sources_dir.exists():
        return []
    return [path for path in sorted(sources_dir.glob("*.sources")) if path.exists()]


def distrodeck_config_targets() -> List[Tuple[str, str]]:
    items: List[Tuple[str, str]] = []
    paths = list(config_paths())
    user_config = paths[-1] if paths else None
    for path in paths:
        if path.exists():
            label = (
                "Distrodeck config (user)"
                if user_config is not None and path == user_config
                else "Distrodeck config (system)"
            )
            items.append((label, str(path)))
    return items


def run_config_edit_tui() -> None:
    log_action_start("config-edit")
    require_dialog()
    while True:
        section = dialog_menu(
            "Config Editor",
            "Select what to edit:",
            [
                ("sources", "Repository sources"),
                ("configs", "System configs"),
                ("distrodeck", "Distrodeck config"),
                ("git", "Git config"),
                ("custom", "Custom path..."),
                ("back", "Back"),
            ],
        )
        if not section or section == "back":
            log_action_end("config-edit")
            break
        if section == "custom":
            custom = dialog_fselect("Config Editor", "Pick a file:", "/etc/")
            if custom:
                edit_config_file(Path(custom))
            continue
        if section == "sources":
            sources = repo_source_targets()
            if not sources:
                dialog_msgbox("Config Editor", "No repository source files found.")
                continue
            items = []
            for label, path in sources:
                items.append((path, label, "off"))
            items.append(("back", "Back", "off"))
            choices = dialog_checklist("Config Editor", "Select sources to edit:", items)
            if not choices or "back" in choices:
                continue
            for choice in choices:
                edit_config_file(Path(choice))
            continue
        if section == "configs":
            items = []
            for label, path in config_edit_targets():
                items.append((path, label, "off"))
            items.append(("back", "Back", "off"))
            choices = dialog_checklist("Config Editor", "Select a file to edit:", items)
            if not choices or "back" in choices:
                continue
            for choice in choices:
                edit_config_file(Path(choice))
            continue
        elif section == "distrodeck":
            items = []
            for label, path in distrodeck_config_targets():
                items.append((path, label, "off"))
            if not items:
                dialog_msgbox("Config Editor", "No distrodeck config file found.")
                continue
            items.append(("back", "Back", "off"))
            choices = dialog_checklist("Config Editor", "Select a file to edit:", items)
            if not choices or "back" in choices:
                continue
            for choice in choices:
                edit_config_file(Path(choice))
            continue
        elif section == "git":
            items = []
            for label, path in git_config_targets():
                items.append((path, label, "off"))
            if not items:
                dialog_msgbox("Config Editor", "No git config files found.")
                continue
            items.append(("back", "Back", "off"))
            choices = dialog_checklist("Config Editor", "Select a git config file:", items)
            if not choices or "back" in choices:
                continue
            for choice in choices:
                edit_config_file(Path(choice))
            continue

def dialog_gauge(
    title: str, message: str, no_percent: bool = False
) -> Optional[subprocess.Popen]:
    if not cmd_exists("dialog"):
        return None
    height, width = dialog_size(0.5, 0.8)
    args = [
        "dialog",
        "--title",
        title,
    ]
    if no_percent and dialog_supports_no_percent():
        args.append("--no-percent")
    args.extend(
        [
            "--gauge",
            message,
            str(height),
            str(width),
        ]
    )
    args.append("0")
    return subprocess.Popen(args, stdin=subprocess.PIPE, text=True)


_DIALOG_NO_PERCENT_SUPPORTED: Optional[bool] = None


def dialog_supports_no_percent() -> bool:
    global _DIALOG_NO_PERCENT_SUPPORTED
    if _DIALOG_NO_PERCENT_SUPPORTED is not None:
        return _DIALOG_NO_PERCENT_SUPPORTED
    if not cmd_exists("dialog"):
        _DIALOG_NO_PERCENT_SUPPORTED = False
        return False
    result = run(["dialog", "--help"], check=False, capture_output=True)
    output = (result.stdout or "") + (result.stderr or "")
    _DIALOG_NO_PERCENT_SUPPORTED = "--no-percent" in output
    return _DIALOG_NO_PERCENT_SUPPORTED


def dialog_gauge_update(proc: subprocess.Popen, percent: int, message: str) -> None:
    if not proc or not proc.stdin:
        return
    try:
        proc.stdin.write(f"XXX\n{percent}\n{message}\nXXX\n")
        proc.stdin.flush()
    except (BrokenPipeError, ValueError):
        return


def dialog_gauge_close(proc: subprocess.Popen) -> None:
    if not proc or not proc.stdin:
        return
    try:
        proc.stdin.write("100\n")
        proc.stdin.close()
    except (BrokenPipeError, ValueError):
        pass
    proc.wait()


class DialogGaugeAnimator:
    def __init__(self, proc: subprocess.Popen, message: str) -> None:
        self.proc = proc
        self.message = message
        self.percent = 0
        self.direction = 1
        self.stop_event = threading.Event()
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def update_message(self, message: str) -> None:
        with self.lock:
            self.message = message
        dialog_gauge_update(self.proc, self.percent, message)

    def _step(self) -> None:
        self.percent += self.direction * 5
        if self.percent >= 100:
            self.percent = 100
            self.direction = -1
        elif self.percent <= 0:
            self.percent = 0
            self.direction = 1

    def _run(self) -> None:
        while not self.stop_event.wait(0.2):
            with self.lock:
                self._step()
                message = self.message
                percent = self.percent
            dialog_gauge_update(self.proc, percent, message)

    def stop(self) -> None:
        self.stop_event.set()
        self.thread.join(timeout=1)


class DialogProgress:
    def __init__(self, title: str, message: str) -> None:
        self.title = title
        self.message = message
        self.gauge: Optional[subprocess.Popen] = None
        self.animator: Optional[DialogGaugeAnimator] = None

    def start(self) -> None:
        if not in_dialog_mode() or not cmd_exists("dialog"):
            return
        self.gauge = dialog_gauge(self.title, self.message, no_percent=True)
        if not self.gauge:
            return
        self.animator = DialogGaugeAnimator(self.gauge, self.message)
        self.animator.start()

    def update(self, message: str) -> None:
        self.message = message
        if self.animator:
            self.animator.update_message(message)
        elif self.gauge:
            dialog_gauge_update(self.gauge, 0, message)

    def close(self, message: Optional[str] = None) -> None:
        if message:
            self.update(message)
        if self.animator:
            self.animator.stop()
        if self.gauge:
            dialog_gauge_close(self.gauge)


def dialog_run_with_progress(title: str, message: str, action):
    progress = DialogProgress(title, message)
    progress.start()
    try:
        return action(progress)
    finally:
        progress.close()


def handle_sigint(signum, frame) -> None:
    if cmd_exists("dialog"):
        run(["dialog", "--clear"], check=False)
    sys.exit(130)


def dialog_log_spinner(log_path: str, message: str, stop_event: threading.Event) -> None:
    """Write periodic spinner updates to log when command produces no output.

    This provides visual feedback in the dialog tailbox that the process is still
    running. Spinner lines are prefixed with [SPINNER] for easy filtering if
    log parsing is needed (e.g., grep -v '^\\[SPINNER\\]' logfile).
    """
    frames = ["|", "/", "-", "\\"]
    index = 0
    try:
        last_size = Path(log_path).stat().st_size
    except OSError:
        last_size = 0
    while not stop_event.wait(1.0):
        try:
            size = Path(log_path).stat().st_size
        except OSError:
            size = last_size
        if size == last_size:
            frame = frames[index % len(frames)]
            index += 1
            try:
                with open(log_path, "a", encoding="utf-8", buffering=1) as handle:
                    handle.write(f"[SPINNER] {message} {frame}\n")
            except OSError:
                return
            try:
                last_size = Path(log_path).stat().st_size
            except OSError:
                last_size = size
        else:
            last_size = size


def dialog_run_command(
    title: str,
    message: str,
    command: List[str],
    allow_input: bool = False,
    env: Optional[dict] = None,
) -> int:
    height, width = dialog_size(0.7, 0.85)
    with tempfile.NamedTemporaryFile(
        prefix="distrodeck-", suffix=".log", delete=False, mode="w", encoding="utf-8"
    ) as log_file:
        log_path = log_file.name
        log_file.write(f"{message}\n\n")
        log_file.flush()

    out_handle = open(log_path, "a", encoding="utf-8", buffering=1)
    proc = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=out_handle,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    spinner_stop = threading.Event()
    spinner_thread = threading.Thread(
        target=dialog_log_spinner, args=(log_path, message, spinner_stop), daemon=True
    )
    spinner_thread.start()

    tail = run(
        [
            "dialog",
            "--stdout",
            "--title",
            title,
            "--tailboxbg",
            log_path,
            str(height),
            str(width),
        ],
        check=False,
        capture_output=True,
    )
    tail_pid = int(tail.stdout.strip()) if tail.stdout.strip().isdigit() else None

    if allow_input:
        prompt = "Send input (blank to refresh, Cancel to abort):"
        while proc.poll() is None:
            result = run(
                [
                    "dialog",
                    "--stdout",
                    "--keep-window",
                    "--title",
                    title,
                    "--inputbox",
                    prompt,
                    str(height),
                    str(width),
                    "",
                ],
                check=False,
                capture_output=True,
            )
            if result.returncode != 0:
                if dialog_yesno(title, "Abort the running command?"):
                    proc.terminate()
                    break
                continue
            text = result.stdout.rstrip("\n")
            if text and proc.stdin:
                try:
                    proc.stdin.write(text + "\n")
                    proc.stdin.flush()
                except (BrokenPipeError, ValueError):
                    pass
            time.sleep(0.1)
    else:
        proc.wait()
    spinner_stop.set()
    spinner_thread.join(timeout=1)

    if proc.stdin:
        try:
            proc.stdin.close()
        except (BrokenPipeError, ValueError):
            pass
    out_handle.close()
    if tail_pid:
        try:
            os.kill(tail_pid, signal.SIGTERM)
        except OSError:
            pass
    run(["dialog", "--clear"], check=False)
    return proc.returncode or 0


def in_dialog_mode() -> bool:
    return os.getenv("DISTRODECK_DIALOG") == "1"


def allow_nala() -> bool:
    return os.getenv("DISTRODECK_NO_NALA") != "1"


def read_os_release() -> dict:
    data = {}
    path = Path("/etc/os-release")
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key] = value.strip().strip('"')
    return data


def get_os_id() -> str:
    return read_os_release().get("ID", "unknown")


def get_codename() -> str:
    if cmd_exists("lsb_release"):
        try:
            return run(["lsb_release", "-sc"], capture_output=True).stdout.strip()
        except subprocess.CalledProcessError:
            return ""
    return read_os_release().get("VERSION_CODENAME", "")


def get_appimage_dirs(arg_dirs: Optional[str]) -> List[str]:
    if arg_dirs:
        return [d for d in arg_dirs.split(":") if d]
    env_dirs = os.getenv("DISTRODECK_APPIMAGE_DIRS") or os.getenv("APPIMAGE_DIRS")
    if env_dirs:
        return [d for d in env_dirs.split(":") if d]
    return [
        str(Path.home() / "Applications"),
        str(Path.home() / "AppImage"),
        str(Path.home() / "AppImages"),
    ]


def get_config_dirs(arg_dirs: Optional[str]) -> List[str]:
    if arg_dirs:
        return [d for d in arg_dirs.split(":") if d]
    return ["/etc", "/etc/apt", "/etc/dnf", "/etc/pacman.d"]


def get_config_files(arg_files: Optional[str]) -> List[str]:
    if arg_files:
        return [os.path.expanduser(p) for p in arg_files.split(":") if p]
    return [
        "/etc/hosts",
        "/etc/fstab",
        os.path.expanduser("~/.ssh/config"),
    ]


def default_export_filename() -> str:
    hostname = socket.gethostname().split(".")[0]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return str(get_export_dir() / f"distrodeck-export-{hostname}-{stamp}.txt")


def backup_export_filename() -> str:
    hostname = socket.gethostname().split(".")[0]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return str(get_export_dir() / f"distrodeck-backup-{hostname}-{stamp}.txt")


EXPORT_SECTION_ORDER = [
    "apt_manual",
    "apt_hold",
    "ppas",
    "apt_sources",
    "snap",
    "flatpak",
    "pacman",
    "dnf",
    "zypper",
    "appimage",
    "pipx",
    "npm_global",
    "composer_global",
    "nuget_global",
    "cargo",
    "gem",
    "go",
    "config_snapshot",
    "services_enabled",
    "services_active",
    "config_files",
]


def run_preflight() -> List[str]:
    results = []
    try:
        usage = shutil.disk_usage("/")
        free_gb = usage.free / (1024**3)
        if free_gb < 1.0:
            results.append(f"WARN: disk space low on / ({free_gb:.1f} GB free)")
        else:
            results.append(f"OK: disk space on / ({free_gb:.1f} GB free)")
    except OSError as exc:
        results.append(f"WARN: disk space check failed: {exc}")

    os_id = get_os_id()
    supported = {
        "ubuntu",
        "debian",
        "fedora",
        "rhel",
        "centos",
        "arch",
        "manjaro",
        "opensuse",
        "opensuse-leap",
        "opensuse-tumbleweed",
    }
    if os_id in supported:
        results.append(f"OK: os_id={os_id}")
    else:
        results.append(f"WARN: os_id={os_id} may be unsupported")

    try:
        with socket.create_connection(("1.1.1.1", 53), timeout=2):
            results.append("OK: connectivity")
    except OSError:
        results.append("WARN: connectivity check failed")

    reboot_required = Path("/var/run/reboot-required")
    if reboot_required.exists():
        results.append("WARN: reboot required (/var/run/reboot-required)")
    elif cmd_exists("needs-restarting"):
        result = run(["needs-restarting", "-r"], check=False)
        if result.returncode != 0:
            results.append("WARN: reboot required (needs-restarting)")
        else:
            results.append("OK: reboot not required")
    else:
        results.append("OK: reboot not required (no indicator)")
    return results


def run_logs(args: argparse.Namespace) -> None:
    log_action_start("logs")
    log_dir = get_log_dir()
    logs = sorted(log_dir.glob("distrodeck-*.log"))
    if not logs:
        print("No logs found.")
        log_action_end("logs", "empty")
        return
    if args.tail and not args.latest:
        args.latest = True
    if args.latest:
        target = logs[-1]
        if args.tail and args.tail > 0:
            lines = target.read_text(encoding="utf-8").splitlines()
            print("\n".join(lines[-args.tail :]))
        else:
            print(target.read_text(encoding="utf-8"))
        log_action_end("logs")
        return
    for path in logs:
        print(str(path))
    log_action_end("logs")


def run_clear_logs(_: argparse.Namespace) -> None:
    log_action_start("clear-logs")
    log_dir = get_log_dir()
    removed = 0
    for path in log_dir.glob("distrodeck-*.log"):
        try:
            path.unlink()
            removed += 1
        except OSError as exc:
            warn(f"Failed to remove log: {path} ({exc})")
    init_logging()
    print(f"Removed {removed} log(s).")
    log_action_end("clear-logs")


def run_preflight_cmd(_: argparse.Namespace) -> None:
    log_action_start("preflight")
    results = run_preflight()
    for line in results:
        log(line)
    log_action_end("preflight")


DOCTOR_SEVERITY_ORDER = {"ok": 0, "warn": 1, "blocker": 2}


def _doctor_add_check(
    checks: List[Dict[str, object]],
    name: str,
    severity: str,
    message: str,
    remediation: str = "",
    details: Optional[Dict[str, object]] = None,
) -> None:
    item: Dict[str, object] = {
        "name": name,
        "severity": severity,
        "message": message,
    }
    if remediation:
        item["remediation"] = remediation
    if details:
        item["details"] = details
    checks.append(item)


def _doctor_status(checks: List[Dict[str, object]]) -> str:
    worst = "ok"
    for check in checks:
        sev = str(check.get("severity", "ok"))
        if DOCTOR_SEVERITY_ORDER.get(sev, 0) > DOCTOR_SEVERITY_ORDER[worst]:
            worst = sev
    return worst


def _doctor_summary(checks: List[Dict[str, object]]) -> Dict[str, int]:
    summary = {"ok": 0, "warn": 0, "blocker": 0}
    for check in checks:
        sev = str(check.get("severity", "ok"))
        if sev in summary:
            summary[sev] += 1
    return summary


def _doctor_apt_repo_hosts() -> Tuple[List[str], List[str]]:
    hosts: Set[str] = set()
    malformed_uris: Set[str] = set()
    for line in active_apt_sources():
        parsed = parse_apt_source_line(line)
        if not parsed:
            continue
        uri = parsed.get("uri", "")
        try:
            parsed_uri = urlparse(uri)
            host = (parsed_uri.hostname or "").strip().lower()
        except ValueError:
            malformed_uris.add(uri)
            continue
        if parsed_uri.scheme in {"cdrom", "file"}:
            continue
        if host:
            hosts.add(host)
    return sorted(hosts), sorted(malformed_uris)


def _doctor_check_host_resolution(host: str) -> bool:
    state = {"resolved": False}

    def _resolve_host() -> None:
        try:
            socket.getaddrinfo(host, None)
            state["resolved"] = True
        except OSError:
            state["resolved"] = False

    thread = threading.Thread(target=_resolve_host, daemon=True)
    thread.start()
    thread.join(timeout=DOCTOR_DNS_TIMEOUT_SECONDS)
    if thread.is_alive():
        return False
    return bool(state["resolved"])


def _doctor_probe_apt_metadata() -> Tuple[int, str]:
    with tempfile.TemporaryDirectory(prefix="distrodeck-doctor-apt-") as temp_dir:
        lists_dir = Path(temp_dir) / "lists"
        partial_dir = lists_dir / "partial"
        partial_dir.mkdir(parents=True, exist_ok=True)
        cmd = [
            "apt-get",
            "update",
            "-o",
            "Debug::NoLocking=true",
            "-o",
            f"Dir::State::Lists={lists_dir}",
            "-o",
            "Acquire::Retries=0",
            "-o",
            "APT::Get::List-Cleanup=0",
        ]
        result = subprocess.run(
            cmd,
            check=False,
            capture_output=True,
            text=True,
            timeout=DOCTOR_REPO_METADATA_TIMEOUT_SECONDS,
        )
        output = (result.stdout or "") + "\n" + (result.stderr or "")
        return result.returncode, output


def get_latest_log_path() -> Optional[Path]:
    log_dir = get_log_dir()
    logs = sorted(log_dir.glob("distrodeck-*.log"))
    return logs[-1] if logs else None


def run_sysinfo(_: argparse.Namespace) -> None:
    log_action_start("sysinfo")
    def section(title: str) -> None:
        log("")
        log(f"== {title} ==")

    def run_capture(cmd: List[str], label: str) -> None:
        if not cmd_exists(cmd[0]):
            log(f"{label}: not available")
            return
        result = run(cmd, check=False, capture_output=True)
        output = (result.stdout or result.stderr or "").strip()
        if not output:
            log(f"{label}: no output")
            return
        log(f"{label}:\n{output}")

    section("OS")
    log(f"os_id={get_os_id()}")
    codename = get_codename()
    if codename:
        log(f"codename={codename}")
    run_capture(["uname", "-a"], "kernel")

    section("CPU")
    run_capture(["lscpu"], "lscpu")

    section("GPU")
    run_capture(["lspci"], "lspci")

    section("Memory")
    run_capture(["free", "-h"], "free")
    if cmd_exists("dmidecode") and cmd_exists("sudo"):
        run_capture(["sudo", "dmidecode", "-t", "memory"], "dmidecode")
    else:
        log("dmidecode: not available (sudo required)")

    section("Disks")
    run_capture(["lsblk", "-o", "NAME,SIZE,TYPE,MODEL,SERIAL"], "lsblk")
    run_capture(["df", "-h", "/"], "df /")

    section("Network")
    run_capture(["ip", "-br", "a"], "interfaces")
    run_capture(["ip", "route"], "routes")
    if cmd_exists("ss"):
        run_capture(["ss", "-tulpen"], "open ports")
    else:
        log("open ports: ss not available")

    section("Public IP")
    if cmd_exists("curl"):
        result = run(
            ["curl", "-fsS", "--max-time", "3", "https://api.ipify.org"],
            check=False,
            capture_output=True,
        )
        output = (result.stdout or "").strip()
        log(f"public_ip={output}" if output else "public_ip: unavailable")
    else:
        log("public_ip: curl not available")

    section("Internet Speed")
    if cmd_exists("speedtest"):
        run_capture(["speedtest", "--accept-license", "--accept-gdpr"], "speedtest")
    elif cmd_exists("speedtest-cli"):
        run_capture(["speedtest-cli", "--simple"], "speedtest-cli")
    else:
        log("speedtest: not available")

    section("USB")
    run_capture(["lsusb"], "lsusb")
    log_action_end("sysinfo")


def get_network_cidrs() -> List[str]:
    if not cmd_exists("ip"):
        return []
    result = run(["ip", "-o", "-f", "inet", "addr", "show"], check=False, capture_output=True)
    cidrs = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if "inet" in parts:
            idx = parts.index("inet")
            if idx + 1 < len(parts):
                cidrs.append(parts[idx + 1])
    return sorted(set(cidrs))


def run_network_tools_tui() -> None:
    log_action_start("net-tools")
    require_dialog()
    cidrs = get_network_cidrs()
    cidr_label = ", ".join(cidrs) if cidrs else "none"
    tools = [
        ("nmap", "Scan local networks with nmap"),
        ("mtr", "Trace route with mtr"),
        ("iperf3", "Throughput test (client mode)"),
        ("traceroute", "Trace route to target"),
        ("tcpdump", "Capture packets (interactive)"),
        ("back", "Back"),
    ]
    while True:
        choice = dialog_menu("Network Tools", f"Detected networks: {cidr_label}", tools)
        if not choice or choice == "back":
            log_action_end("net-tools")
            break
        if choice == "nmap":
            log_action_start("net-tools nmap")
            if not cmd_exists("nmap"):
                dialog_msgbox("Network Tools", "nmap not installed.")
                log_action_end("net-tools nmap", "missing")
                continue
            targets = cidrs if cidrs else []
            custom = dialog_input("nmap", "Targets (space-separated, blank = auto):", " ".join(targets))
            if custom:
                targets = custom.split()
            if not targets:
                dialog_msgbox("nmap", "No targets available.")
                continue
            run(["dialog", "--clear"], check=False)
            def _run_nmap(_progress):
                return run(["nmap", "-sV", *targets], check=False, capture_output=True)

            result = dialog_run_with_progress(
                "nmap",
                f"Scanning {len(targets)} target(s)...",
                _run_nmap,
            )
            output = (result.stdout or result.stderr or "No output").strip()
            if output:
                dialog_textbox("nmap Results", output)
            log_action_end("net-tools nmap")
            continue
        if choice == "mtr":
            log_action_start("net-tools mtr")
            if not cmd_exists("mtr"):
                dialog_msgbox("Network Tools", "mtr not installed.")
                log_action_end("net-tools mtr", "missing")
                continue
            host = dialog_input("mtr", "Host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["mtr", host], check=False)
            log_action_end("net-tools mtr")
            continue
        if choice == "iperf3":
            log_action_start("net-tools iperf3")
            if not cmd_exists("iperf3"):
                dialog_msgbox("Network Tools", "iperf3 not installed.")
                log_action_end("net-tools iperf3", "missing")
                continue
            host = dialog_input("iperf3", "Server host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["iperf3", "-c", host], check=False)
            log_action_end("net-tools iperf3")
            continue
        if choice == "traceroute":
            log_action_start("net-tools traceroute")
            if not cmd_exists("traceroute"):
                dialog_msgbox("Network Tools", "traceroute not installed.")
                log_action_end("net-tools traceroute", "missing")
                continue
            host = dialog_input("traceroute", "Host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["traceroute", host], check=False)
            log_action_end("net-tools traceroute")
            continue
        if choice == "tcpdump":
            log_action_start("net-tools tcpdump")
            if not cmd_exists("tcpdump"):
                dialog_msgbox("Network Tools", "tcpdump not installed.")
                log_action_end("net-tools tcpdump", "missing")
                continue
            iface = dialog_input("tcpdump", "Interface (blank = default):", "")
            cmd = ["tcpdump"]
            if iface:
                cmd.extend(["-i", iface])
            run(["dialog", "--clear"], check=False)
            run(cmd, check=False)
            log_action_end("net-tools tcpdump")
            continue


def copy_to_clipboard(text: str) -> bool:
    if cmd_exists("wl-copy"):
        run(["wl-copy"], input_text=text, check=False)
        return True
    if cmd_exists("xclip"):
        run(["xclip", "-selection", "clipboard"], input_text=text, check=False)
        return True
    if cmd_exists("xsel"):
        run(["xsel", "--clipboard", "--input"], input_text=text, check=False)
        return True
    if cmd_exists("pbcopy"):
        run(["pbcopy"], input_text=text, check=False)
        return True
    return False


def export_apt_manual() -> List[str]:
    if cmd_exists("apt-mark"):
        out = run(["apt-mark", "showmanual"], capture_output=True).stdout
        return sorted([line for line in out.splitlines() if line.strip()])
    return []


def export_apt_hold() -> List[str]:
    if cmd_exists("apt-mark"):
        out = run(["apt-mark", "showhold"], capture_output=True).stdout
        return sorted([line for line in out.splitlines() if line.strip()])
    return []


def export_ppas() -> List[str]:
    lines = []
    for path in ["/etc/apt/sources.list", "/etc/apt/sources.list.d"]:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                for name in files:
                    if name.endswith(".list"):
                        lines.extend(
                            Path(root, name).read_text(encoding="utf-8").splitlines()
                        )
        elif os.path.isfile(path):
            lines.extend(Path(path).read_text(encoding="utf-8").splitlines())
    ppas = set()
    for line in lines:
        if not line.startswith("deb "):
            continue
        match = re.search(r"ppa\.launchpad\.net/([^/]+)/([^/]+)/", line)
        if match:
            ppas.add(f"ppa:{match.group(1)}/{match.group(2)}")
    return sorted(ppas)


def normalize_apt_source_line(line: str) -> str:
    return re.sub(r"\s+", " ", line.strip())


def parse_apt_source_line(line: str) -> Optional[Dict[str, str]]:
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        return None
    if not (stripped.startswith("deb ") or stripped.startswith("deb-src ")):
        return None
    parsed_line = stripped
    if re.match(r"^deb(?:-src)?\s+\[", stripped):
        bracket_start = stripped.find("[")
        bracket_end = stripped.find("]", bracket_start + 1)
        if bracket_start == -1 or bracket_end == -1:
            return None
        before = stripped[:bracket_start].rstrip()
        after = stripped[bracket_end + 1 :].lstrip()
        parsed_line = f"{before} {after}".strip()
    try:
        parts = shlex.split(parsed_line)
    except ValueError:
        return None
    if len(parts) < 2:
        return None
    kind = parts[0]
    idx = 1
    if idx >= len(parts):
        return None
    uri = parts[idx]
    suite = parts[idx + 1] if idx + 1 < len(parts) else ""
    return {"kind": kind, "uri": uri, "suite": suite, "line": stripped}


def _split_deb822_field(value: str) -> List[str]:
    return [part for part in value.split() if part]


def _normalize_deb822_option_value(value: str) -> str:
    return ",".join(value.split())


def deb822_to_deb_lines(lines: List[str]) -> List[str]:
    """
    Convert deb822 stanzas to deb/deb-src lines.

    Supported options: Architectures, Signed-By.
    Other deb822 fields are ignored during conversion, so conversion is lossy.
    Stanzas with `Enabled: no|false|0|off` are skipped.
    Stanzas missing URIs or Suites are skipped.
    """
    stanzas: List[Dict[str, str]] = []
    current: Dict[str, str] = {}
    current_key: Optional[str] = None
    for raw in lines:
        line = raw.rstrip("\n")
        if not line.strip():
            if current:
                stanzas.append(current)
                current = {}
            current_key = None
            continue
        if line.lstrip().startswith("#"):
            continue
        if line[:1].isspace():
            if current_key:
                current[current_key] = f"{current[current_key]} {line.strip()}"
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip().lower()
        current[key] = value.strip()
        current_key = key
    if current:
        stanzas.append(current)

    output: List[str] = []
    for stanza in stanzas:
        enabled_value = stanza.get("enabled", "").strip().lower()
        if enabled_value in {"no", "false", "0", "off"}:
            continue
        types = _split_deb822_field(stanza.get("types", "deb"))
        uris = _split_deb822_field(stanza.get("uris", "") or stanza.get("uri", ""))
        suites = _split_deb822_field(stanza.get("suites", "") or stanza.get("suite", ""))
        components = _split_deb822_field(stanza.get("components", ""))
        if not uris or not suites:
            continue
        options = []
        architectures = stanza.get("architectures", "")
        if architectures:
            options.append(f"arch={_normalize_deb822_option_value(architectures)}")
        signed_by = stanza.get("signed-by", "")
        if signed_by:
            options.append(f"signed-by={_normalize_deb822_option_value(signed_by)}")
        options_prefix = f"[{' '.join(options)}] " if options else ""
        for entry_type in types:
            for uri in uris:
                for suite in suites:
                    line = f"{entry_type} {options_prefix}{uri} {suite}"
                    if components:
                        line += " " + " ".join(components)
                    output.append(line)
    return output


def _is_same_or_subdomain(host: str, parent: str) -> bool:
    """
    Return True if ``host`` is exactly ``parent`` or a subdomain of it.

    Both arguments are treated as DNS hostnames (no ports) and are compared
    case-insensitively based on their label structure.
    This is used for repository trust decisions; changes affect security.

    Examples:
      - host=archive.ubuntu.com, parent=ubuntu.com -> True
      - host=ubuntu.com.attacker.com, parent=ubuntu.com -> False
      - host=evilarchive.ubuntu.com.attacker.com, parent=archive.ubuntu.com -> False
    """
    if not host or not parent:
        return False
    host_norm = host.lower().rstrip(".")
    parent_norm = parent.lower().rstrip(".")
    if host_norm == parent_norm:
        return True
    if not host_norm.endswith(f".{parent_norm}"):
        return False
    host_labels = host_norm.split(".")
    parent_labels = parent_norm.split(".")
    if len(host_labels) <= len(parent_labels):
        return False
    return host_labels[-len(parent_labels) :] == parent_labels


def is_official_apt_repo(uri: str, os_id: str) -> bool:
    parsed = urlparse(uri)
    if parsed.scheme == "cdrom":
        return True
    if parsed.scheme == "file":
        return parsed.path.startswith("/cdrom")
    if not parsed.scheme and parsed.path.startswith("/cdrom"):
        return True
    host = (parsed.hostname or "").lower()
    if not host:
        return False
    for official in get_official_apt_hosts(os_id):
        if _is_same_or_subdomain(host, official):
            return True
    return False


def active_apt_sources() -> Set[str]:
    sources: Set[str] = set()
    for path in apt_source_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("#"):
                continue
            if stripped.startswith("deb ") or stripped.startswith("deb-src "):
                sources.add(normalize_apt_source_line(stripped))
    for path in apt_deb822_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for deb_line in deb822_to_deb_lines(lines):
            sources.add(normalize_apt_source_line(deb_line))
    return sources


def export_apt_sources() -> List[str]:
    sources = set()
    os_id = get_os_id()
    for item in apt_source_files():
        try:
            lines = item.read_text(encoding="utf-8").splitlines()
        except OSError:
            warn(f"Failed to read apt sources: {item}")
            continue
        for line in lines:
            info = parse_apt_source_line(line)
            if not info:
                continue
            if "ppa.launchpad.net" in info["line"]:
                continue
            if is_official_apt_repo(info["uri"], os_id):
                continue
            sources.add(normalize_apt_source_line(info["line"]))
    for item in apt_deb822_files():
        try:
            lines = item.read_text(encoding="utf-8").splitlines()
        except OSError:
            warn(f"Failed to read apt sources: {item}")
            continue
        for deb_line in deb822_to_deb_lines(lines):
            info = parse_apt_source_line(deb_line)
            if not info:
                continue
            if "ppa.launchpad.net" in info["line"]:
                continue
            if is_official_apt_repo(info["uri"], os_id):
                continue
            sources.add(normalize_apt_source_line(info["line"]))
    return sorted(sources)


def export_snaps() -> List[str]:
    if not cmd_exists("snap"):
        return []
    out = run(["snap", "list"], capture_output=True).stdout
    items = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 4:
            continue
        name = parts[0]
        tracking = parts[3]
        notes = parts[-1] if len(parts) > 5 else ""
        classic = "true" if notes == "classic" else "false"
        items.append(f"{name} channel={tracking} classic={classic}")
    return sorted(set(items))


def export_flatpaks() -> List[str]:
    if not cmd_exists("flatpak"):
        return []
    out = run(
        ["flatpak", "list", "--app", "--columns=application,origin"],
        capture_output=True,
    ).stdout
    items = []
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        app = parts[0]
        remote = parts[1] if len(parts) > 1 else ""
        if remote:
            items.append(f"remote={remote} app={app}")
        else:
            items.append(f"app={app}")
    return sorted(set(items))


def export_pacman() -> List[str]:
    if not cmd_exists("pacman"):
        return []
    out = run(["pacman", "-Qqe"], capture_output=True).stdout
    return sorted([line for line in out.splitlines() if line.strip()])


def export_dnf() -> List[str]:
    if not cmd_exists("dnf"):
        return []
    try:
        out = run(
            ["dnf", "repoquery", "--userinstalled", "--qf", "%{name}"],
            capture_output=True,
        ).stdout
        items = [line for line in out.splitlines() if line.strip()]
        return sorted(set(items))
    except subprocess.CalledProcessError:
        return []


def export_zypper() -> List[str]:
    if not cmd_exists("zypper"):
        return []
    try:
        out = run(
            ["zypper", "search", "-i", "-t", "package", "-s"],
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        if not line.strip().startswith("i |"):
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) >= 2:
            name = parts[1]
            if name:
                items.append(name)
    return sorted(set(items))


def export_appimages(appimage_dirs: List[str]) -> List[str]:
    found = set()
    for root in appimage_dirs:
        path = Path(root)
        if not path.exists():
            continue
        for dirpath, _, filenames in os.walk(path):
            depth = len(Path(dirpath).relative_to(path).parts)
            if depth > 1:
                continue
            for name in filenames:
                if name.endswith(".AppImage"):
                    found.add(str(Path(dirpath, name)))
    return sorted(found)


def export_pipx() -> List[str]:
    if not cmd_exists("pipx"):
        return []
    try:
        out = run(["pipx", "list", "--short"], capture_output=True).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        parts = line.strip().split()
        if parts:
            items.append(parts[0])
    return sorted(set(items))


def export_npm_globals() -> List[str]:
    if not cmd_exists("npm"):
        return []
    try:
        out = run(
            ["npm", "ls", "-g", "--depth=0", "--parseable"], capture_output=True
        ).stdout
    except subprocess.CalledProcessError:
        return []
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if not lines:
        return []
    root = lines[0]
    items = []
    for line in lines[1:]:
        if line == root:
            continue
        name = Path(line).name
        if name:
            items.append(name)
    return sorted(set(items))


def export_composer_globals() -> List[str]:
    if not cmd_exists("composer"):
        return []
    try:
        out = run(["composer", "global", "show", "-N"], capture_output=True).stdout
    except subprocess.CalledProcessError:
        return []
    items = [line.strip() for line in out.splitlines() if line.strip()]
    return sorted(set(items))


def export_nuget_globals() -> List[str]:
    if cmd_exists("dotnet"):
        try:
            out = run(["dotnet", "tool", "list", "-g"], capture_output=True).stdout
        except subprocess.CalledProcessError:
            return []
        items = []
        for line in out.splitlines():
            parts = line.strip().split()
            if parts and parts[0].lower() != "package":
                items.append(parts[0])
        return sorted(set(items))
    return []


def export_cargo_installs() -> List[str]:
    if not cmd_exists("cargo"):
        return []
    try:
        out = run(["cargo", "install", "--list"], capture_output=True).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        match = re.match(r"^([A-Za-z0-9_-]+)\s+v[0-9]", line)
        if match:
            items.append(match.group(1))
    return sorted(set(items))


def export_gems() -> List[str]:
    if not cmd_exists("gem"):
        return []
    try:
        out = run(["gem", "list"], capture_output=True).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        parts = line.strip().split()
        if parts:
            items.append(parts[0])
    return sorted(set(items))


def export_go_installs() -> List[str]:
    if not cmd_exists("go"):
        return []
    try:
        gobin = run(["go", "env", "GOBIN"], capture_output=True).stdout.strip()
        gopath = run(["go", "env", "GOPATH"], capture_output=True).stdout.strip()
    except subprocess.CalledProcessError:
        return []
    bin_dir = Path(gobin) if gobin else Path(gopath) / "bin"
    if not bin_dir.exists():
        return []
    items = []
    for entry in bin_dir.iterdir():
        if entry.is_file() and os.access(entry, os.X_OK):
            items.append(entry.name)
    return sorted(set(items))


def export_config_files(paths: List[str]) -> List[str]:
    items = []
    for path_str in paths:
        path = Path(path_str)
        if not path.exists() or not path.is_file():
            warn(f"Config file not found, skipping: {path}")
            continue
        try:
            raw = path.read_bytes()
        except OSError:
            warn(f"Failed to read config file: {path}")
            continue
        b64 = base64.b64encode(raw).decode("ascii")
        items.append(f"path={path} content_b64={b64}")
    return items


def export_services_enabled() -> List[str]:
    if not cmd_exists("systemctl"):
        return []
    try:
        out = run(
            ["systemctl", "list-unit-files", "--type=service", "--state=enabled"],
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        if not line or line.startswith("UNIT FILE") or line.startswith("-"):
            continue
        parts = line.split()
        if parts:
            items.append(parts[0])
    return sorted(set(items))


def export_services_active() -> List[str]:
    if not cmd_exists("systemctl"):
        return []
    try:
        out = run(
            [
                "systemctl",
                "list-units",
                "--type=service",
                "--state=running",
                "--no-legend",
                "--no-pager",
            ],
            capture_output=True,
        ).stdout
    except subprocess.CalledProcessError:
        return []
    items = []
    for line in out.splitlines():
        parts = line.split()
        if parts:
            items.append(parts[0])
    return sorted(set(items))


def normalize_snap_entry(entry: str) -> str:
    parts = entry.split()
    return parts[0] if parts else ""


def normalize_flatpak_entry(entry: str) -> str:
    app = ""
    for part in entry.split():
        if part.startswith("app="):
            app = part.split("=", 1)[1]
            break
    return app


def diff_items(desired: List[str], current: List[str]) -> Tuple[List[str], List[str]]:
    desired_set = {item for item in desired if item}
    current_set = {item for item in current if item}
    missing = sorted(desired_set - current_set)
    extra = sorted(current_set - desired_set)
    return missing, extra


def log_diff(title: str, missing: List[str], extra: List[str]) -> None:
    if not missing and not extra:
        log(f"{title}: up to date.")
        return
    if missing:
        log(f"{title}: missing ({len(missing)}): " + ", ".join(missing))
    if extra:
        log(f"{title}: extra ({len(extra)}): " + ", ".join(extra))


def export_config_snapshot(
    dirs: List[str], excludes: List[str], archive_path: Path
) -> Optional[str]:
    suppress_if_missing = {
        "/etc/apt": "apt-get",
        "/etc/dnf": "dnf",
        "/etc/pacman.d": "pacman",
        "/etc/zypp": "zypper",
        "/etc/yum.repos.d": "yum",
        "/etc/yum": "yum",
        "/etc/apk": "apk",
    }
    valid_dirs = []
    missing = []
    for path in dirs:
        if Path(path).exists():
            valid_dirs.append(path)
        else:
            missing.append(path)
    for path in missing:
        cmd = suppress_if_missing.get(path)
        if cmd and not cmd_exists(cmd):
            continue
        warn(f"Config dir not found, skipping: {path}")
    if not valid_dirs:
        return None
    cmd = ["sudo", "tar", "-czf", str(archive_path)]
    for pattern in excludes:
        cmd.extend(["--exclude", pattern])
    cmd.extend(valid_dirs)
    run_logged(cmd, "config snapshot tar", echo=not in_dialog_mode())
    return str(archive_path)


def export_all(args: argparse.Namespace) -> None:
    log_action_start("export")
    os_id = get_os_id()
    codename = get_codename()
    if args.output == DEFAULT_EXPORT_FILE:
        args.output = default_export_filename()
    appimage_dirs = get_appimage_dirs(args.appimage_dirs)
    config_dirs = get_config_dirs(args.config_dirs) if args.config_dirs else []
    config_excludes = args.config_exclude or []
    if args.include_config and not config_dirs:
        config_dirs = get_config_dirs(None)
    if args.config_archive:
        config_archive_path = Path(args.config_archive)
    else:
        out_path = Path(args.output)
        if out_path.suffix:
            config_archive_path = out_path.with_suffix(out_path.suffix + ".configs.tar.gz")
        else:
            config_archive_path = Path(f"{out_path}.configs.tar.gz")

    def export_config_section() -> List[str]:
        if not config_dirs:
            return []
        if not cmd_exists("sudo"):
            warn("sudo not available; skipping config snapshot.")
            return []
        if in_dialog_mode():
            if not ensure_sudo():
                return []
        archive = export_config_snapshot(
            config_dirs, config_excludes, config_archive_path
        )
        if not archive:
            return []
        return [
            f"archive={archive}",
            f"dirs={':'.join(config_dirs)}",
            *[f"exclude={pattern}" for pattern in config_excludes],
        ]
    sections = [
        ("apt_manual", export_apt_manual, "Exporting apt packages..."),
        ("apt_hold", export_apt_hold, "Exporting apt holds..."),
        ("ppas", export_ppas, "Exporting PPAs..."),
        ("apt_sources", export_apt_sources, "Exporting apt sources..."),
        ("snap", export_snaps, "Exporting snaps..."),
        ("flatpak", export_flatpaks, "Exporting flatpaks..."),
        ("pacman", export_pacman, "Exporting pacman packages..."),
        ("dnf", export_dnf, "Exporting dnf packages..."),
        ("zypper", export_zypper, "Exporting zypper packages..."),
        ("appimage", lambda: export_appimages(appimage_dirs), "Scanning AppImages..."),
    ]
    if config_dirs:
        sections.append(
            ("config_snapshot", export_config_section, "Saving config snapshot...")
        )
    config_files = get_config_files(args.config_files) if args.config_files else []
    if args.include_config_files and not config_files:
        config_files = get_config_files(None)
    if config_files:
        sections.append(
            (
                "config_files",
                lambda: export_config_files(config_files),
                "Exporting config files...",
            )
        )
    if args.include_user_tools:
        sections.extend(
            [
                ("pipx", export_pipx, "Exporting pipx tools..."),
                ("npm_global", export_npm_globals, "Exporting npm globals..."),
                ("composer_global", export_composer_globals, "Exporting Composer globals..."),
                ("nuget_global", export_nuget_globals, "Exporting NuGet globals..."),
                ("cargo", export_cargo_installs, "Exporting cargo installs..."),
                ("gem", export_gems, "Exporting gems..."),
                ("go", export_go_installs, "Exporting Go binaries..."),
            ]
        )
    if args.include_services:
        sections.extend(
            [
                ("services_enabled", export_services_enabled, "Exporting enabled services..."),
                ("services_active", export_services_active, "Exporting active services..."),
            ]
        )
    section_results = []
    progress = DialogProgress("Distrodeck Export", "Starting export...")
    progress.start()
    for name, func, message in sections:
        if progress.gauge:
            progress.update(message)
        section_results.append((name, func()))
    if progress.gauge:
        progress.close("Finalizing export...")
    out_lines = [
        "# distrodeck export v1",
        f"exported_at={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"distro_id={os_id}",
        f"codename={codename}",
        "",
    ]
    for name, items in section_results:
        out_lines.extend([f"[{name}]", *items, ""])
    Path(args.output).write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    log(f"Exported to {args.output}")
    if "config_snapshot" in {name for name, _ in section_results}:
        config_entry = next(
            (items for name, items in section_results if name == "config_snapshot"), []
        )
        for line in config_entry:
            if line.startswith("archive="):
                log(f"Config snapshot archive: {line.split('=', 1)[1]}")
                break
    log_action_end("export")


def ensure_nala() -> bool:
    if cmd_exists("nala"):
        return True
    if not cmd_exists("apt-get"):
        warn("apt-get not available; cannot install Nala")
        return False
    log("Installing Nala...")
    update_result = run_warn_live(["sudo", "apt-get", "update"], "apt-get update")
    if update_result.returncode != 0:
        warn("Skipping Nala install due to apt-get update failure.")
        return False
    run_warn_live(["sudo", "apt-get", "install", "-y", "nala"], "apt-get install nala")
    return True


def _kernel_package_abi(package: str) -> Optional[str]:
    for prefix in sorted(KERNEL_PACKAGE_PREFIXES, key=len, reverse=True):
        if package.startswith(prefix):
            abi = package[len(prefix) :]
            if abi and re.match(r"^\d", abi):
                return abi
    return None


def _kernel_base(abi: str) -> str:
    base = abi
    while re.search(r"-[A-Za-z][A-Za-z0-9.]*$", base):
        base = re.sub(r"-[A-Za-z][A-Za-z0-9.]*$", "", base)
    return base


def _kernel_sort_key(base: str) -> List[object]:
    parts: List[object] = []
    for part in re.split(r"([0-9]+)", base):
        if part.isdigit():
            parts.append((0, int(part)))
        elif part:
            parts.append((1, part))
    return parts


def select_old_kernel_packages(
    installed_packages: List[str],
    auto_packages: List[str],
    running_kernel: str,
    keep_previous: int = 1,
) -> Tuple[List[str], List[str]]:
    keep_previous = max(0, keep_previous)
    auto_set = set(auto_packages)
    base_to_packages: Dict[str, Set[str]] = {}
    for package in installed_packages:
        if package not in auto_set:
            continue
        abi = _kernel_package_abi(package)
        if not abi:
            continue
        base_to_packages.setdefault(_kernel_base(abi), set()).add(package)

    running_base = _kernel_base(running_kernel)
    base_sort_keys = {
        base: _kernel_sort_key(base)
        for base in {*base_to_packages.keys(), running_base}
    }
    running_sort_key = base_sort_keys[running_base]
    sorted_bases = sorted(
        base_to_packages,
        key=lambda base: base_sort_keys[base],
        reverse=True,
    )
    keep_bases: Set[str] = {running_base}
    newer_bases = [
        base
        for base in sorted_bases
        if base != running_base and base_sort_keys[base] > running_sort_key
    ]
    keep_bases.update(newer_bases)
    if running_base in base_to_packages:
        older_bases = [
            base
            for base in sorted_bases
            if base != running_base and base_sort_keys[base] <= running_sort_key
        ]
        for base in older_bases:
            if len(keep_bases) >= len(newer_bases) + keep_previous + 1:
                break
            keep_bases.add(base)
    else:
        for base in sorted_bases:
            if base == running_base or base_sort_keys[base] > running_sort_key:
                continue
            if len(keep_bases) >= len(newer_bases) + keep_previous + 1:
                break
            keep_bases.add(base)

    removable_bases = [base for base in sorted_bases if base not in keep_bases]
    packages: List[str] = []
    for base in removable_bases:
        packages.extend(sorted(base_to_packages[base]))
    return packages, removable_bases


def installed_apt_packages() -> List[str]:
    result = run(
        ["dpkg-query", "-W", "-f=${binary:Package}\n"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        message = "Failed to list installed apt packages with dpkg-query."
        if detail:
            message = f"{message} {detail}"
        raise RuntimeError(message)
    return [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]


def apt_auto_packages() -> List[str]:
    result = run(["apt-mark", "showauto"], check=False, capture_output=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        message = "Failed to list auto-installed apt packages with apt-mark."
        if detail:
            message = f"{message} {detail}"
        raise RuntimeError(message)
    return [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]


def cleanup_kernels_supported() -> bool:
    return cmd_exists("apt-get") and cmd_exists("dpkg-query") and cmd_exists("apt-mark")


def run_cleanup_kernels(args: argparse.Namespace) -> bool:
    log_action_start("cleanup-kernels")
    if not cleanup_kernels_supported():
        warn("Kernel cleanup is only supported on apt-based systems.")
        log_action_end("cleanup-kernels", "unsupported")
        return False
    keep_previous = max(0, int(getattr(args, "keep", 1)))
    running_kernel = run(["uname", "-r"], capture_output=True).stdout.strip()
    try:
        installed_packages = installed_apt_packages()
        auto_packages = apt_auto_packages()
    except RuntimeError as exc:
        warn(str(exc))
        log_action_end("cleanup-kernels", "failed")
        return False
    packages, bases = select_old_kernel_packages(
        installed_packages,
        auto_packages,
        running_kernel,
        keep_previous,
    )
    if not packages:
        log("No old auto-installed kernels found for cleanup.")
        log_action_end("cleanup-kernels")
        return True
    log(
        "Old kernel groups eligible for cleanup: "
        + ", ".join(bases)
        + f" ({len(packages)} packages)"
    )
    if getattr(args, "dry_run", False):
        for package in packages:
            log(f"would purge: {package}")
        log_action_end("cleanup-kernels", "dry-run")
        return True
    purge = run_warn_live(
        ["sudo", "apt-get", "purge", "-y", *packages],
        "apt-get purge old kernels",
    )
    if purge.returncode != 0:
        log_action_end("cleanup-kernels", "failed")
        return False
    autoremove = run_warn_live(
        ["sudo", "apt-get", "autoremove", "-y"],
        "apt-get autoremove",
    )
    ok = autoremove.returncode == 0
    log_action_end("cleanup-kernels", "ok" if ok else "failed")
    return ok


def maybe_cleanup_kernels(keep: int) -> None:
    if not cleanup_kernels_supported():
        warn("Old kernel cleanup is only supported on apt-based systems; skipping.")
        return
    if not run_cleanup_kernels(argparse.Namespace(dry_run=False, keep=keep)):
        warn("Old kernel cleanup reported errors.")


def run_cleanup_kernels_cmd(args: argparse.Namespace) -> None:
    if not cleanup_kernels_supported():
        warn("Old kernel cleanup is only supported on apt-based systems; skipping.")
        return
    if not run_cleanup_kernels(args):
        sys.exit(1)


def run_update(cleanup_kernels: bool = False, keep_kernels: int = 1) -> bool:
    log_action_start("update")
    had_errors = False
    if allow_nala() and ensure_nala():
        update_cmd = ["sudo", "nala", "update"]
        upgrade_cmd = ["sudo", "nala", "upgrade", "-y"]
        if in_dialog_mode():
            update_cmd.extend(["-v"])
            upgrade_cmd.extend(["-v", "--raw-dpkg"])
        if run_warn_live(update_cmd, "nala update").returncode != 0:
            had_errors = True
        if run_warn_live(upgrade_cmd, "nala upgrade").returncode != 0:
            had_errors = True
    elif cmd_exists("apt-get"):
        if (
            run_warn_live(["sudo", "apt-get", "update"], "apt-get update").returncode
            != 0
        ):
            had_errors = True
        if (
            run_warn_live(["sudo", "apt-get", "upgrade", "-y"], "apt-get upgrade").returncode
            != 0
        ):
            had_errors = True
    elif cmd_exists("apt"):
        if run_warn_live(["sudo", "apt", "update"], "apt update").returncode != 0:
            had_errors = True
        if run_warn_live(["sudo", "apt", "upgrade", "-y"], "apt upgrade").returncode != 0:
            had_errors = True
    elif cmd_exists("dnf"):
        if run(["sudo", "dnf", "upgrade", "-y"], check=False).returncode != 0:
            had_errors = True
    elif cmd_exists("zypper"):
        if run(["sudo", "zypper", "refresh"], check=False).returncode != 0:
            had_errors = True
        if run(["sudo", "zypper", "update", "-y"], check=False).returncode != 0:
            had_errors = True
    elif cmd_exists("pacman"):
        if run(["sudo", "pacman", "-Syu", "--noconfirm"], check=False).returncode != 0:
            had_errors = True
    else:
        warn("No supported package manager for update.")
    if cmd_exists("snap"):
        if run(["sudo", "snap", "refresh"], check=False).returncode != 0:
            had_errors = True
    if cmd_exists("flatpak"):
        if run(["flatpak", "update", "-y"], check=False).returncode != 0:
            had_errors = True
    if cleanup_kernels and not had_errors:
        maybe_cleanup_kernels(keep_kernels)
    log_action_end("update", "errors" if had_errors else "ok")
    return not had_errors


def run_security() -> None:
    log_action_start("security")
    if cmd_exists("unattended-upgrade"):
        result = run(["sudo", "unattended-upgrade", "--verbose"], check=False)
        if result.returncode != 0:
            warn("unattended-upgrade failed; trying package-manager security updates.")
        else:
            log_action_end("security")
            return
    if allow_nala() and cmd_exists("nala"):
        cmd = ["sudo", "nala", "upgrade", "-y", "--security"]
        if in_dialog_mode():
            cmd.extend(["-v", "--raw-dpkg"])
        result = run(cmd, check=False)
        if result.returncode == 0:
            log_action_end("security")
            return
        warn("nala does not support --security; falling back to a full upgrade.")
        cmd = ["sudo", "nala", "upgrade", "-y"]
        if in_dialog_mode():
            cmd.extend(["-v", "--raw-dpkg"])
        run(cmd)
        log_action_end("security")
        return
    if cmd_exists("apt-get"):
        run(["sudo", "apt-get", "update"])
        run(["sudo", "apt-get", "upgrade", "-y", "--with-new-pkgs"])
        log_action_end("security")
        return
    if cmd_exists("dnf"):
        run(["sudo", "dnf", "upgrade", "-y", "--security"])
        log_action_end("security")
        return
    if cmd_exists("zypper"):
        run(["sudo", "zypper", "patch", "--category", "security", "-y"])
        log_action_end("security")
        return
    if cmd_exists("pacman"):
        warn("Pacman has no separate security-only mode; run update instead.")
        log_action_end("security", "unsupported")
        return
    warn("No supported package manager for security updates.")
    log_action_end("security", "failed")


def build_upgrade_restore_args(
    export_path: Path, *, skip_existing_source_update: bool
) -> argparse.Namespace:
    return argparse.Namespace(
        input=str(export_path),
        apply=True,
        update_sources=True,
        skip_existing_source_update=skip_existing_source_update,
        apply_config=False,
        config_archive=None,
        apply_services=False,
        apply_config_files=False,
        sections="apt_manual,apt_hold,ppas,apt_sources",
        cleanup_extras=False,
        appimage_dirs=None,
        skip_backup=False,
        skip_revert_prompt=False,
    )


def run_upgrade(args: argparse.Namespace) -> None:
    log_action_start("upgrade")
    os_id = get_os_id()
    old_codename = get_codename()
    if os_id not in {"ubuntu", "debian"}:
        warn(f"Distro upgrade not implemented for {os_id}")
        log_action_end("upgrade", "unsupported")
        return
    export_path = Path(default_export_filename())
    log(f"Creating pre-upgrade export at {export_path}")
    export_args = argparse.Namespace(
        output=str(export_path),
        appimage_dirs=None,
        include_config=False,
        config_dirs=None,
        config_exclude=[],
        config_archive=None,
        include_config_files=False,
        config_files=None,
        include_user_tools=False,
        include_services=False,
    )
    export_all(export_args)

    if os_id == "ubuntu":
        if not cmd_exists("do-release-upgrade"):
            fail("do-release-upgrade not available")
        cmd = ["sudo", "do-release-upgrade"]
        if in_dialog_mode():
            cmd.extend(["-f", "DistUpgradeViewText"])
        run(cmd)
        new_codename = get_codename()
        if old_codename and new_codename and old_codename != new_codename:
            update_apt_sources_codename(old_codename, new_codename)
        restore_args = build_upgrade_restore_args(
            export_path, skip_existing_source_update=True
        )
        import_from_file(restore_args)
        if getattr(args, "cleanup_kernels", False):
            maybe_cleanup_kernels(getattr(args, "keep_kernels", 1))
        log_action_end("upgrade")
        return

    if os_id == "debian":
        target_codename = args.target_codename or os.getenv("DISTRODECK_TARGET_CODENAME")
        if not target_codename:
            fail(
                "Debian upgrade requires --target-codename or DISTRODECK_TARGET_CODENAME."
            )
        if not DEBIAN_CODENAME_PATTERN.fullmatch(target_codename):
            warn(
                "Debian target codename does not match the expected lowercase format "
                "(for example 'bookworm' or 'trixie'). Proceeding anyway."
            )
        if not old_codename:
            fail("Unable to detect current Debian codename for upgrade.")
        sources_updated = False
        try:
            update_apt_sources_codename(old_codename, target_codename)
            sources_updated = True
            run(["sudo", "apt-get", "update"])
            run(["sudo", "apt-get", "full-upgrade", "-y"])
            new_codename = get_codename()
            if new_codename and target_codename and new_codename != target_codename:
                warn(
                    "Debian codename does not match target after upgrade; "
                    "sources already set to target."
                )
            restore_args = build_upgrade_restore_args(
                export_path, skip_existing_source_update=True
            )
            import_from_file(restore_args)
            if getattr(args, "cleanup_kernels", False):
                maybe_cleanup_kernels(getattr(args, "keep_kernels", 1))
            log_action_end("upgrade")
            return
        except (subprocess.CalledProcessError, OSError) as exc:
            if sources_updated:
                warn(
                    "Debian upgrade failed after updating APT sources; "
                    "attempting to revert sources to the previous codename."
                )
                try:
                    update_apt_sources_codename(target_codename, old_codename)
                except Exception as revert_err:
                    warn(
                        f"Failed to revert APT sources to {old_codename}: {revert_err}"
                    )
            log_action_end("upgrade", "failed")
            raise exc



def rewrite_codename(line: str, old_codename: str, new_codename: str) -> str:
    if not old_codename or not new_codename:
        return line
    stripped = line.lstrip()
    prefix = line[: len(line) - len(stripped)]
    match = re.match(
        r"^(deb(?:-src)?\s+(?:\[[^\]]*\]\s+)?\S+\s+)(\S+)",
        stripped,
    )
    if match:
        suite = match.group(2)
        if suite == old_codename:
            tail = stripped[match.end(2) :]
            return f"{prefix}{match.group(1)}{new_codename}{tail}"
        return line
    pattern = r"\b" + re.escape(old_codename) + r"\b"
    return re.sub(pattern, new_codename, line)


def replace_codename_tokens(value: str, old_codename: str, new_codename: str) -> Tuple[str, int]:
    parts = re.split(r"(\s+)", value)
    substitutions = 0
    for idx in range(0, len(parts), 2):
        token = parts[idx]
        if token == old_codename:
            parts[idx] = new_codename
            substitutions += 1
        elif token.startswith(f"{old_codename}-"):
            parts[idx] = f"{new_codename}{token[len(old_codename):]}"
            substitutions += 1
    return "".join(parts), substitutions


def write_root_file(path: Path, content: str) -> None:
    if not content.endswith("\n"):
        content += "\n"
    if os.geteuid() == 0:
        path.write_text(content, encoding="utf-8")
        return
    run(["sudo", "tee", str(path)], input_text=content)


def parse_apt_update_issues(output: str) -> Tuple[List[str], List[str]]:
    urls = set()
    key_ids = set()
    for line in output.splitlines():
        if "NO_PUBKEY" in line:
            for match in re.findall(r"NO_PUBKEY\s+([0-9A-F]+)", line):
                key_ids.add(match)
        is_error = False
        if line.startswith(("E:", "Err:", "Error:")):
            is_error = True
        if "Failed to fetch" in line:
            is_error = True
        if "does not have a Release file" in line:
            is_error = True
        if not is_error:
            continue
        match = re.search(r"The repository '([^']+)' does not have a Release file", line)
        if match:
            repo = match.group(1).split()[0]
            urls.add(repo)
            continue
        for match in re.findall(r"(https?://[^\s']+)", line):
            urls.add(match)
    return sorted(urls), sorted(key_ids)


def comment_out_apt_repos(urls: List[str]) -> List[str]:
    if not urls:
        return []
    changed_files = []
    for path in apt_source_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            warn(f"Failed to read apt sources: {path}")
            continue
        updated = []
        changed = 0
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("#"):
                updated.append(line)
                continue
            if not (stripped.startswith("deb ") or stripped.startswith("deb-src ")):
                updated.append(line)
                continue
            if any(url in line for url in urls):
                updated.append(f"# disabled by distrodeck repo-repair: {line}")
                changed += 1
            else:
                updated.append(line)
        if changed:
            write_root_file(path, "\n".join(updated))
            changed_files.append(str(path))
    return changed_files


def refresh_apt_keys(key_ids: List[str]) -> List[str]:
    if not key_ids:
        return []
    if not cmd_exists("gpg"):
        warn("gpg not available; cannot refresh apt keys.")
        return []
    refreshed = []
    with tempfile.TemporaryDirectory(prefix="distrodeck-gnupg-") as gnupg_home:
        env = os.environ.copy()
        env["GNUPGHOME"] = gnupg_home
        for key_id in key_ids:
            result = run(
                ["gpg", "--batch", "--keyserver", "keyserver.ubuntu.com", "--recv-keys", key_id],
                check=False,
                env=env,
            )
            if result.returncode != 0:
                warn(f"Failed to fetch key: {key_id}")
                continue
            tmp_key = Path(tempfile.mkstemp(prefix="distrodeck-key-", suffix=".gpg")[1])
            run(
                ["gpg", "--batch", "--yes", "--output", str(tmp_key), "--export", key_id],
                check=False,
                env=env,
            )
            if tmp_key.exists():
                run(
                    ["sudo", "install", "-m", "0644", str(tmp_key), f"/etc/apt/trusted.gpg.d/{key_id}.gpg"],
                    check=False,
                )
                try:
                    tmp_key.unlink()
                except OSError:
                    pass
                refreshed.append(key_id)
    return refreshed


def run_repo_repair() -> None:
    log_action_start("repo-repair")
    if not cmd_exists("apt-get"):
        msg = "apt-get not available; repo repair is only supported for apt-based systems."
        if in_dialog_mode() and cmd_exists("dialog"):
            dialog_msgbox("Repo Repair", msg)
        else:
            warn(msg)
        log_action_end("repo-repair", "unsupported")
        return
    if not ensure_sudo():
        log_action_end("repo-repair", "cancelled")
        return
    def _run_apt_update(_progress):
        return run(["sudo", "apt-get", "update"], check=False, capture_output=True)

    result = dialog_run_with_progress(
        "Repo Repair", "Checking apt repositories...", _run_apt_update
    )
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    urls, key_ids = parse_apt_update_issues(output)
    if not urls and not key_ids:
        msg = "No apt repo issues detected."
        if in_dialog_mode() and cmd_exists("dialog"):
            dialog_msgbox("Repo Repair", msg)
        else:
            log(msg)
        log_action_end("repo-repair", "no-issues")
        return
    summary_lines = []
    if urls:
        summary_lines.append("Repositories to disable:")
        summary_lines.extend([f"  {url}" for url in urls])
    if key_ids:
        summary_lines.append("Keys to refresh:")
        summary_lines.extend([f"  {key_id}" for key_id in key_ids])
    summary = "\n".join(summary_lines)
    confirm = False
    if in_dialog_mode() and cmd_exists("dialog"):
        confirm = dialog_yesno("Repo Repair", f"{summary}\n\nApply these changes?")
    elif sys.stdin.isatty():
        reply = input(f"{summary}\n\nApply these changes? [y/N]: ").strip().lower()
        confirm = reply in {"y", "yes"}
    if not confirm:
        log_action_end("repo-repair", "cancelled")
        return
    changed_files = comment_out_apt_repos(urls)
    refreshed_keys = refresh_apt_keys(key_ids)
    if in_dialog_mode() and cmd_exists("dialog"):
        run(["dialog", "--clear"], check=False)
        dialog_run_with_progress(
            "Repo Repair",
            "Re-running apt-get update...",
            lambda _progress: run(
                ["sudo", "apt-get", "update"], check=False, capture_output=True
            ),
        )
    else:
        run(["sudo", "apt-get", "update"], check=False)
    details = []
    if changed_files:
        details.append("Disabled repos in:")
        details.extend([f"  {path}" for path in changed_files])
    if refreshed_keys:
        details.append("Refreshed keys:")
        details.extend([f"  {key_id}" for key_id in refreshed_keys])
    if not details:
        details.append("No sources or keys were changed.")
    message = "\n".join(details)
    if in_dialog_mode() and cmd_exists("dialog"):
        dialog_msgbox("Repo Repair", message)
    else:
        log(message)
    log_action_end("repo-repair")


def update_apt_sources_codename(old_codename: str, new_codename: str) -> None:
    if not old_codename or not new_codename:
        warn("Skipping apt source update; missing release codename.")
        return
    active_sources = active_apt_sources()
    for path in apt_source_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            warn(f"Failed to read apt sources: {path}")
            continue
        # Pre-populate with rewritten active sources to prevent duplicate re-enables below.
        for line in lines:
            stripped = line.lstrip()
            deb_line: Optional[str] = None
            if stripped.startswith("#"):
                match = re.match(r"^\s*#\s*(deb(?:-src)?\s+.+)$", line)
                if match:
                    deb_line = match.group(1).strip()
            elif stripped.startswith("deb ") or stripped.startswith("deb-src "):
                deb_line = stripped
            if deb_line is not None and old_codename in deb_line:
                normalized = normalize_apt_source_line(
                    rewrite_codename(deb_line, old_codename, new_codename)
                )
                active_sources.add(normalized)
        updated_lines: List[str] = []
        added_sources: Set[str] = set()
        changed = 0
        for line in lines:
            stripped = line.lstrip()
            prefix = line[: len(line) - len(stripped)]
            if stripped.startswith("#"):
                match = re.match(r"^\s*#\s*(deb(?:-src)?\s+.+)$", line)
                if match:
                    deb_line = match.group(1).strip()
                    updated_lines.append(line)
                    if old_codename in deb_line:
                        new_line = prefix + rewrite_codename(
                            deb_line, old_codename, new_codename
                        )
                        normalized = normalize_apt_source_line(new_line)
                        if normalized not in active_sources and normalized not in added_sources:
                            updated_lines.append(new_line)
                            added_sources.add(normalized)
                            active_sources.add(normalized)
                            changed += 1
                    continue
                updated_lines.append(line)
                continue
            if stripped.startswith("deb ") or stripped.startswith("deb-src "):
                if old_codename in stripped:
                    new_line = prefix + rewrite_codename(
                        stripped, old_codename, new_codename
                    )
                    if new_line != line:
                        changed += 1
                    updated_lines.append(new_line)
                    active_sources.add(normalize_apt_source_line(new_line))
                    continue
            updated_lines.append(line)
        if updated_lines != lines:
            write_root_file(path, "\n".join(updated_lines))
            log(f"Updated apt sources in {path} ({changed} entries)")
    for path in apt_deb822_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            warn(f"Failed to read apt sources: {path}")
            continue
        updated_lines = []
        changed = 0
        for line in lines:
            stripped = line.lstrip()
            if stripped.startswith("#"):
                updated_lines.append(line)
                continue
            match = re.match(
                r"^(\s*(?:Suite|Suites|Codename):\s*)(.*)$",
                line,
                flags=re.IGNORECASE,
            )
            if match:
                prefix, value = match.groups()
                new_value, num_subs = replace_codename_tokens(
                    value,
                    old_codename,
                    new_codename,
                )
                if num_subs > 0:
                    changed += 1
                    updated_lines.append(prefix + new_value)
                    continue
            updated_lines.append(line)
        if updated_lines != lines:
            write_root_file(path, "\n".join(updated_lines))
            log(f"Updated deb822 apt sources in {path} ({changed} entries)")


def parse_export_file(path: Path) -> dict:
    data = {
        "apt_manual": [],
        "apt_hold": [],
        "ppas": [],
        "apt_sources": [],
        "snap": [],
        "flatpak": [],
        "pacman": [],
        "dnf": [],
        "zypper": [],
        "appimage": [],
        "pipx": [],
        "npm_global": [],
        "composer_global": [],
        "nuget_global": [],
        "cargo": [],
        "gem": [],
        "go": [],
        "config_snapshot": [],
        "services_enabled": [],
        "services_active": [],
        "config_files": [],
        "codename": "",
    }
    section = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("codename="):
            data["codename"] = line.split("=", 1)[1]
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section in data:
            data[section].append(line)
    return data


def export_section_paths(entries: List[str]) -> List[str]:
    paths = []
    for entry in entries:
        if entry.startswith("path="):
            path_part = entry.split(" content_b64=", 1)[0]
            path = path_part.split("=", 1)[1]
            if path:
                paths.append(path)
    return paths


def parse_config_snapshot_entries(entries: List[str]) -> Tuple[List[str], List[str]]:
    dirs = []
    excludes = []
    for entry in entries:
        if entry.startswith("dirs="):
            raw = entry.split("=", 1)[1]
            dirs = [part for part in raw.split(":") if part]
        elif entry.startswith("exclude="):
            excludes.append(entry.split("=", 1)[1])
    return dirs, excludes


def write_export_subset(path: Path, data: dict, allowed_sections: set) -> None:
    out_lines = [
        "# distrodeck export v1",
        f"exported_at={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"distro_id={get_os_id()}",
        f"codename={data.get('codename', '')}",
        "",
    ]
    for name in EXPORT_SECTION_ORDER:
        if name not in allowed_sections:
            continue
        items = data.get(name, [])
        out_lines.extend([f"[{name}]", *items, ""])
    path.write_text("\n".join(out_lines) + "\n", encoding="utf-8")


def import_from_file(args: argparse.Namespace) -> None:
    log_action_start("import")
    path = Path(args.input)
    if not path.exists():
        fail(f"Input file not found: {args.input}")
    data = parse_export_file(path)
    progress = DialogProgress("Import", "Preparing import...")
    progress.start()
    backup_path = None
    sections = {
        "apt_manual",
        "apt_hold",
        "ppas",
        "apt_sources",
        "snap",
        "flatpak",
        "pacman",
        "dnf",
        "zypper",
        "appimage",
    }
    if data["config_snapshot"]:
        sections.add("config_snapshot")
    if data["services_enabled"]:
        sections.add("services_enabled")
    if data["config_files"]:
        sections.add("config_files")
    if args.sections:
        selected_sections = {item.strip() for item in args.sections.split(",") if item.strip()}
    else:
        selected_sections = sections
    def wants(section: str) -> bool:
        return section in selected_sections
    try:
        echo_output = not in_dialog_mode()
        errors: List[str] = []

        def import_run(cmd, title: str, input_text: Optional[str] = None):
            result = run_logged(
                cmd,
                title,
                echo=echo_output,
                input_text=input_text,
            )
            if result.returncode != 0:
                details = (result.stderr or result.stdout or "").strip()
                message = f"{title} failed (exit {result.returncode})"
                if details:
                    snippet = details if len(details) <= 800 else details[:800] + "..."
                    message = f"{message}:\n{snippet}"
                errors.append(message)
            return result

        if not getattr(args, "skip_backup", False):
            progress.update("Creating backup before import...")
            backup_path = Path(backup_export_filename())
            config_dirs, config_excludes = parse_config_snapshot_entries(data["config_snapshot"])
            config_files = export_section_paths(data["config_files"])
            backup_args = argparse.Namespace(
                output=str(backup_path),
                appimage_dirs=args.appimage_dirs,
                include_config="config_snapshot" in selected_sections,
                config_dirs=":".join(config_dirs) if config_dirs else None,
                config_exclude=config_excludes,
                config_archive=None,
                include_config_files="config_files" in selected_sections,
                config_files=":".join(config_files) if config_files else None,
                include_user_tools=False,
                include_services="services_enabled" in selected_sections,
            )
            previous_dialog = os.environ.get("DISTRODECK_DIALOG")
            os.environ["DISTRODECK_DIALOG"] = "0"
            try:
                export_all(backup_args)
            finally:
                if previous_dialog is None:
                    os.environ.pop("DISTRODECK_DIALOG", None)
                else:
                    os.environ["DISTRODECK_DIALOG"] = previous_dialog
            if selected_sections:
                backup_data = parse_export_file(backup_path)
                write_export_subset(backup_path, backup_data, selected_sections)
            log(f"Created pre-import backup for this attempt at: {backup_path}")
        log(
            "Plan: "
            f"{len(data['apt_manual'])} apt packages, "
            f"{len(data['ppas'])} PPAs, "
            f"{len(data['snap'])} snaps, "
            f"{len(data['flatpak'])} flatpaks, "
            f"{len(data['pacman'])} pacman packages, "
            f"{len(data['dnf'])} dnf packages, "
            f"{len(data['zypper'])} zypper packages, "
            f"{len(data['appimage'])} appimages"
        )
        if not args.apply:
            progress.update("Diffing current system state...")
            log("Dry-run diff (desired vs current):")
            current = {
                "apt_manual": export_apt_manual(),
                "apt_hold": export_apt_hold(),
                "ppas": export_ppas(),
                "apt_sources": export_apt_sources(),
                "snap": [normalize_snap_entry(item) for item in export_snaps()],
                "flatpak": [normalize_flatpak_entry(item) for item in export_flatpaks()],
                "pacman": export_pacman(),
                "dnf": export_dnf(),
                "zypper": export_zypper(),
                "appimage": export_appimages(get_appimage_dirs(args.appimage_dirs)),
            }
            if wants("apt_manual"):
                progress.update("Diffing apt packages...")
                log_diff("apt_manual", *diff_items(data["apt_manual"], current["apt_manual"]))
            if wants("apt_hold"):
                progress.update("Diffing apt holds...")
                log_diff("apt_hold", *diff_items(data["apt_hold"], current["apt_hold"]))
            if wants("ppas"):
                progress.update("Diffing PPAs...")
                log_diff("ppas", *diff_items(data["ppas"], current["ppas"]))
            if wants("apt_sources"):
                progress.update("Diffing apt sources...")
                log_diff("apt_sources", *diff_items(data["apt_sources"], current["apt_sources"]))
            if wants("snap"):
                progress.update("Diffing snaps...")
                desired = [normalize_snap_entry(item) for item in data["snap"]]
                log_diff("snap", *diff_items(desired, current["snap"]))
            if wants("flatpak"):
                progress.update("Diffing flatpaks...")
                desired = [normalize_flatpak_entry(item) for item in data["flatpak"]]
                log_diff("flatpak", *diff_items(desired, current["flatpak"]))
            if wants("appimage"):
                progress.update("Diffing AppImages...")
                log_diff("appimage", *diff_items(data["appimage"], current["appimage"]))
                missing = [item for item in data["appimage"] if not Path(item).exists()]
                if missing:
                    log("appimage missing on disk: " + ", ".join(missing))
            if wants("config_files"):
                progress.update("Checking config files...")
                log(f"config_files: {len(data['config_files'])} entries in export.")
            if not args.apply_config and not args.apply_services and not args.cleanup_extras and not args.apply_config_files:
                log("Dry-run only. Re-run with --apply to install.")
                return

        if args.apply:
            if wants("ppas") and data["ppas"] and cmd_exists("add-apt-repository"):
                progress.update("Adding PPAs...")
                import_run(
                    ["sudo", "apt-get", "update"],
                    "apt-get update",
                )
                for ppa in data["ppas"]:
                    import_run(
                        ["sudo", "add-apt-repository", "-y", ppa],
                        f"add-apt-repository {ppa}",
                    )

            if wants("apt_sources") and data["apt_sources"] and cmd_exists("apt-get"):
                progress.update("Restoring apt sources...")
                new_codename = get_codename()
                sources_lines = []
                existing_sources = active_apt_sources()
                for src in data["apt_sources"]:
                    if args.update_sources:
                        src = rewrite_codename(src, data["codename"], new_codename)
                    normalized = normalize_apt_source_line(src)
                    if normalized in existing_sources:
                        continue
                    sources_lines.append(src)
                    existing_sources.add(normalized)
                if sources_lines:
                    content = "\n".join(sources_lines) + "\n"
                    import_run(
                        ["sudo", "tee", "/etc/apt/sources.list.d/distrodeck-import.list"],
                        "write apt sources",
                        input_text=content,
                    )
                else:
                    log("No new apt sources to add; all entries already present.")
                if args.update_sources and not getattr(
                    args, "skip_existing_source_update", False
                ):
                    update_apt_sources_codename(data["codename"], new_codename)

            if wants("apt_manual") and data["apt_manual"] and cmd_exists("apt-get"):
                progress.update("Installing apt packages...")
                import_run(
                    ["sudo", "apt-get", "update"],
                    "apt-get update",
                )
                import_run(
                    ["sudo", "apt-get", "install", "-y", *data["apt_manual"]],
                    "apt-get install apt packages",
                )
            elif wants("apt_manual") and data["apt_manual"]:
                warn("apt-get not available; skipping apt package install")

            if wants("apt_hold") and data["apt_hold"] and cmd_exists("apt-mark"):
                progress.update("Applying apt holds...")
                for pkg in data["apt_hold"]:
                    import_run(
                        ["sudo", "apt-mark", "hold", pkg],
                        f"apt-mark hold {pkg}",
                    )

            if wants("snap") and data["snap"] and cmd_exists("snap"):
                progress.update("Installing snaps...")
                for entry in data["snap"]:
                    parts = entry.split()
                    name = parts[0] if parts else ""
                    channel = ""
                    classic = False
                    for part in parts[1:]:
                        if part.startswith("channel="):
                            channel = part.split("=", 1)[1]
                        if part.startswith("classic="):
                            classic = part.split("=", 1)[1] == "true"
                    if not name:
                        continue
                    cmd = ["sudo", "snap", "install", name]
                    if channel:
                        cmd.append(f"--channel={channel}")
                    if classic:
                        cmd.append("--classic")
                    import_run(
                        cmd,
                        f"snap install {name}",
                    )

            if wants("flatpak") and data["flatpak"] and cmd_exists("flatpak"):
                progress.update("Installing flatpaks...")
                for entry in data["flatpak"]:
                    app = ""
                    remote = ""
                    for part in entry.split():
                        if part.startswith("app="):
                            app = part.split("=", 1)[1]
                        if part.startswith("remote="):
                            remote = part.split("=", 1)[1]
                    if not app:
                        continue
                    if remote:
                        import_run(
                            ["flatpak", "install", "-y", remote, app],
                            f"flatpak install {app}",
                        )
                    else:
                        import_run(
                            ["flatpak", "install", "-y", app],
                            f"flatpak install {app}",
                        )

            if wants("appimage") and data["appimage"]:
                progress.update("Restoring AppImages...")
                for path_str in data["appimage"]:
                    path = Path(path_str)
                    if path.exists():
                        path.chmod(path.stat().st_mode | 0o111)
                    else:
                        warn(f"AppImage not found: {path_str}")

            if wants("pacman") and data["pacman"] and cmd_exists("pacman"):
                progress.update("Installing pacman packages...")
                import_run(
                    ["sudo", "pacman", "-S", "--needed", "--noconfirm", *data["pacman"]],
                    "pacman install packages",
                )
            elif wants("pacman") and data["pacman"]:
                warn("pacman not available; skipping pacman package install")

            if wants("dnf") and data["dnf"] and cmd_exists("dnf"):
                progress.update("Installing dnf packages...")
                import_run(
                    ["sudo", "dnf", "install", "-y", *data["dnf"]],
                    "dnf install packages",
                )
            elif wants("dnf") and data["dnf"]:
                warn("dnf not available; skipping dnf package install")

            if wants("zypper") and data["zypper"] and cmd_exists("zypper"):
                progress.update("Installing zypper packages...")
                import_run(
                    ["sudo", "zypper", "install", "-y", *data["zypper"]],
                    "zypper install packages",
                )
            elif wants("zypper") and data["zypper"]:
                warn("zypper not available; skipping zypper package install")

        if args.apply_config and wants("config_snapshot"):
            progress.update("Restoring config snapshot...")
            archive = args.config_archive
            if not archive and data["config_snapshot"]:
                for entry in data["config_snapshot"]:
                    if entry.startswith("archive="):
                        archive = entry.split("=", 1)[1]
                        break
            if not archive:
                warn("Config snapshot not found in export file.")
            else:
                if not Path(archive).exists():
                    warn(f"Config snapshot not found on disk: {archive}")
                else:
                    if confirm_risky_extract(archive):
                        import_run(
                            ["sudo", "tar", "-xzf", archive, "-C", "/"],
                            "extract config snapshot",
                        )
                    else:
                        warn("Skipped config snapshot extraction.")

        if args.apply_services and wants("services_enabled"):
            progress.update("Enabling services...")
            if not cmd_exists("systemctl"):
                warn("systemctl not available; skipping service enablement.")
            else:
                for service in data["services_enabled"]:
                    import_run(
                        ["sudo", "systemctl", "enable", service],
                        f"systemctl enable {service}",
                    )

        if args.cleanup_extras:
            progress.update("Removing extra packages...")
            if wants("snap") and cmd_exists("snap"):
                desired = [normalize_snap_entry(item) for item in data["snap"]]
                _, extra = diff_items(desired, [normalize_snap_entry(item) for item in export_snaps()])
                for name in extra:
                    import_run(
                        ["sudo", "snap", "remove", name],
                        f"snap remove {name}",
                    )
            if wants("flatpak") and cmd_exists("flatpak"):
                desired = [normalize_flatpak_entry(item) for item in data["flatpak"]]
                _, extra = diff_items(desired, [normalize_flatpak_entry(item) for item in export_flatpaks()])
                for app in extra:
                    if app:
                        import_run(
                            ["flatpak", "uninstall", "-y", app],
                            f"flatpak uninstall {app}",
                        )

        if args.apply_config_files and wants("config_files"):
            progress.update("Restoring config files...")
            home = Path.home().resolve()
            for entry in data["config_files"]:
                path = ""
                content_b64 = ""
                if " content_b64=" in entry and entry.startswith("path="):
                    path_part, content_part = entry.split(" content_b64=", 1)
                    path = path_part.split("=", 1)[1]
                    content_b64 = content_part
                if not path or not content_b64:
                    continue
                try:
                    content = base64.b64decode(content_b64.encode("ascii"))
                except ValueError:
                    warn(f"Invalid base64 content for: {path}")
                    continue
                target = Path(path).expanduser()
                try:
                    needs_sudo = not str(target.resolve()).startswith(str(home))
                except OSError:
                    needs_sudo = True
                if needs_sudo and not cmd_exists("sudo"):
                    warn(f"sudo not available; skipping config file: {path}")
                    continue
                if needs_sudo:
                    parent = target.parent
                    import_run(
                        ["sudo", "mkdir", "-p", str(parent)],
                        f"mkdir {parent}",
                    )
                    with tempfile.NamedTemporaryFile(delete=False) as tmp:
                        tmp.write(content)
                        tmp_path = tmp.name
                    import_run(
                        ["sudo", "install", "-m", "0644", tmp_path, str(target)],
                        f"install config file {target}",
                    )
                    try:
                        os.unlink(tmp_path)
                    except OSError:
                        # Best-effort cleanup: failure to remove the temporary file is non-fatal.
                        pass
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
        if errors:
            raise RuntimeError("\n\n".join(errors))
    except Exception as exc:
        error_message = str(exc)
        if isinstance(exc, subprocess.CalledProcessError):
            details = (exc.stderr or exc.stdout or "").strip()
            if details:
                error_message = f"{error_message}\n{details}"
        backup_ready = backup_path is not None and backup_path.exists()
        if getattr(args, "skip_revert_prompt", False):
            warn(f"Import failed: {error_message}")
            return
        if in_dialog_mode() and cmd_exists("dialog"):
            message = f"Import failed:\n{error_message}"
            if backup_ready:
                message += f"\n\nBackup: {backup_path}\nRevert using this backup?"
                if dialog_yesno("Import Failed", message):
                    revert_args = argparse.Namespace(
                        input=str(backup_path),
                        apply=True,
                        update_sources=False,
                        apply_config=args.apply_config,
                        config_archive=None,
                        apply_services=args.apply_services,
                        apply_config_files=args.apply_config_files,
                        sections=",".join(selected_sections),
                        cleanup_extras=args.cleanup_extras,
                        appimage_dirs=args.appimage_dirs,
                        skip_backup=True,
                        skip_revert_prompt=True,
                    )
                    import_from_file(revert_args)
            else:
                dialog_msgbox("Import Failed", message)
        else:
            warn(f"Import failed: {error_message}")
            if backup_ready and sys.stdin.isatty():
                reply = input(f"Revert using backup {backup_path}? [y/N]: ").strip().lower()
                if reply in {"y", "yes"}:
                    revert_args = argparse.Namespace(
                        input=str(backup_path),
                        apply=True,
                        update_sources=False,
                        apply_config=args.apply_config,
                        config_archive=None,
                        apply_services=args.apply_services,
                        apply_config_files=args.apply_config_files,
                        sections=",".join(selected_sections),
                        cleanup_extras=args.cleanup_extras,
                        appimage_dirs=args.appimage_dirs,
                        skip_backup=True,
                        skip_revert_prompt=True,
                    )
                    import_from_file(revert_args)
        return
    finally:
        progress.close("Finalizing import...")
        log_action_end("import")


def run_doctor(args: argparse.Namespace) -> None:
    log_action_start("doctor")
    checks: List[Dict[str, object]] = []
    os_id = get_os_id()
    codename = get_codename()
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    native_pm = {
        "ubuntu": "apt-get",
        "debian": "apt-get",
        "fedora": "dnf",
        "rhel": "dnf",
        "centos": "dnf",
        "arch": "pacman",
        "manjaro": "pacman",
        "opensuse": "zypper",
        "opensuse-leap": "zypper",
        "opensuse-tumbleweed": "zypper",
    }
    required_pm = native_pm.get(os_id)
    if required_pm:
        if cmd_exists(required_pm):
            _doctor_add_check(
                checks,
                "package_manager",
                "ok",
                f"Detected required package manager: {required_pm}",
            )
        else:
            _doctor_add_check(
                checks,
                "package_manager",
                "blocker",
                f"Required package manager not found: {required_pm}",
                remediation=f"Install {required_pm} or run distrodeck on a supported system for {os_id}.",
            )
    else:
        _doctor_add_check(
            checks,
            "os_support",
            "warn",
            f"OS '{os_id}' is not in the supported list.",
            remediation="Use Ubuntu/Debian/Fedora/RHEL/CentOS/Arch/Manjaro/openSUSE where possible.",
        )

    optional_tools: List[Tuple[str, str]] = [
        ("snap", "Snap package manager"),
        ("flatpak", "Flatpak package manager"),
    ]
    if required_pm == "apt-get" or cmd_exists("apt-get"):
        optional_tools.extend(
            [
                ("nala", "Apt UI/formatter"),
                ("add-apt-repository", "Manage PPAs and apt repositories"),
                ("do-release-upgrade", "Ubuntu distro upgrade tool"),
            ]
        )
    for name, desc in optional_tools:
        if cmd_exists(name):
            _doctor_add_check(checks, f"tool:{name}", "ok", f"{name} available ({desc})")
        else:
            _doctor_add_check(
                checks,
                f"tool:{name}",
                "warn",
                f"{name} not found ({desc})",
                remediation=f"Install {name} if you need workflows that depend on it.",
            )

    try:
        usage = shutil.disk_usage("/")
        free_gb = usage.free / (1024**3)
        if free_gb < 1.0:
            _doctor_add_check(
                checks,
                "disk_space",
                "blocker",
                f"Low disk space on / ({free_gb:.1f} GB free)",
                remediation="Free disk space before export/import operations.",
                details={"free_gb": round(free_gb, 2)},
            )
        elif free_gb < 5.0:
            _doctor_add_check(
                checks,
                "disk_space",
                "warn",
                f"Disk space on / is limited ({free_gb:.1f} GB free)",
                remediation="Recommended free space is at least 5 GB for safer operations.",
                details={"free_gb": round(free_gb, 2)},
            )
        else:
            _doctor_add_check(
                checks,
                "disk_space",
                "ok",
                f"Disk space check passed on / ({free_gb:.1f} GB free)",
                details={"free_gb": round(free_gb, 2)},
            )
    except OSError as exc:
        _doctor_add_check(
            checks,
            "disk_space",
            "warn",
            f"Disk space check failed: {exc}",
            remediation="Verify available disk space manually with 'df -h'.",
        )

    try:
        with socket.create_connection(("1.1.1.1", 53), timeout=2):
            _doctor_add_check(checks, "network", "ok", "Network connectivity check passed")
    except OSError:
        _doctor_add_check(
            checks,
            "network",
            "warn",
            "Network connectivity check failed",
            remediation="Verify internet/DNS access before import or upgrade operations.",
        )

    reboot_required = Path("/var/run/reboot-required")
    if reboot_required.exists():
        _doctor_add_check(
            checks,
            "reboot_required",
            "warn",
            "System indicates a reboot is required",
            remediation="Reboot before running risky update/import workflows.",
        )
    elif cmd_exists("needs-restarting"):
        result = run(["needs-restarting", "-r"], check=False, capture_output=True)
        if result.returncode != 0:
            _doctor_add_check(
                checks,
                "reboot_required",
                "warn",
                "needs-restarting indicates reboot is required",
                remediation="Reboot before running risky update/import workflows.",
            )
        else:
            _doctor_add_check(checks, "reboot_required", "ok", "No reboot required")
    else:
        _doctor_add_check(checks, "reboot_required", "ok", "No reboot requirement detected")

    if cmd_exists("apt-get"):
        hosts, malformed_uris = _doctor_apt_repo_hosts()
        if malformed_uris:
            _doctor_add_check(
                checks,
                "apt_repo_uri_format",
                "warn",
                "Some APT source URIs are malformed and were skipped",
                remediation="Fix malformed APT source lines before running upgrades/imports.",
                details={"malformed_uris": malformed_uris},
            )
        if hosts:
            # Resolve repository hosts concurrently to avoid cumulative DNS timeouts.
            resolution_results: Dict[str, bool] = {}
            resolution_lock = threading.Lock()

            def _resolve_host_for_doctor(hostname: str) -> None:
                result = _doctor_check_host_resolution(hostname)
                with resolution_lock:
                    resolution_results[hostname] = result

            threads: List[threading.Thread] = []
            for host in hosts:
                t = threading.Thread(target=_resolve_host_for_doctor, args=(host,), daemon=True)
                threads.append(t)
                t.start()

            for t in threads:
                t.join()

            unresolved = [host for host in hosts if not resolution_results.get(host, False)]
            if unresolved:
                _doctor_add_check(
                    checks,
                    "apt_repo_host_resolution",
                    "blocker",
                    "One or more APT repository hosts could not be resolved",
                    remediation="Fix DNS/network or remove broken apt sources before import/upgrade.",
                    details={"unresolved_hosts": unresolved},
                )
            else:
                _doctor_add_check(
                    checks,
                    "apt_repo_host_resolution",
                    "ok",
                    "All configured APT repository hosts resolved successfully",
                    details={"hosts_checked": len(hosts)},
                )
        else:
            _doctor_add_check(
                checks,
                "apt_repo_host_resolution",
                "warn",
                "No active APT repository hosts detected",
                remediation="Verify /etc/apt/sources.list and /etc/apt/sources.list.d/*.sources.",
            )

        try:
            apt_rc, apt_output = _doctor_probe_apt_metadata()
        except subprocess.TimeoutExpired:
            _doctor_add_check(
                checks,
                "apt_metadata",
                "warn",
                "APT metadata probe timed out",
                remediation="Run 'apt-get update' manually and resolve slow/unresponsive repositories.",
            )
        except OSError as exc:
            _doctor_add_check(
                checks,
                "apt_metadata",
                "warn",
                "APT metadata probe failed due to an OS error",
                remediation="Check disk space, permissions, and APT configuration; then re-run 'distrodeck doctor'.",
                details={"error": str(exc)},
            )
        else:
            bad_urls, missing_keys = parse_apt_update_issues(apt_output)
            issue_details: Dict[str, object] = {}
            issue_summaries: List[str] = []
            remediations: List[str] = []
            if missing_keys:
                issue_details["missing_keys"] = missing_keys
                issue_summaries.append("missing public keys")
                remediations.append("Run 'distrodeck repo-repair' or refresh missing apt keys.")
            if bad_urls:
                issue_details["broken_repos"] = bad_urls
                issue_summaries.append("broken repositories")
                remediations.append("Run 'distrodeck repo-repair' and disable/fix broken repositories.")
            if issue_details:
                seen_remediations: Set[str] = set()
                unique_remediations: List[str] = []
                for rem in remediations:
                    if rem in seen_remediations:
                        continue
                    seen_remediations.add(rem)
                    unique_remediations.append(rem)
                _doctor_add_check(
                    checks,
                    "apt_metadata",
                    "blocker",
                    f"APT metadata validation found {' and '.join(issue_summaries)}",
                    remediation=" ".join(unique_remediations),
                    details=issue_details,
                )
            else:
                if apt_rc == 0:
                    _doctor_add_check(
                        checks,
                        "apt_metadata",
                        "ok",
                        "APT repository metadata validation passed",
                    )
                else:
                    tail = [line for line in apt_output.splitlines() if line.strip()][-3:]
                    _doctor_add_check(
                        checks,
                        "apt_metadata",
                        "warn",
                        "APT metadata probe failed with a non-zero exit code",
                        remediation="Run 'apt-get update' manually and inspect output.",
                        details={"exit_code": apt_rc, "tail": tail},
                    )
    elif cmd_exists("dnf"):
        try:
            result = run(
                ["dnf", "repolist", "--enabled"],
                check=False,
                capture_output=True,
                timeout=DOCTOR_REPO_METADATA_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            _doctor_add_check(
                checks,
                "repo_metadata",
                "warn",
                f"DNF repository listing timed out after {DOCTOR_REPO_METADATA_TIMEOUT_SECONDS}s",
                remediation="Check network/repository health, then re-run 'dnf repolist --enabled'.",
            )
        else:
            if result.returncode == 0:
                _doctor_add_check(checks, "repo_metadata", "ok", "DNF repository listing succeeded")
            else:
                _doctor_add_check(
                    checks,
                    "repo_metadata",
                    "warn",
                    "DNF repository listing failed",
                    remediation="Run 'dnf repolist --enabled' and resolve repository issues.",
                )
    elif cmd_exists("zypper"):
        try:
            result = run(
                ["zypper", "repos"],
                check=False,
                capture_output=True,
                timeout=DOCTOR_REPO_METADATA_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            _doctor_add_check(
                checks,
                "repo_metadata",
                "warn",
                f"Zypper repository listing timed out after {DOCTOR_REPO_METADATA_TIMEOUT_SECONDS}s",
                remediation="Check network/repository health, then re-run 'zypper repos'.",
            )
        else:
            if result.returncode == 0:
                _doctor_add_check(checks, "repo_metadata", "ok", "Zypper repository listing succeeded")
            else:
                _doctor_add_check(
                    checks,
                    "repo_metadata",
                    "warn",
                    "Zypper repository listing failed",
                    remediation="Run 'zypper repos' and resolve repository issues.",
                )
    elif cmd_exists("pacman"):
        try:
            result = run(
                ["pacman", "-Si", "pacman"],
                check=False,
                capture_output=True,
                timeout=DOCTOR_REPO_METADATA_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            _doctor_add_check(
                checks,
                "repo_metadata",
                "warn",
                f"Pacman repository metadata query timed out after {DOCTOR_REPO_METADATA_TIMEOUT_SECONDS}s",
                remediation="Check network/repository health, then re-run 'pacman -Si pacman'.",
            )
        else:
            if result.returncode == 0:
                _doctor_add_check(checks, "repo_metadata", "ok", "Pacman repository metadata query succeeded")
            else:
                _doctor_add_check(
                    checks,
                    "repo_metadata",
                    "warn",
                    "Pacman repository metadata query failed",
                    remediation="Run 'pacman -Si pacman' and resolve repository issues.",
                )

    overall = _doctor_status(checks)
    summary = _doctor_summary(checks)
    payload = {
        "status": overall,
        "timestamp": now,
        "os": {"id": os_id, "codename": codename or ""},
        "summary": summary,
        "checks": checks,
    }

    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"Doctor report for os_id={os_id}" + (f", codename={codename}" if codename else ""))
        for check in checks:
            sev = str(check["severity"]).upper()
            print(f"[{sev}] {check['name']}: {check['message']}")
            remediation = check.get("remediation")
            if remediation:
                print(f"  hint: {remediation}")
            if VERBOSE and check.get("details"):
                print(f"  details: {check['details']}")
        print(
            "Summary: "
            f"ok={summary['ok']} warn={summary['warn']} blocker={summary['blocker']} "
            f"status={overall}"
        )

    if overall == "blocker":
        log_action_end("doctor", "failed")
        sys.exit(1)
    log_action_end("doctor", "warn" if overall == "warn" else "ok")


def run_install_tools(args: argparse.Namespace) -> None:
    log_action_start("install-tools")
    script_candidates: List[Path] = []
    if runtime_share_root is not None:
        # Installed/dist layout should prefer the share-root script path.
        script_candidates.append(runtime_share_root / "scripts" / "install-tools-tui.sh")
    else:
        # Source-tree layout uses scripts/ next to distrodeck.py.
        script_candidates.append(SCRIPT_FILE.parent / "scripts" / "install-tools-tui.sh")
    script_candidates.extend(
        [
            Path("/usr/local/share/distrodeck/scripts/install-tools-tui.sh"),
            Path("/usr/share/distrodeck/scripts/install-tools-tui.sh"),
            Path("/usr/lib/distrodeck/scripts/install-tools-tui.sh"),
        ]
    )
    script = next((path for path in script_candidates if path.exists()), None)
    if script is None:
        locations = ", ".join(str(path) for path in script_candidates)
        fail(f"Installer script not found. Checked: {locations}")
    cmd = [str(script)]
    if args.all:
        cmd.append("--all")
    # Use check=False to allow partial failures (script reports them)
    result = run(cmd, check=False)
    if result.returncode != 0:
        log("Some tools failed to install/uninstall. See warnings above.")
    log_action_end("install-tools")


GIT_STATUS_MARKER_START = "# >>> distrodeck git-status >>>"
GIT_STATUS_MARKER_END = "# <<< distrodeck git-status <<<"


def detect_shell_name() -> str:
    shell = os.environ.get("SHELL", "")
    shell_name = Path(shell).name if shell else ""
    if not shell_name:
        if os.environ.get("ZSH_VERSION"):
            shell_name = "zsh"
        elif os.environ.get("BASH_VERSION"):
            shell_name = "bash"
        elif os.environ.get("FISH_VERSION"):
            shell_name = "fish"
    return shell_name or "bash"


def git_status_script_path(shell_name: str) -> Path:
    config_dir = Path.home() / ".config" / "distrodeck"
    if shell_name == "fish":
        return config_dir / "git-status.fish"
    return config_dir / "git-status.sh"


def git_status_shell_script() -> str:
    return "\n".join(
        [
            "#!/usr/bin/env bash",
            "# Generated by distrodeck git-status. Do not edit by hand.",
            "",
            "distrodeck_git_status() {",
            "  command -v git >/dev/null 2>&1 || return",
            "  # If git is available but the current directory is not a git repository, exit quietly.",
            "  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return",
            "  local branch upstream counts ahead behind status status_text dirty",
            "  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || return",
            "  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)",
            "  ahead=0",
            "  behind=0",
            "  dirty=0",
            "  if [[ -n \"$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null)\" ]]; then",
            "    dirty=1",
            "  fi",
            "  if [[ -n \"$upstream\" ]]; then",
            "    counts=$(git rev-list --left-right --count \"HEAD...$upstream\" 2>/dev/null || true)",
            "    if [[ -n \"$counts\" ]]; then",
            "      local a b",
            "      counts=$(printf '%s' \"$counts\" | tr '[:space:]' ' ')",
            "      read -r a b <<<\"$counts\"",
            "      ahead=${a:-0}",
            "      behind=${b:-0}",
            "    fi",
            "  fi",
            "  status_text=\"\"",
            "  if [[ \"$dirty\" != \"0\" ]]; then",
            "    status_text=\" *\"",
            "  fi",
            "  if [[ -n \"$upstream\" ]]; then",
            "    if [[ \"$ahead\" != \"0\" && \"$behind\" != \"0\" ]]; then",
            "      status_text+=\" ${ahead}↑${behind}↓\"",
            "    elif [[ \"$behind\" != \"0\" ]]; then",
            "      status_text+=\" ${behind}↓\"",
            "    elif [[ \"$ahead\" != \"0\" ]]; then",
            "      status_text+=\" ${ahead}↑\"",
            "    else",
            "      status_text+=\" ≡\"",
            "    fi",
            "  fi",
            "  local branch_color status_color reset_code",
            "  branch_color=\"green\"",
            "  if [[ \"$behind\" != \"0\" ]]; then",
            "    status_color=\"red\"",
            "  elif [[ \"$ahead\" != \"0\" || \"$dirty\" != \"0\" ]]; then",
            "    status_color=\"yellow\"",
            "  else",
            "    status_color=\"green\"",
            "  fi",
            "  if [[ -n \"${ZSH_VERSION:-}\" ]]; then",
            "    if [[ -n \"$status_text\" ]]; then",
            "      printf \"%%F{%s}(%s%%f%%F{%s}%s%%f%%F{%s})%%f\" \"$branch_color\" \"$branch\" \"$status_color\" \"$status_text\" \"$branch_color\"",
            "    else",
            "      printf \"%%F{%s}(%s)%%f\" \"$branch_color\" \"$branch\"",
            "    fi",
            "  else",
            "    reset_code=$(tput sgr0 2>/dev/null || true)",
            "    local branch_code status_code",
            "    branch_code=$(tput setaf 2 2>/dev/null || true)",
            "    case \"$status_color\" in",
            "      red) status_code=$(tput setaf 1 2>/dev/null || true);;",
            "      yellow) status_code=$(tput setaf 3 2>/dev/null || true);;",
            "      green) status_code=$(tput setaf 2 2>/dev/null || true);;",
            "    esac",
            "    if [[ -n \"$status_text\" ]]; then",
            "      printf \"%s(%s%s\" \"$branch_code\" \"$branch\" \"$reset_code\"",
            "      printf \"%s%s\" \"$status_code\" \"$status_text\"",
            "      printf \"%s)%s\" \"$branch_code\" \"$reset_code\"",
            "    else",
            "      printf \"%s(%s)%s\" \"$branch_code\" \"$branch\" \"$reset_code\"",
            "    fi",
            "  fi",
            "}",
            "",
            "distrodeck_git_status_enable() {",
            "  if [[ -n \"${DISTRODECK_GIT_STATUS_ENABLED:-}\" ]]; then",
            "    return",
            "  fi",
            "  DISTRODECK_GIT_STATUS_ENABLED=1",
            "  export DISTRODECK_GIT_STATUS_ENABLED",
            "  if [[ -n \"${ZSH_VERSION:-}\" ]]; then",
            "    setopt PROMPT_SUBST",
            "    if [[ \"$PROMPT\" == *\"distrodeck_git_status\"* ]]; then",
            "      return",
            "    fi",
            "    if [[ \"$PROMPT\" == *\"parse_git_branch\"* ]]; then",
            "      parse_git_branch() { distrodeck_git_status; }",
            "      return",
            "    fi",
            "    if [[ -z \"${DISTRODECK_GIT_STATUS_ORIG_PROMPT:-}\" ]]; then",
            "      DISTRODECK_GIT_STATUS_ORIG_PROMPT=\"$PROMPT\"",
            "    fi",
            "    local status_sub='$(distrodeck_git_status)'",
            "    if [[ \"${DISTRODECK_GIT_STATUS_ORIG_PROMPT}\" == *\"%#\"* ]]; then",
            "      PROMPT=\"${DISTRODECK_GIT_STATUS_ORIG_PROMPT/%#/%#${status_sub}}\"",
            "    else",
            "      PROMPT=\"${DISTRODECK_GIT_STATUS_ORIG_PROMPT}${status_sub}\"",
            "    fi",
            "  else",
            "    if [[ \"$PS1\" == *\"distrodeck_git_status\"* ]]; then",
            "      return",
            "    fi",
            "    if [[ \"$PS1\" == *\"parse_git_branch\"* ]]; then",
            "      parse_git_branch() { distrodeck_git_status; }",
            "      return",
            "    fi",
            "    if [[ -z \"${DISTRODECK_GIT_STATUS_ORIG_PS1:-}\" ]]; then",
            "      DISTRODECK_GIT_STATUS_ORIG_PS1=\"$PS1\"",
            "    fi",
            "    local status_sub='$(distrodeck_git_status)'",
            "    if [[ \"${DISTRODECK_GIT_STATUS_ORIG_PS1}\" == *\"\\\\$ \"* ]]; then",
            "      PS1=\"${DISTRODECK_GIT_STATUS_ORIG_PS1/\\\\$ /${status_sub}\\\\$ }\"",
            "    elif [[ \"${DISTRODECK_GIT_STATUS_ORIG_PS1}\" == *\"\\\\$\"* ]]; then",
            "      PS1=\"${DISTRODECK_GIT_STATUS_ORIG_PS1/\\\\$/${status_sub}\\\\$}\"",
            "    else",
            "      PS1=\"${DISTRODECK_GIT_STATUS_ORIG_PS1}${status_sub}\"",
            "    fi",
            "  fi",
            "}",
            "",
        ]
    )


def git_status_fish_script() -> str:
    return "\n".join(
        [
            "# Generated by distrodeck git-status. Do not edit by hand.",
            "function distrodeck_git_status",
            "  command -v git >/dev/null 2>&1; or return",
            "  git rev-parse --is-inside-work-tree >/dev/null 2>&1; or return",
            "  set branch (git symbolic-ref --quiet --short HEAD ^/dev/null; or git describe --tags --exact-match ^/dev/null; or git rev-parse --short HEAD ^/dev/null)",
            "  if test -z \"$branch\"",
            "    return",
            "  end",
            "  set upstream (git rev-parse --abbrev-ref --symbolic-full-name '@{u}' ^/dev/null)",
            "  set ahead 0",
            "  set behind 0",
            "  set dirty 0",
            "  if test -n (git status --porcelain=v1 --untracked-files=normal ^/dev/null)",
            "    set dirty 1",
            "  end",
            "  if test -n \"$upstream\"",
            "    set counts (git rev-list --left-right --count \"HEAD...$upstream\" ^/dev/null)",
            "    if test -n \"$counts\"",
            "      set counts (string replace -ar '\\\\s+' ' ' $counts)",
            "      set parts (string split --no-empty \" \" $counts)",
            "      set ahead $parts[1]",
            "      set behind $parts[2]",
            "    end",
            "  end",
            "  set status_text \"\"",
            "  if test \"$dirty\" != \"0\"",
            "    set status_text \" *\"",
            "  end",
            "  if test -n \"$upstream\"",
            "    if test \"$ahead\" != \"0\" -a \"$behind\" != \"0\"",
            "      set status_text \"$status_text $ahead↑$behind↓\"",
            "    else if test \"$behind\" != \"0\"",
            "      set status_text \"$status_text $behind↓\"",
            "    else if test \"$ahead\" != \"0\"",
            "      set status_text \"$status_text $ahead↑\"",
            "    else",
            "      set status_text \"$status_text ≡\"",
            "    end",
            "  end",
            "  set branch_color green",
            "  set status_color green",
            "  if test \"$behind\" != \"0\"",
            "    set status_color red",
            "  else if test \"$ahead\" != \"0\" -o \"$dirty\" != \"0\"",
            "    set status_color yellow",
            "  end",
            "  set_color $branch_color",
            "  if test -n \"$status_text\"",
            "    printf \"(%s\" \"$branch\"",
            "    set_color normal",
            "    set_color $status_color",
            "    printf \"%s\" \"$status_text\"",
            "    set_color $branch_color",
            "    printf \")\"",
            "  else",
            "    printf \"(%s)\" \"$branch\"",
            "  end",
            "  set_color normal",
            "end",
            "",
            "function distrodeck_git_status_enable",
            "  if set -q DISTRODECK_GIT_STATUS_ENABLED",
            "    return",
            "  end",
            "  set -gx DISTRODECK_GIT_STATUS_ENABLED 1",
            "  if functions -q distrodeck_fish_prompt_original",
            "    return",
            "  end",
            "  if functions -q fish_prompt",
            "    functions -c fish_prompt distrodeck_fish_prompt_original",
            "  end",
            "  function fish_prompt",
            "    if functions -q distrodeck_fish_prompt_original",
            "      distrodeck_fish_prompt_original",
            "    end",
            "    printf \"%s\" (distrodeck_git_status)",
            "  end",
            "end",
            "",
        ]
    )


def git_status_block(shell_name: str, script_path: Path) -> str:
    if shell_name == "fish":
        return "\n".join(
            [
                GIT_STATUS_MARKER_START,
                f"if test -f \"{script_path}\"",
                f"  source \"{script_path}\"",
                "  distrodeck_git_status_enable",
                "end",
                GIT_STATUS_MARKER_END,
            ]
        )
    return "\n".join(
        [
            GIT_STATUS_MARKER_START,
            f"if [ -f \"{script_path}\" ]; then",
            "  # shellcheck source=/dev/null",
            f"  . \"{script_path}\"",
            "  distrodeck_git_status_enable",
            "fi",
            GIT_STATUS_MARKER_END,
        ]
    )


def remove_git_status_block(content: str) -> str:
    pattern = re.compile(
        rf"{re.escape(GIT_STATUS_MARKER_START)}.*?{re.escape(GIT_STATUS_MARKER_END)}\n?",
        re.DOTALL,
    )
    return re.sub(pattern, "", content)


def write_shell_block(path: Path, block: str) -> None:
    content = ""
    if path.exists():
        try:
            content = path.read_text(encoding="utf-8")
        except OSError:
            content = ""
    content = remove_git_status_block(content)
    if content and not content.endswith("\n"):
        content += "\n"
    if content:
        content += "\n"
    content += block + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def remove_shell_block(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return False
    updated = remove_git_status_block(content)
    if updated == content:
        return False
    path.write_text(updated, encoding="utf-8")
    return True


def run_git_status_set(_: argparse.Namespace) -> None:
    log_action_start("git-status set")
    shell_name = detect_shell_name()
    if shell_name not in {"bash", "zsh", "fish"}:
        warn(f"Shell '{shell_name}' not supported; falling back to bash config.")
        shell_name = "bash"
    script_path = git_status_script_path(shell_name)
    script_path.parent.mkdir(parents=True, exist_ok=True)
    if script_path.exists():
        try:
            script_path.unlink()
        except OSError:
            warn(f"Failed to replace existing {script_path}")
    if shell_name == "fish":
        script_path.write_text(git_status_fish_script(), encoding="utf-8")
    else:
        script_path.write_text(git_status_shell_script(), encoding="utf-8")
    try:
        script_path.chmod(0o755)
    except OSError:
        warn(f"Failed to set executable permissions on {script_path}")
    shell_config = shell_config_path(shell_name)
    block = git_status_block(shell_name, script_path)
    write_shell_block(shell_config, block)
    log(f"git-status enabled for {shell_name} in {shell_config}")
    log(f"Reload your shell config: source {shell_config}")
    log_action_end("git-status set")


def run_git_status_unset(_: argparse.Namespace) -> None:
    log_action_start("git-status unset")
    shell_name = detect_shell_name()
    if shell_name not in {"bash", "zsh", "fish"}:
        warn(f"Shell '{shell_name}' not supported; falling back to bash config.")
        shell_name = "bash"
    shell_config = shell_config_path(shell_name)
    removed = remove_shell_block(shell_config)
    script_path = git_status_script_path(shell_name)
    if script_path.exists():
        try:
            script_path.unlink()
        except OSError:
            warn(f"Failed to remove {script_path}")
    if removed:
        log(f"git-status disabled for {shell_name} in {shell_config}")
    else:
        log(f"git-status block not found in {shell_config}")
    log_action_end("git-status unset")


def git_alias_definitions() -> List[Tuple[str, str, str]]:
    # Tuple format: (alias_name, git_command, human_readable_description)
    # fmt: off
    _do_cmd = (
        "!f() {"
        " if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1;"
        " then echo 'Not a git repository (or any of the parent directories).' >&2; return 1; fi;"
        " url=$(git remote get-url origin 2>/dev/null)"
        " || { echo 'No remote origin found.' >&2; return 1; };"
        " url=${url%.git};"
        " url=$(printf '%s\\n' \"$url\""
        " | sed 's|git@\\([^:]*\\):|https://\\1/|;s|^ssh://git@\\([^/]*\\)/|https://\\1/|');"
        " case \"$url\" in http://*|https://*) ;;"
        " *) echo 'Origin URL is not HTTP(S); not opening.' >&2; echo \"$url\"; return 1;; esac;"
        " safe_url=$(printf '%s\\n' \"$url\""
        " | sed 's#^\\(https\\?://\\)[^/@]*@#\\1#');"
        " if command -v xdg-open >/dev/null 2>&1; then xdg-open \"$safe_url\" 2>/dev/null || { echo \"$safe_url\"; return 1; };"
        " elif command -v open >/dev/null 2>&1; then open \"$safe_url\" 2>/dev/null || { echo \"$safe_url\"; return 1; };"
        " elif command -v python3 >/dev/null 2>&1; then python3 -m webbrowser \"$safe_url\" 2>/dev/null || { echo \"$safe_url\"; return 1; };"
        " elif command -v python >/dev/null 2>&1; then python -m webbrowser \"$safe_url\" 2>/dev/null || { echo \"$safe_url\"; return 1; };"
        " elif command -v cmd.exe >/dev/null 2>&1; then cmd.exe /c start \"\" \"$safe_url\" >/dev/null 2>&1 || { echo \"$safe_url\"; return 1; };"
        " else echo \"$safe_url\"; fi;"
        " }; f"
    )
    # fmt: on
    entries = [
        ("df", "fetch", "fetch"),
        ("dp", "pull", "pull"),
        ("dfp", "!git fetch --all && git pull --all", "fetch --all && pull --all"),
        ("dl", "log --graph --decorate --oneline --all --color=always", "history"),
        ("dpr", "!gh pr create --fill", "create PR (requires gh)"),
        (
            "dis",
            "!gh issue list --state all --limit 1000 --json number,title,state --template '{{tablerow \"NUMBER\" \"TITLE\" \"STATE\"}}{{range .}}{{tablerow (printf \"#%v\" .number) .title .state}}{{end}}{{tablerender}}'",
            "list repository issues (number, title, state; requires gh)",
        ),
        (
            "dprs",
            "!gh pr list --state all --limit 1000 --json number,title,state --template '{{tablerow \"NUMBER\" \"TITLE\" \"STATE\"}}{{range .}}{{tablerow (printf \"#%v\" .number) .title .state}}{{end}}{{tablerender}}'",
            "list repository pull requests (number, title, state; requires gh)",
        ),
        (
            "dup",
            "!branch=$(git symbolic-ref --quiet --short HEAD) && git push -u origin \"$branch\"",
            "push current branch and set upstream to origin/<current-branch>",
        ),
        ("ds", "status -sb", "short status"),
        ("db", "branch -vv", "verbose branches"),
        ("dbr", "branch -a", "all branches"),
        ("dd", "diff", "diff"),
        ("dds", "diff --staged", "diff staged"),
        ("dco", "checkout", "checkout"),
        ("dcb", "checkout -b", "create branch"),
        ("do", _do_cmd, "open remote origin URL in browser"),
    ]
    alias_names = [name for name, _, _ in entries] + ["dhelp"]
    alias_pattern = "|".join(re.escape(name) for name in alias_names)
    entries.append(
        (
            "dhelp",
            f"!git config --get-regexp '^alias\\.({alias_pattern})$' || true",
            "show distrodeck aliases",
        )
    )
    return entries


def apply_git_aliases(entries: List[Tuple[str, str, str]]) -> bool:
    failures: List[Tuple[str, str]] = []
    for name, value, _ in entries:
        current = run(
            ["git", "config", "--global", "--get", f"alias.{name}"],
            check=False,
            capture_output=True,
        )
        if current.returncode == 0:
            existing = (current.stdout or "").strip()
            if existing and existing != value:
                warn(f"Overwriting git alias {name}: {existing} -> {value}")
        result = run(
            ["git", "config", "--global", f"alias.{name}", value],
            check=False,
            capture_output=True,
        )
        if result.returncode != 0:
            details = (result.stderr or result.stdout or "").strip() or "unknown error"
            failures.append((name, details))
    if failures:
        warn("Failed to set one or more git aliases; tracking entries unchanged.")
        for name, details in failures:
            warn(f"Alias {name} failed: {details}")
        return False
    run(
        ["git", "config", "--global", "--unset-all", "distrodeck.alias"],
        check=False,
    )
    for name, value, _ in entries:
        run(
            ["git", "config", "--global", "--add", "distrodeck.alias", f"{name}={value}"],
            check=False,
        )
    return True


def stored_git_alias_entries() -> List[Tuple[str, str]]:
    result = run(
        ["git", "config", "--global", "--get-all", "distrodeck.alias"],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        return []
    entries = []
    for line in (result.stdout or "").splitlines():
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip()
        if name:
            entries.append((name, value))
    return entries


def run_git_aliases_set(args: argparse.Namespace) -> bool:
    """Configure git aliases in the global git config.

    This command sets aliases from ``args.entries`` (if provided) or from
    :func:`git_alias_definitions`. When entries are not explicitly provided,
    the CLI checks for conflicting alias names and asks users to resolve them
    via the TUI.

    Args:
        args: Parsed command-line arguments.

    Returns:
        True when aliases were applied successfully; False otherwise.
    """
    log_action_start("git-aliases set")
    if not cmd_exists("git"):
        warn("git not available; cannot set aliases.")
        log_action_end("git-aliases set", "failed")
        return False
    entries = getattr(args, "entries", None) or git_alias_definitions()
    if getattr(args, "entries", None) is None:
        git_cmds = git_command_names()
        conflicts = [name for name, _, _ in entries if name in git_cmds]
        if conflicts:
            warn(
                "Alias names conflict with existing git commands: "
                + ", ".join(sorted(conflicts))
                + ". Use the TUI to resolve conflicts."
            )
            log_action_end("git-aliases set", "failed")
            return False
    if apply_git_aliases(entries):
        log("Git aliases configured in global git config.")
        log_action_end("git-aliases set")
        return True
    log_action_end("git-aliases set", "failed")
    return False


def run_git_aliases_unset(_: argparse.Namespace) -> None:
    log_action_start("git-aliases unset")
    if not cmd_exists("git"):
        warn("git not available; cannot unset aliases.")
        log_action_end("git-aliases unset", "failed")
        return
    stored = stored_git_alias_entries()
    if stored:
        for name, _ in stored:
            run(
                ["git", "config", "--global", "--unset", f"alias.{name}"],
                check=False,
            )
        run(
            ["git", "config", "--global", "--unset-all", "distrodeck.alias"],
            check=False,
        )
        log("Git aliases removed from global git config (stored entries).")
        log_action_end("git-aliases unset")
        return
    for name, _, _ in git_alias_definitions():
        run(["git", "config", "--global", "--unset", f"alias.{name}"], check=False)
    log("Git aliases removed from global git config.")
    log_action_end("git-aliases unset")


def run_git_aliases_show(_: argparse.Namespace) -> None:
    log_action_start("git-aliases show")
    if not cmd_exists("git"):
        warn("git not available; cannot show aliases.")
        log_action_end("git-aliases show", "failed")
        return
    lines = []
    stored = stored_git_alias_entries()
    if stored:
        for name, value in stored:
            lines.append(f"{name} = {value}  (stored)")
        log("\n".join(lines))
        log_action_end("git-aliases show")
        return
    for name, _, desc in git_alias_definitions():
        current = run(
            ["git", "config", "--global", "--get", f"alias.{name}"],
            check=False,
            capture_output=True,
        )
        value = (current.stdout or "").strip()
        if value:
            lines.append(f"{name} = {value}  ({desc})")
        else:
            lines.append(f"{name} = (not set)  ({desc})")
    log("\n".join(lines))
    log_action_end("git-aliases show")


def resolve_git_alias_conflicts(entries: List[Tuple[str, str, str]]) -> List[Tuple[str, str, str]]:
    git_cmds = git_command_names()
    def find_available_alias_name(seed: str, used: Set[str]) -> str:
        candidate = seed
        suffix = 1
        attempts = 0
        while candidate in git_cmds or candidate in used:
            attempts += 1
            if attempts > MAX_ALIAS_GENERATION_ATTEMPTS:
                raise RuntimeError(
                    f"Unable to generate a safe alias name for seed '{seed}' "
                    f"after {MAX_ALIAS_GENERATION_ATTEMPTS} attempts."
                )
            candidate = f"{seed}{suffix}"
            suffix += 1
        return candidate

    updated: List[Tuple[str, str, str]] = []
    used_names: Set[str] = set()
    for name, value, desc in entries:
        if name in git_cmds:
            dialog_msgbox(
                "Git Aliases",
                f"Alias '{name}' conflicts with an existing git command.",
            )
            seed = f"d{name}"
            try:
                default_name = find_available_alias_name(seed, used_names)
            except RuntimeError as exc:
                fail(str(exc))
            attempts = 0
            while True:
                new_name = dialog_input(
                    "Git Aliases",
                    f"Alias name for '{name}' (required):",
                    default_name,
                )
                if new_name is None:
                    new_name = default_name
                new_name = new_name.strip() or default_name
                if new_name not in git_cmds and new_name not in used_names:
                    break
                attempts += 1
                if attempts >= MAX_ALIAS_NAME_ATTEMPTS:
                    new_name = find_available_alias_name(seed, used_names)
                    break
                dialog_msgbox(
                    "Git Aliases",
                    f"'{new_name}' is a git command or already used. Choose another name.",
                )
            new_value = dialog_input(
                "Git Aliases",
                f"Alias command for '{new_name}':",
                value,
            )
            if new_value is None:
                new_value = value
            new_value = new_value.strip() or value
            used_names.add(new_name)
            updated.append((new_name, new_value, desc))
        else:
            used_names.add(name)
            updated.append((name, value, desc))
    return updated


def run_git_aliases_tui() -> None:
    require_dialog()
    if not cmd_exists("git"):
        dialog_msgbox("Git Aliases", "git not available; cannot manage aliases.")
        return
    choice = dialog_menu(
        "Git Aliases",
        "Configure git aliases:",
        [
            ("set", "Set recommended git aliases"),
            ("unset", "Remove recommended git aliases"),
            ("show", "Show current alias values"),
            ("back", "Back"),
        ],
    )
    if not choice or choice == "back":
        return
    if choice == "set":
        entries = resolve_git_alias_conflicts(git_alias_definitions())
        if run_git_aliases_set(argparse.Namespace(entries=entries)):
            dialog_msgbox("Git Aliases", "Aliases set in global git config.")
        else:
            dialog_msgbox(
                "Git Aliases",
                "Failed to set aliases. See logs for details.",
            )
    elif choice == "unset":
        run_git_aliases_unset(argparse.Namespace())
        dialog_msgbox("Git Aliases", "Aliases removed from global git config.")
    elif choice == "show":
        lines = []
        for name, _, desc in git_alias_definitions():
            current = run(
                ["git", "config", "--global", "--get", f"alias.{name}"],
                check=False,
                capture_output=True,
            )
            value = (current.stdout or "").strip()
            if value:
                lines.append(f"{name} = {value}  ({desc})")
            else:
                lines.append(f"{name} = (not set)  ({desc})")
        dialog_msgbox("Git Aliases", "\n".join(lines) if lines else "No aliases found.")


def shell_config_path(shell_name: str) -> Path:
    home = Path.home()
    if shell_name == "zsh":
        return home / ".zshrc"
    if shell_name == "fish":
        return home / ".config" / "fish" / "config.fish"
    return home / ".bashrc"


def shell_source_command(shell_config: Path) -> str:
    return f"source {shell_config}"


def run_git_status_tui() -> None:
    choice = dialog_menu(
        "Git Status",
        "Enable or disable git branch status in your shell prompt:",
        [
            ("set", "Enable git status prompt"),
            ("unset", "Disable git status prompt"),
            ("back", "Back"),
        ],
    )
    if not choice or choice == "back":
        return
    if choice == "set":
        run_git_status_set(argparse.Namespace())
        shell_name = detect_shell_name()
        if shell_name not in {"bash", "zsh", "fish"}:
            shell_name = "bash"
        shell_config = shell_config_path(shell_name)
        dialog_msgbox(
            "Git Status",
            "Git status prompt enabled.\n"
            f"Reload your shell config:\n{shell_source_command(shell_config)}",
        )
    else:
        run_git_status_unset(argparse.Namespace())
        dialog_msgbox("Git Status", "Git status prompt disabled.")


def ensure_sudo() -> bool:
    if not cmd_exists("sudo"):
        warn("sudo not available; some actions may fail.")
        return True
    if run(["sudo", "-n", "true"], check=False).returncode == 0:
        return True
    password = dialog_password("Authentication", "Enter sudo password:")
    if password is None:
        return False
    result = run(["sudo", "-S", "-v"], check=False, input_text=f"{password}\n")
    if result.returncode != 0:
        dialog_msgbox("Authentication", "Sudo authentication failed.")
        return False
    return True


def build_git_askpass_script() -> Path:
    script = tempfile.NamedTemporaryFile(
        delete=False, prefix="distrodeck-askpass-", mode="w", encoding="utf-8"
    )
    script.write(
        "#!/usr/bin/env bash\n"
        "prompt=\"$1\"\n"
        "case \"$prompt\" in\n"
        "  *Username*|*username*) echo \"${ANSIBLE_GIT_USERNAME:-}\";;\n"
        "  *Password*|*password*|*token*) echo \"${ANSIBLE_GIT_PASSWORD:-}\";;\n"
        "  *) echo \"\";;\n"
        "esac\n"
    )
    script.flush()
    os.fchmod(script.fileno(), 0o700)
    script.close()
    return Path(script.name)


def run_automate_tui() -> None:
    log_action_start("automate")
    if not cmd_exists("ansible-pull"):
        dialog_msgbox(
            "Automate",
            "ansible-pull is not installed.\nRun install-tools and install ansible, then retry.",
        )
        log_action_end("automate", "missing")
        return
    if not cmd_exists("git"):
        dialog_msgbox(
            "Automate",
            "git is required for ansible-pull.\nRun install-tools and install git, then retry.",
        )
        return
    url = dialog_input("Automate", "Ansible pull URL (git repo):", "")
    if not url:
        return
    playbook = dialog_input("Automate", "Playbook path (in repo):", "site.yml")
    if playbook is None:
        return
    if not playbook:
        playbook = "site.yml"
    inventory = dialog_input(
        "Automate", "Inventory path (optional, in repo or local):", ""
    )
    if inventory is None:
        return
    auth_method = dialog_menu(
        "Automate",
        "Select authentication method:",
        [
            ("none", "Public repo / SSH agent"),
            ("ssh", "SSH key"),
            ("userpass", "HTTPS username/password"),
            ("token", "HTTPS token"),
        ],
    )
    if not auth_method:
        return
    env_vars = {}
    askpass_path = None
    if auth_method == "ssh":
        key_path_input = dialog_input(
            "Automate", "SSH key path:", "~/.ssh/id_rsa"
        )
        if not key_path_input:
            return
        key_path = Path(key_path_input).expanduser()
        if not key_path.exists():
            dialog_msgbox("Automate", f"SSH key not found: {key_path}")
            return
        env_vars["GIT_SSH_COMMAND"] = (
            f"ssh -i {key_path} -o IdentitiesOnly=yes"
        )
    elif auth_method in {"userpass", "token"}:
        default_user = "token" if auth_method == "token" else ""
        username = dialog_input("Automate", "Username:", default_user)
        if username is None:
            return
        if not username.strip():
            dialog_msgbox("Automate", "Username is required.")
            return
        password = dialog_password(
            "Automate", "Password:" if auth_method == "userpass" else "Token:"
        )
        if password is None:
            return
        if not password:
            dialog_msgbox("Automate", "Password/token is required.")
            return
        askpass_path = build_git_askpass_script()
        env_vars.update(
            {
                "ANSIBLE_GIT_USERNAME": username,
                "ANSIBLE_GIT_PASSWORD": password,
                "GIT_ASKPASS": str(askpass_path),
                "GIT_TERMINAL_PROMPT": "0",
            }
        )
    use_sudo = dialog_yesno("Automate", "Run ansible-pull with sudo?")
    if use_sudo and not ensure_sudo():
        log_action_end("automate", "cancelled")
        return
    base_cmd = ["ansible-pull", "-U", url]
    if inventory:
        base_cmd.extend(["-i", inventory])
    if playbook:
        base_cmd.append(playbook)
    try:
        if use_sudo:
            cmd = ["sudo"]
            if env_vars:
                cmd.append("env")
                cmd.extend([f"{key}={value}" for key, value in env_vars.items()])
            cmd.extend(base_cmd)
            exit_code = dialog_run_command(
                "Automate",
                "Running ansible-pull...",
                cmd,
            )
        else:
            env = os.environ.copy()
            env.update(env_vars)
            exit_code = dialog_run_command(
                "Automate",
                "Running ansible-pull...",
                base_cmd,
                env=env,
            )
    finally:
        if askpass_path:
            try:
                askpass_path.unlink()
            except OSError:
                pass
    if exit_code != 0:
        dialog_msgbox(
            "Automate",
            f"Automation failed (exit {exit_code}). Check logs for details.",
        )
        log_action_end("automate", "failed")
    else:
        dialog_msgbox("Automate", "Automation completed.")
        log_action_end("automate")


def run_tui() -> None:
    require_dialog()
    os.environ["DISTRODECK_DIALOG"] = "1"
    self_cmd = str(Path(__file__).resolve())
    actions = [
        ("preflight", "Diagnostics: Preflight checks"),
        ("export", "Packages: Export installed packages"),
        ("import", "Packages: Import from export file"),
        ("update", "System: Update packages"),
        ("upgrade", "System: Upgrade distro"),
        ("cleanup-kernels", "System: Cleanup old kernels"),
        ("security", "Security: Apply security updates"),
        ("repo-repair", "Packages: Repo repair (apt issues)"),
        ("install-tools", "Tools: Install optional tools"),
        ("git-status", "Tools: Enable git status in shell prompt"),
        ("git-aliases", "Tools: Configure git aliases"),
        ("automate", "Automation: Run Ansible pull"),
        ("net-tools", "Network: Run installed tools"),
        ("config-edit", "System: Edit config files"),
        ("doctor", "Diagnostics: Check system prerequisites"),
        ("sysinfo", "Diagnostics: Full system info"),
        ("logs", "Diagnostics: View logs"),
        ("clear-logs", "Diagnostics: Clear all logs"),
        ("about", "About"),
        ("quit", "Exit"),
    ]
    while True:
        clear_dialog_before_run = False
        choice = dialog_menu("Distrodeck", "Select an action:", actions)
        if not choice or choice == "quit":
            if cmd_exists("dialog"):
                run(["dialog", "--clear"], check=False)
            break
        if choice == "about":
            show_about_dialog()
            continue
        if choice == "export":
            output = dialog_input(
                "Export", "Output file:", default_export_filename()
            )
            if not output:
                continue
            appimage_dirs = dialog_input(
                "Export", "AppImage dirs (colon-separated, blank for default):", ""
            )
            include_user_tools = dialog_yesno(
                "Export", "Include user-level tools (pipx/npm/composer/nuget/cargo/gem/go)?"
            )
            include_config = dialog_yesno(
                "Export", "Include system config snapshot?"
            )
            include_services = dialog_yesno(
                "Export", "Include enabled/active services?"
            )
            include_config_files = dialog_yesno(
                "Export", "Include key config files (hosts/fstab/ssh config)?"
            )
            config_dirs = []
            config_excludes = []
            if include_config:
                items = [
                    ("/etc", "/etc", "on"),
                    ("/etc/apt", "/etc/apt", "on"),
                    ("/etc/dnf", "/etc/dnf", "on"),
                    ("/etc/pacman.d", "/etc/pacman.d", "on"),
                ]
                config_dirs = dialog_checklist(
                    "Export", "Select config dirs:", items
                )
                if not config_dirs:
                    include_config = False
                if include_config:
                    exclude_input = dialog_input(
                        "Export",
                        "Exclude patterns (comma-separated, blank for none):",
                        "",
                    )
                    if exclude_input:
                        config_excludes = [
                            part.strip()
                            for part in exclude_input.split(",")
                            if part.strip()
                        ]
            cmd = [self_cmd, "export", "--output", output]
            if appimage_dirs:
                cmd.extend(["--appimage-dirs", appimage_dirs])
            if include_user_tools:
                cmd.append("--include-user-tools")
            if include_config:
                if not ensure_sudo():
                    continue
                cmd.append("--include-config")
                if config_dirs:
                    cmd.extend(["--config-dirs", ":".join(config_dirs)])
                for pattern in config_excludes:
                    cmd.extend(["--config-exclude", pattern])
            if include_services:
                cmd.append("--include-services")
            if include_config_files:
                items = [
                    ("/etc/hosts", "/etc/hosts", "on"),
                    ("/etc/fstab", "/etc/fstab", "on"),
                    ("~/.ssh/config", "~/.ssh/config", "on"),
                ]
                selected_files = dialog_checklist(
                    "Export", "Select config files:", items
                )
                extra_input = dialog_input(
                    "Export",
                    "Additional config files (colon-separated, blank for none):",
                    "",
                )
                extra_files = []
                if extra_input:
                    extra_files = [p for p in extra_input.split(":") if p.strip()]
                # Normalize escaped tildes from dialog output.
                # The dialog utility escapes "~" as "\~" in some terminals to prevent
                # shell expansion when output is captured. Other special characters
                # (spaces, quotes) are handled by dialog_checklist which strips quotes
                # from output. We only need tilde handling here because:
                # 1. Our predefined paths use ~ for home directory (e.g., ~/.ssh/config)
                # 2. User-provided paths via extra_input are colon-separated, not quoted
                # 3. Paths with spaces would need quoting which dialog handles differently
                combined = [p.replace("\\~", "~") for p in (selected_files + extra_files)]
                if combined:
                    cmd.append("--include-config-files")
                    cmd.extend(["--config-files", ":".join(combined)])
            clear_dialog_before_run = True
        elif choice == "import":
            default_path = str(get_export_dir() / DEFAULT_EXPORT_FILE)
            input_file = dialog_fselect("Import", "Input file:", default_path)
            if not input_file:
                continue
            try:
                import_data = parse_export_file(Path(input_file))
            except OSError as exc:
                dialog_msgbox("Import", f"Failed to read file: {exc}")
                continue
            apply = dialog_yesno("Import", "Apply installs now?")
            update_sources = dialog_yesno("Import", "Update apt source codenames?")
            items = [
                ("apt_manual", "Apt packages", "on" if import_data["apt_manual"] else "off"),
                ("apt_hold", "Apt holds", "on" if import_data["apt_hold"] else "off"),
                ("ppas", "PPAs", "on" if import_data["ppas"] else "off"),
                ("apt_sources", "Apt sources", "on" if import_data["apt_sources"] else "off"),
                ("snap", "Snap packages", "on" if import_data["snap"] else "off"),
                ("flatpak", "Flatpak apps", "on" if import_data["flatpak"] else "off"),
                ("pacman", "Pacman packages", "on" if import_data["pacman"] else "off"),
                ("dnf", "DNF packages", "on" if import_data["dnf"] else "off"),
                ("zypper", "Zypper packages", "on" if import_data["zypper"] else "off"),
                ("appimage", "AppImages", "on" if import_data["appimage"] else "off"),
                ("config_files", "Config files", "on" if import_data["config_files"] else "off"),
                ("config_snapshot", "Config snapshot", "on" if import_data["config_snapshot"] else "off"),
                ("services_enabled", "Enabled services", "on" if import_data["services_enabled"] else "off"),
            ]
            selected_sections = dialog_checklist(
                "Import", "Select sections to restore:", items
            )
            if not selected_sections:
                continue
            apply_config = False
            apply_services = False
            if "config_snapshot" in selected_sections:
                apply_config = dialog_yesno(
                    "Import", "Restore config snapshot?"
                )
            if "services_enabled" in selected_sections:
                apply_services = dialog_yesno(
                    "Import", "Enable services from export?"
                )
            apply_config_files = False
            if "config_files" in selected_sections:
                apply_config_files = dialog_yesno(
                    "Import", "Restore config files to their paths?"
                )
            cleanup_extras = False
            if "snap" in selected_sections or "flatpak" in selected_sections:
                cleanup_extras = dialog_yesno(
                    "Import", "Remove snap/flatpak extras not in export?"
                )
            appimage_dirs = dialog_input(
                "Import", "AppImage dirs (colon-separated, blank for default):", ""
            )
            cmd = [self_cmd, "import", "--input", input_file]
            if apply:
                cmd.append("--apply")
            if update_sources:
                cmd.append("--update-sources")
            if apply_config:
                if not ensure_sudo():
                    continue
                cmd.append("--apply-config")
            if apply_services:
                if not ensure_sudo():
                    continue
                cmd.append("--apply-services")
            if apply_config_files:
                if not ensure_sudo():
                    continue
                cmd.append("--apply-config-files")
            if cleanup_extras:
                if not ensure_sudo():
                    continue
                cmd.append("--cleanup-extras")
            if selected_sections:
                cmd.extend(["--sections", ",".join(selected_sections)])
            if appimage_dirs:
                cmd.extend(["--appimage-dirs", appimage_dirs])
            clear_dialog_before_run = True
        elif choice == "install-tools":
            if not ensure_sudo():
                continue
            run(["dialog", "--clear"], check=False)
            run([self_cmd, "install-tools"], check=False)
            continue
        elif choice == "automate":
            run_automate_tui()
            continue
        elif choice == "net-tools":
            run_network_tools_tui()
            continue
        elif choice == "config-edit":
            run_config_edit_tui()
            continue
        elif choice == "preflight":
            results = run_preflight()
            dialog_msgbox("Preflight", "\n".join(results))
            continue
        elif choice == "logs":
            latest = get_latest_log_path()
            if not latest:
                dialog_msgbox("Logs", "No logs found.")
                continue
            try:
                content = latest.read_text(encoding="utf-8").strip()
            except OSError as exc:
                dialog_msgbox("Logs", f"Failed to read log: {exc}")
                continue
            if not content:
                content = "Log file is empty."
            dialog_textbox("Distrodeck Logs", content)
            continue
        elif choice == "sysinfo":
            if cmd_exists("dmidecode") and cmd_exists("sudo"):
                if not ensure_sudo():
                    continue
            result = run([self_cmd, "sysinfo"], check=False, capture_output=True)
            output = (result.stdout or result.stderr or "No output").strip()
            height, width = dialog_size(0.85, 0.9)
            temp = Path(tempfile.mkstemp(prefix="distrodeck-sysinfo-")[1])
            temp.write_text(output + "\n", encoding="utf-8")
            dialog_result = run(
                [
                    "dialog",
                    "--title",
                    "Distrodeck System Info",
                    "--extra-button",
                    "--extra-label",
                    "Copy",
                    "--textbox",
                    str(temp),
                    str(height),
                    str(width),
                ],
                check=False,
            )
            if dialog_result.returncode == 3:
                if copy_to_clipboard(output + "\n"):
                    dialog_msgbox("Distrodeck System Info", "Copied to clipboard.")
                else:
                    dialog_msgbox(
                        "Distrodeck System Info",
                        "Clipboard tool not found (wl-copy/xclip/xsel/pbcopy).",
                    )
            try:
                temp.unlink()
            except OSError:
                pass
            continue
        elif choice == "update":
            if not ensure_sudo():
                continue
            cleanup_kernels = dialog_yesno(
                "Update", "Clean up old auto-installed kernels after successful update?"
            )
            if cmd_exists("nala"):
                run(["dialog", "--clear"], check=False)
                log(
                    "Starting system update with Nala (refresh package lists, then upgrade packages)."
                )
                previous_dialog = os.environ.get("DISTRODECK_DIALOG")
                os.environ["DISTRODECK_DIALOG"] = "1"
                if not run_update(cleanup_kernels=cleanup_kernels):
                    if dialog_yesno("Update Issues", "Updates reported errors. Run repo repair?"):
                        run_repo_repair()
                if previous_dialog is None:
                    os.environ.pop("DISTRODECK_DIALOG", None)
                else:
                    os.environ["DISTRODECK_DIALOG"] = previous_dialog
                continue
            run(["dialog", "--clear"], check=False)
            env = os.environ.copy()
            env["DISTRODECK_DIALOG"] = "1"
            env["DISTRODECK_NO_NALA"] = "1"
            log("Starting system update (refresh package lists, then upgrade packages).")
            cmd = [self_cmd, "update"]
            if cleanup_kernels:
                cmd.append("--cleanup-kernels")
            run(cmd, check=False, env=env)
            continue
        elif choice == "upgrade":
            if not ensure_sudo():
                continue
            cleanup_kernels = dialog_yesno(
                "Upgrade", "Clean up old auto-installed kernels after successful distro upgrade?"
            )
            run(["dialog", "--clear"], check=False)
            log("Starting distro upgrade. Follow any prompts in the terminal.")
            run_upgrade(
                argparse.Namespace(
                    target_codename=None,
                    cleanup_kernels=cleanup_kernels,
                    keep_kernels=1,
                )
            )
            continue
        elif choice == "cleanup-kernels":
            dry_run = dialog_yesno("Kernel Cleanup", "Preview old kernel cleanup without removing packages?")
            if not dry_run and not ensure_sudo():
                continue
            run(["dialog", "--clear"], check=False)
            run_cleanup_kernels(argparse.Namespace(dry_run=dry_run, keep=1))
            continue
        elif choice == "security":
            if not ensure_sudo():
                continue
            if cmd_exists("nala") or cmd_exists("unattended-upgrade"):
                run(["dialog", "--clear"], check=False)
                run_security()
                continue
            env = os.environ.copy()
            env["DISTRODECK_DIALOG"] = "1"
            env["DISTRODECK_NO_NALA"] = "1"
            dialog_run_command(
                "Distrodeck Security",
                "Applying security updates...",
                [self_cmd, "security"],
                env=env,
            )
            continue
        elif choice == "repo-repair":
            run_repo_repair()
            continue
        elif choice == "doctor":
            result = run([self_cmd, "--verbose", "doctor"], check=False, capture_output=True)
            output = (result.stdout or result.stderr or "No output").strip()
            height, width = dialog_size(0.85, 0.9)
            temp = Path(tempfile.mkstemp(prefix="distrodeck-doctor-")[1])
            temp.write_text(output + "\n", encoding="utf-8")
            run(
                [
                    "dialog",
                    "--title",
                    "Distrodeck Doctor",
                    "--textbox",
                    str(temp),
                    str(height),
                    str(width),
                ],
                check=False,
            )
            try:
                temp.unlink()
            except OSError:
                pass
            continue
        elif choice == "clear-logs":
            run_clear_logs(argparse.Namespace())
            continue
        else:
            cmd = [self_cmd, choice]
        if choice == "git-status":
            run_git_status_tui()
            continue
        if choice == "git-aliases":
            run_git_aliases_tui()
            continue

        env = None
        if choice == "export":
            env = os.environ.copy()
            env["DISTRODECK_DIALOG"] = "1"
        if clear_dialog_before_run and cmd_exists("dialog"):
            run(["dialog", "--clear"], check=False)
        if choice == "export":
            result = run(cmd, check=False, env=env)
        elif choice == "import":
            result = run(cmd, check=False, env=env)
        else:
            result = run(cmd, check=False, capture_output=True, env=env)
        if result.returncode != 0:
            message = (result.stderr or result.stdout or "Command failed").strip()
            dialog_msgbox("Distrodeck Error", message)
        else:
            dialog_msgbox("Distrodeck", "Done.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="distrodeck",
        description="Export and restore packages before distro upgrades.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable verbose output where applicable",
    )
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command", required=True)

    export_cmd = sub.add_parser("export", help="Export installed packages and sources")
    export_cmd.add_argument("--output", default=DEFAULT_EXPORT_FILE)
    export_cmd.add_argument("--appimage-dirs", default=None)
    export_cmd.add_argument(
        "--include-config",
        action="store_true",
        help="Include system config snapshots (opt-in)",
    )
    export_cmd.add_argument(
        "--config-dirs",
        default=None,
        help="Colon-separated config dirs (default: /etc:/etc/apt:/etc/dnf:/etc/pacman.d)",
    )
    export_cmd.add_argument(
        "--config-exclude",
        action="append",
        default=[],
        help="Exclude patterns for config snapshot (repeatable)",
    )
    export_cmd.add_argument(
        "--config-archive",
        default=None,
        help="Path for config snapshot archive",
    )
    export_cmd.add_argument(
        "--include-config-files",
        action="store_true",
        help="Include key config files as entries",
    )
    export_cmd.add_argument(
        "--config-files",
        default=None,
        help="Colon-separated config files (default: /etc/hosts:/etc/fstab:~/.ssh/config)",
    )
    export_cmd.add_argument(
        "--include-user-tools",
        action="store_true",
        help="Include user-level tools (pipx, npm, composer, nuget, cargo, gem, go)",
    )
    export_cmd.add_argument(
        "--include-services",
        action="store_true",
        help="Include enabled/active systemd services",
    )
    export_cmd.set_defaults(func=export_all)

    import_cmd = sub.add_parser("import", help="Import packages and sources")
    import_cmd.add_argument("--input", required=True)
    import_cmd.add_argument("--apply", action="store_true")
    import_cmd.add_argument("--update-sources", action="store_true")
    import_cmd.add_argument(
        "--apply-config",
        action="store_true",
        help="Restore config snapshot from the export file",
    )
    import_cmd.add_argument(
        "--config-archive",
        default=None,
        help="Override config snapshot archive path",
    )
    import_cmd.add_argument(
        "--apply-services",
        action="store_true",
        help="Enable systemd services captured in the export",
    )
    import_cmd.add_argument(
        "--apply-config-files",
        action="store_true",
        help="Restore exported config files to their paths",
    )
    import_cmd.add_argument(
        "--sections",
        default=None,
        help="Comma-separated sections to restore (e.g., apt_manual,snap,flatpak)",
    )
    import_cmd.add_argument(
        "--cleanup-extras",
        action="store_true",
        help="Remove snap/flatpak extras not present in the export",
    )
    import_cmd.add_argument("--appimage-dirs", default=None)
    import_cmd.set_defaults(func=import_from_file)

    update_cmd = sub.add_parser("update", help="Update system packages")
    update_cmd.add_argument(
        "--cleanup-kernels",
        action="store_true",
        help="Clean up old auto-installed kernels after a successful update",
    )
    update_cmd.add_argument(
        "--keep-kernels",
        type=int,
        default=1,
        help="Previous kernel versions to keep when --cleanup-kernels is used",
    )
    update_cmd.set_defaults(
        func=lambda args: run_update(
            cleanup_kernels=args.cleanup_kernels,
            keep_kernels=args.keep_kernels,
        )
    )

    upgrade_cmd = sub.add_parser("upgrade", help="Run distro upgrade")
    upgrade_cmd.add_argument(
        "--target-codename",
        default=None,
        help="Target codename for Debian upgrades (or set DISTRODECK_TARGET_CODENAME)",
    )
    upgrade_cmd.add_argument(
        "--cleanup-kernels",
        action="store_true",
        help="Clean up old auto-installed kernels after a successful distro upgrade",
    )
    upgrade_cmd.add_argument(
        "--keep-kernels",
        type=int,
        default=1,
        help="Previous kernel versions to keep when --cleanup-kernels is used",
    )
    upgrade_cmd.set_defaults(func=run_upgrade)

    cleanup_cmd = sub.add_parser(
        "cleanup-kernels",
        help="Clean up old auto-installed kernels",
    )
    cleanup_cmd.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview kernel packages that would be removed",
    )
    cleanup_cmd.add_argument(
        "--keep",
        type=int,
        default=1,
        help="Previous kernel versions to keep in addition to the running kernel",
    )
    cleanup_cmd.set_defaults(func=run_cleanup_kernels_cmd)

    security_cmd = sub.add_parser("security", help="Apply security upgrades")
    security_cmd.set_defaults(func=lambda _: run_security())

    repair_cmd = sub.add_parser("repo-repair", help="Repair apt repo issues")
    repair_cmd.set_defaults(func=lambda _: run_repo_repair())

    doctor_cmd = sub.add_parser("doctor", help="Check system prerequisites")
    doctor_cmd.add_argument(
        "--json",
        action="store_true",
        help="Output machine-readable JSON report",
    )
    doctor_cmd.set_defaults(func=run_doctor)

    install_cmd = sub.add_parser(
        "install-tools",
        help="Install optional tools via a TUI checklist",
    )
    install_cmd.add_argument(
        "--all",
        action="store_true",
        help="Install all tools without showing the TUI",
    )
    install_cmd.set_defaults(func=run_install_tools)

    git_cmd = sub.add_parser(
        "git-status",
        help="Enable or disable git status in the shell prompt",
    )
    git_sub = git_cmd.add_subparsers(dest="action", required=True)
    git_set_cmd = git_sub.add_parser("set", help="Enable git status prompt")
    git_set_cmd.set_defaults(func=run_git_status_set)
    git_unset_cmd = git_sub.add_parser("unset", help="Disable git status prompt")
    git_unset_cmd.set_defaults(func=run_git_status_unset)

    alias_cmd = sub.add_parser(
        "git-aliases",
        help="Manage recommended git aliases",
    )
    alias_sub = alias_cmd.add_subparsers(dest="action", required=True)
    alias_set_cmd = alias_sub.add_parser("set", help="Set recommended git aliases")
    alias_set_cmd.set_defaults(func=run_git_aliases_set)
    alias_unset_cmd = alias_sub.add_parser("unset", help="Remove recommended git aliases")
    alias_unset_cmd.set_defaults(func=run_git_aliases_unset)
    alias_show_cmd = alias_sub.add_parser("show", help="Show recommended git aliases")
    alias_show_cmd.set_defaults(func=run_git_aliases_show)

    preflight_cmd = sub.add_parser("preflight", help="Run preflight checks")
    preflight_cmd.set_defaults(func=run_preflight_cmd)

    logs_cmd = sub.add_parser("logs", help="View logs")
    logs_cmd.add_argument("--latest", action="store_true", help="Show latest log")
    logs_cmd.add_argument(
        "--tail",
        type=int,
        default=0,
        help="Show last N lines (implies --latest)",
    )
    logs_cmd.set_defaults(func=run_logs)

    clear_logs_cmd = sub.add_parser("clear-logs", help="Delete all logs")
    clear_logs_cmd.set_defaults(func=run_clear_logs)

    sysinfo_cmd = sub.add_parser("sysinfo", help="Show full system info")
    sysinfo_cmd.set_defaults(func=run_sysinfo)

    config_cmd = sub.add_parser(
        "config-edit",
        help="Edit common system config files (TUI)",
    )
    config_cmd.set_defaults(func=lambda _: run_config_edit_tui())

    net_cmd = sub.add_parser("net-tools", help="Run installed network tools (TUI)")
    net_cmd.set_defaults(func=lambda _: run_network_tools_tui())

    return parser


def main() -> None:
    require_python_version()
    init_logging()
    signal.signal(signal.SIGINT, handle_sigint)
    if len(sys.argv) == 1:
        if not cmd_exists("dialog"):
            print("dialog is required for the TUI.")
            reply = input("Install dialog now? [y/N]: ").strip().lower()
            if reply in {"y", "yes"}:
                if not install_dialog_cli():
                    fail("Failed to install dialog.")
            else:
                parser = build_parser()
                parser.print_help()
                return
        run_tui()
        return
    parser = build_parser()
    args = parser.parse_args()
    global VERBOSE
    VERBOSE = args.verbose
    args.func(args)


if __name__ == "__main__":
    main()
