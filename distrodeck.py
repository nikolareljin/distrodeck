#!/usr/bin/env python3
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
import signal
import base64
import socket
import shutil
from shutil import get_terminal_size
from datetime import datetime, timezone
from pathlib import Path
from typing import List, Optional, Tuple
from glob import glob

VERSION = "0.3.0"
VERSION_FILE = Path(__file__).resolve().with_name("VERSION")
SHARE_VERSION_FILE = Path("/usr/share/distrodeck/VERSION")
for path in (VERSION_FILE, SHARE_VERSION_FILE):
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


def run(
    cmd, check=True, capture_output=False, text=True, input_text=None, env=None
):
    return subprocess.run(
        cmd,
        check=check,
        capture_output=capture_output,
        text=text,
        input=input_text,
        env=env,
    )


def run_warn(cmd, title: str) -> subprocess.CompletedProcess:
    result = run(cmd, check=False, capture_output=True)
    if result.returncode != 0:
        details = (result.stderr or result.stdout or "").strip()
        if details:
            warn(f"{title} failed:\n{details}")
        else:
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


def cmd_exists(name: str) -> bool:
    return subprocess.call(
        ["bash", "-lc", f"command -v {name} >/dev/null 2>&1"]
    ) == 0


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


def edit_config_file(path: Path) -> None:
    if not path.exists() or not path.is_file():
        dialog_msgbox("Config Editor", f"File not found: {path}")
        return
    editor = os.getenv("EDITOR") or ""
    if not editor:
        for candidate in ("nano", "vim", "vi"):
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


def run_config_edit_tui() -> None:
    require_dialog()
    while True:
        items = [("custom", "Custom path...", "off")]
        for label, path in config_edit_targets():
            items.append((path, label, "off"))
        items.append(("back", "Back", "off"))
        choices = dialog_checklist("Config Editor", "Select a file to edit:", items)
        if not choices or "back" in choices:
            break
        for choice in choices:
            if choice == "custom":
                custom = dialog_fselect("Config Editor", "Pick a file:", "/etc/")
                if custom:
                    edit_config_file(Path(custom))
            else:
                edit_config_file(Path(choice))

def dialog_gauge(title: str, message: str) -> Optional[subprocess.Popen]:
    if not cmd_exists("dialog"):
        return None
    height, width = dialog_size(0.5, 0.8)
    return subprocess.Popen(
        [
            "dialog",
            "--title",
            title,
            "--gauge",
            message,
            str(height),
            str(width),
            "0",
        ],
        stdin=subprocess.PIPE,
        text=True,
    )


def dialog_gauge_update(proc: subprocess.Popen, percent: int, message: str) -> None:
    if not proc or not proc.stdin:
        return
    proc.stdin.write(f"XXX\n{percent}\n{message}\nXXX\n")
    proc.stdin.flush()


def dialog_gauge_close(proc: subprocess.Popen) -> None:
    if not proc or not proc.stdin:
        return
    proc.stdin.write("100\n")
    proc.stdin.close()
    proc.wait()


def handle_sigint(signum, frame) -> None:
    if cmd_exists("dialog"):
        run(["dialog", "--clear"], check=False)
    sys.exit(130)


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
                proc.stdin.write(text + "\n")
                proc.stdin.flush()
            time.sleep(0.1)
    else:
        proc.wait()

    if proc.stdin:
        proc.stdin.close()
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
    return f"distrodeck-export-{hostname}-{stamp}.txt"


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
    log_dir = get_log_dir()
    logs = sorted(log_dir.glob("distrodeck-*.log"))
    if not logs:
        log("No logs found.")
        return
    if args.tail and not args.latest:
        args.latest = True
    if args.latest:
        target = logs[-1]
        if args.tail and args.tail > 0:
            lines = target.read_text(encoding="utf-8").splitlines()
            log("\n".join(lines[-args.tail :]))
        else:
            log(target.read_text(encoding="utf-8"))
        return
    for path in logs:
        log(str(path))


def run_preflight_cmd(_: argparse.Namespace) -> None:
    results = run_preflight()
    for line in results:
        log(line)


def get_latest_log_path() -> Optional[Path]:
    log_dir = get_log_dir()
    logs = sorted(log_dir.glob("distrodeck-*.log"))
    return logs[-1] if logs else None


def run_sysinfo(_: argparse.Namespace) -> None:
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
            break
        if choice == "nmap":
            if not cmd_exists("nmap"):
                dialog_msgbox("Network Tools", "nmap not installed.")
                continue
            targets = cidrs if cidrs else []
            custom = dialog_input("nmap", "Targets (space-separated, blank = auto):", " ".join(targets))
            if custom:
                targets = custom.split()
            if not targets:
                dialog_msgbox("nmap", "No targets available.")
                continue
            run(["dialog", "--clear"], check=False)
            run(["nmap", "-sV", *targets], check=False)
            continue
        if choice == "mtr":
            if not cmd_exists("mtr"):
                dialog_msgbox("Network Tools", "mtr not installed.")
                continue
            host = dialog_input("mtr", "Host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["mtr", host], check=False)
            continue
        if choice == "iperf3":
            if not cmd_exists("iperf3"):
                dialog_msgbox("Network Tools", "iperf3 not installed.")
                continue
            host = dialog_input("iperf3", "Server host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["iperf3", "-c", host], check=False)
            continue
        if choice == "traceroute":
            if not cmd_exists("traceroute"):
                dialog_msgbox("Network Tools", "traceroute not installed.")
                continue
            host = dialog_input("traceroute", "Host/IP:", "")
            if not host:
                continue
            run(["dialog", "--clear"], check=False)
            run(["traceroute", host], check=False)
            continue
        if choice == "tcpdump":
            if not cmd_exists("tcpdump"):
                dialog_msgbox("Network Tools", "tcpdump not installed.")
                continue
            iface = dialog_input("tcpdump", "Interface (blank = default):", "")
            cmd = ["tcpdump"]
            if iface:
                cmd.extend(["-i", iface])
            run(["dialog", "--clear"], check=False)
            run(cmd, check=False)
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


def export_apt_sources() -> List[str]:
    sources = set()
    path = Path("/etc/apt/sources.list.d")
    if not path.exists():
        return []
    for item in path.glob("*.list"):
        for line in item.read_text(encoding="utf-8").splitlines():
            if line.startswith("deb ") and "ppa.launchpad.net" not in line:
                sources.add(line.strip())
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
    valid_dirs = [d for d in dirs if Path(d).exists()]
    missing = [d for d in dirs if not Path(d).exists()]
    for path in missing:
        warn(f"Config dir not found, skipping: {path}")
    if not valid_dirs:
        return None
    cmd = ["sudo", "tar", "-czf", str(archive_path)]
    for pattern in excludes:
        cmd.extend(["--exclude", pattern])
    cmd.extend(valid_dirs)
    run(cmd)
    return str(archive_path)


def export_all(args: argparse.Namespace) -> None:
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
    gauge = None
    if in_dialog_mode() and cmd_exists("dialog"):
        gauge = dialog_gauge("Distrodeck Export", "Starting export...")
    total = len(sections)
    for idx, (name, func, message) in enumerate(sections, start=1):
        if gauge:
            percent = min(99, int(idx * 100 / total))
            dialog_gauge_update(gauge, percent, message)
        section_results.append((name, func()))
    if gauge:
        dialog_gauge_update(gauge, 100, "Finalizing export...")
        dialog_gauge_close(gauge)
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


def ensure_nala() -> bool:
    if cmd_exists("nala"):
        return True
    if not cmd_exists("apt-get"):
        warn("apt-get not available; cannot install Nala")
        return False
    log("Installing Nala...")
    update_result = run_warn(["sudo", "apt-get", "update"], "apt-get update")
    if update_result.returncode != 0:
        warn("Skipping Nala install due to apt-get update failure.")
        return False
    run_warn(["sudo", "apt-get", "install", "-y", "nala"], "apt-get install nala")
    return True


def run_update() -> None:
    if allow_nala() and ensure_nala():
        update_cmd = ["sudo", "nala", "update"]
        upgrade_cmd = ["sudo", "nala", "upgrade", "-y"]
        if in_dialog_mode():
            update_cmd.extend(["-v"])
            upgrade_cmd.extend(["-v", "--raw-dpkg"])
        run_warn(update_cmd, "nala update")
        run_warn(upgrade_cmd, "nala upgrade")
    elif cmd_exists("apt-get"):
        run_warn(["sudo", "apt-get", "update"], "apt-get update")
        run_warn(["sudo", "apt-get", "upgrade", "-y"], "apt-get upgrade")
    elif cmd_exists("apt"):
        run_warn(["sudo", "apt", "update"], "apt update")
        run_warn(["sudo", "apt", "upgrade", "-y"], "apt upgrade")
    elif cmd_exists("dnf"):
        run(["sudo", "dnf", "upgrade", "-y"])
    elif cmd_exists("zypper"):
        run(["sudo", "zypper", "refresh"])
        run(["sudo", "zypper", "update", "-y"])
    elif cmd_exists("pacman"):
        run(["sudo", "pacman", "-Syu", "--noconfirm"])
    else:
        warn("No supported package manager for update.")
    if cmd_exists("snap"):
        run(["sudo", "snap", "refresh"])
    if cmd_exists("flatpak"):
        run(["flatpak", "update", "-y"])


def run_security() -> None:
    if cmd_exists("unattended-upgrade"):
        result = run(["sudo", "unattended-upgrade", "--verbose"], check=False)
        if result.returncode != 0:
            warn("unattended-upgrade failed; trying package-manager security updates.")
        else:
            return
    if allow_nala() and cmd_exists("nala"):
        cmd = ["sudo", "nala", "upgrade", "-y", "--security"]
        if in_dialog_mode():
            cmd.extend(["-v", "--raw-dpkg"])
        result = run(cmd, check=False)
        if result.returncode == 0:
            return
        warn("nala does not support --security; falling back to a full upgrade.")
        cmd = ["sudo", "nala", "upgrade", "-y"]
        if in_dialog_mode():
            cmd.extend(["-v", "--raw-dpkg"])
        run(cmd)
        return
    if cmd_exists("apt-get"):
        run(["sudo", "apt-get", "update"])
        run(["sudo", "apt-get", "upgrade", "-y", "--with-new-pkgs"])
        return
    if cmd_exists("dnf"):
        run(["sudo", "dnf", "upgrade", "-y", "--security"])
        return
    if cmd_exists("zypper"):
        run(["sudo", "zypper", "patch", "--category", "security", "-y"])
        return
    if cmd_exists("pacman"):
        warn("Pacman has no separate security-only mode; run update instead.")
        return
    warn("No supported package manager for security updates.")


def run_upgrade() -> None:
    os_id = get_os_id()
    if os_id == "ubuntu":
        if not cmd_exists("do-release-upgrade"):
            fail("do-release-upgrade not available")
        cmd = ["sudo", "do-release-upgrade"]
        if in_dialog_mode():
            cmd.extend(["-f", "DistUpgradeViewText"])
        run(cmd)
        return
    warn(f"Distro upgrade not implemented for {os_id}")


def rewrite_codename(line: str, old_codename: str, new_codename: str) -> str:
    if not old_codename or not new_codename:
        return line
    return line.replace(old_codename, new_codename)


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


def import_from_file(args: argparse.Namespace) -> None:
    path = Path(args.input)
    if not path.exists():
        fail(f"Input file not found: {args.input}")
    data = parse_export_file(path)
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
            log_diff("apt_manual", *diff_items(data["apt_manual"], current["apt_manual"]))
        if wants("apt_hold"):
            log_diff("apt_hold", *diff_items(data["apt_hold"], current["apt_hold"]))
        if wants("ppas"):
            log_diff("ppas", *diff_items(data["ppas"], current["ppas"]))
        if wants("apt_sources"):
            log_diff("apt_sources", *diff_items(data["apt_sources"], current["apt_sources"]))
        if wants("snap"):
            desired = [normalize_snap_entry(item) for item in data["snap"]]
            log_diff("snap", *diff_items(desired, current["snap"]))
        if wants("flatpak"):
            desired = [normalize_flatpak_entry(item) for item in data["flatpak"]]
            log_diff("flatpak", *diff_items(desired, current["flatpak"]))
        if wants("appimage"):
            log_diff("appimage", *diff_items(data["appimage"], current["appimage"]))
            missing = [item for item in data["appimage"] if not Path(item).exists()]
            if missing:
                log("appimage missing on disk: " + ", ".join(missing))
        if wants("config_files"):
            log(f"config_files: {len(data['config_files'])} entries in export.")
        if not args.apply_config and not args.apply_services and not args.cleanup_extras and not args.apply_config_files:
            log("Dry-run only. Re-run with --apply to install.")
            return

    if args.apply:
        if wants("ppas") and data["ppas"] and cmd_exists("add-apt-repository"):
            run(["sudo", "apt-get", "update"])
            for ppa in data["ppas"]:
                run(["sudo", "add-apt-repository", "-y", ppa])

        if wants("apt_sources") and data["apt_sources"] and cmd_exists("apt-get"):
            new_codename = get_codename()
            sources_lines = []
            for src in data["apt_sources"]:
                if args.update_sources:
                    src = rewrite_codename(src, data["codename"], new_codename)
                sources_lines.append(src)
            content = "\n".join(sources_lines) + "\n"
            run(
                ["sudo", "tee", "/etc/apt/sources.list.d/distrodeck-import.list"],
                input_text=content,
            )

        if wants("apt_manual") and data["apt_manual"] and cmd_exists("apt-get"):
            run(["sudo", "apt-get", "update"])
            run(["sudo", "apt-get", "install", "-y", *data["apt_manual"]])
        elif wants("apt_manual") and data["apt_manual"]:
            warn("apt-get not available; skipping apt package install")

        if wants("apt_hold") and data["apt_hold"] and cmd_exists("apt-mark"):
            for pkg in data["apt_hold"]:
                run(["sudo", "apt-mark", "hold", pkg])

        if wants("snap") and data["snap"] and cmd_exists("snap"):
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
                run(cmd)

        if wants("flatpak") and data["flatpak"] and cmd_exists("flatpak"):
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
                    run(["flatpak", "install", "-y", remote, app])
                else:
                    run(["flatpak", "install", "-y", app])

        if wants("appimage") and data["appimage"]:
            for path_str in data["appimage"]:
                path = Path(path_str)
                if path.exists():
                    path.chmod(path.stat().st_mode | 0o111)
                else:
                    warn(f"AppImage not found: {path_str}")

        if wants("pacman") and data["pacman"] and cmd_exists("pacman"):
            run(["sudo", "pacman", "-S", "--needed", "--noconfirm", *data["pacman"]])
        elif wants("pacman") and data["pacman"]:
            warn("pacman not available; skipping pacman package install")

        if wants("dnf") and data["dnf"] and cmd_exists("dnf"):
            run(["sudo", "dnf", "install", "-y", *data["dnf"]])
        elif wants("dnf") and data["dnf"]:
            warn("dnf not available; skipping dnf package install")

        if wants("zypper") and data["zypper"] and cmd_exists("zypper"):
            run(["sudo", "zypper", "install", "-y", *data["zypper"]])
        elif wants("zypper") and data["zypper"]:
            warn("zypper not available; skipping zypper package install")

    if args.apply_config and wants("config_snapshot"):
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
                run(["sudo", "tar", "-xzf", archive, "-C", "/"])

    if args.apply_services and wants("services_enabled"):
        if not cmd_exists("systemctl"):
            warn("systemctl not available; skipping service enablement.")
        else:
            for service in data["services_enabled"]:
                run(["sudo", "systemctl", "enable", service], check=False)

    if args.cleanup_extras:
        if wants("snap") and cmd_exists("snap"):
            desired = [normalize_snap_entry(item) for item in data["snap"]]
            _, extra = diff_items(desired, [normalize_snap_entry(item) for item in export_snaps()])
            for name in extra:
                run(["sudo", "snap", "remove", name], check=False)
        if wants("flatpak") and cmd_exists("flatpak"):
            desired = [normalize_flatpak_entry(item) for item in data["flatpak"]]
            _, extra = diff_items(desired, [normalize_flatpak_entry(item) for item in export_flatpaks()])
            for app in extra:
                if app:
                    run(["flatpak", "uninstall", "-y", app], check=False)

    if args.apply_config_files and wants("config_files"):
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
            except (ValueError, OSError):
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
                run(["sudo", "mkdir", "-p", str(parent)], check=False)
                with tempfile.NamedTemporaryFile(delete=False) as tmp:
                    tmp.write(content)
                    tmp_path = tmp.name
                run(["sudo", "install", "-m", "0644", tmp_path, str(target)], check=False)
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)


def run_doctor() -> None:
    os_id = get_os_id()
    codename = get_codename()
    log(f"os_id={os_id}")
    if codename:
        log(f"codename={codename}")
    checks = [
        ("apt-get", "Debian/Ubuntu package manager (base system updates)"),
        ("nala", "Apt UI/formatter (faster output)"),
        ("snap", "Snap package manager"),
        ("flatpak", "Flatpak package manager"),
        ("add-apt-repository", "Manage PPAs and apt repositories"),
        ("do-release-upgrade", "Ubuntu distro upgrade tool"),
        ("dnf", "Fedora/RHEL package manager"),
        ("zypper", "openSUSE package manager"),
        ("pacman", "Arch package manager"),
    ]

    def command_path(name: str) -> str:
        path = shutil.which(name)
        return path or ""

    def command_version(name: str) -> str:
        for flag in ("--version", "-V", "-v"):
            result = run([name, flag], check=False, capture_output=True)
            output = (result.stdout or result.stderr or "").strip()
            if result.returncode == 0 and output:
                return output.splitlines()[0]
        return ""

    for name, desc in checks:
        status = "ok" if cmd_exists(name) else "missing"
        if VERBOSE:
            path = command_path(name)
            version = command_version(name) if status == "ok" else ""
            details = []
            if path:
                details.append(f"path={path}")
            if version:
                details.append(f"version={version}")
            detail_str = f" ({', '.join(details)})" if details else ""
            log(f"{name}: {status} - {desc}{detail_str}")
        else:
            log(f"{name}: {status}")


def run_install_tools(args: argparse.Namespace) -> None:
    script = Path(__file__).resolve().parent / "scripts" / "install-tools-tui.sh"
    if not script.exists():
        fail(f"Installer script not found: {script}")
    cmd = [str(script)]
    if args.all:
        cmd.append("--all")
    run(cmd)


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


def run_tui() -> None:
    require_dialog()
    self_cmd = str(Path(__file__).resolve())
    actions = [
        ("export", "Packages: Export installed packages"),
        ("import", "Packages: Import from export file"),
        ("update", "System: Update packages"),
        ("upgrade", "System: Upgrade distro"),
        ("security", "Security: Apply security updates"),
        ("install-tools", "Tools: Install optional tools"),
        ("net-tools", "Network: Run installed tools"),
        ("config-edit", "System: Edit config files"),
        ("preflight", "Diagnostics: Preflight checks"),
        ("doctor", "Diagnostics: Check system prerequisites"),
        ("sysinfo", "Diagnostics: Full system info"),
        ("logs", "Diagnostics: View logs"),
        ("quit", "Exit"),
    ]
    while True:
        choice = dialog_menu("Distrodeck", "Select an action:", actions)
        if not choice or choice == "quit":
            if cmd_exists("dialog"):
                run(["dialog", "--clear"], check=False)
            break
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
                combined = selected_files + extra_files
                if combined:
                    cmd.append("--include-config-files")
                    cmd.extend(["--config-files", ":".join(combined)])
        elif choice == "import":
            default_path = str(Path.cwd() / DEFAULT_EXPORT_FILE)
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
        elif choice == "install-tools":
            if not ensure_sudo():
                continue
            run(["dialog", "--clear"], check=False)
            run([self_cmd, "install-tools"], check=False)
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
            height, width = dialog_size(0.8, 0.9)
            run(
                [
                    "dialog",
                    "--title",
                    "Distrodeck Logs",
                    "--textbox",
                    str(latest),
                    str(height),
                    str(width),
                ],
                check=False,
            )
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
            if cmd_exists("nala"):
                run(["dialog", "--clear"], check=False)
                run_update()
                continue
            run(["dialog", "--clear"], check=False)
            env = os.environ.copy()
            env["DISTRODECK_NO_NALA"] = "1"
            run([self_cmd, "update"], check=False, env=env)
            continue
        elif choice == "upgrade":
            if not ensure_sudo():
                continue
            run(["dialog", "--clear"], check=False)
            run_upgrade()
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
        else:
            cmd = [self_cmd, choice]

        env = None
        if choice == "export":
            env = os.environ.copy()
            env["DISTRODECK_DIALOG"] = "1"
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
    update_cmd.set_defaults(func=lambda _: run_update())

    upgrade_cmd = sub.add_parser("upgrade", help="Run distro upgrade")
    upgrade_cmd.set_defaults(func=lambda _: run_upgrade())

    security_cmd = sub.add_parser("security", help="Apply security upgrades")
    security_cmd.set_defaults(func=lambda _: run_security())

    doctor_cmd = sub.add_parser("doctor", help="Check system prerequisites")
    doctor_cmd.set_defaults(func=lambda _: run_doctor())

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
