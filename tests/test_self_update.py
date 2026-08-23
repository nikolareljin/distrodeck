import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load distrodeck module")
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)


def test_self_update_commands_are_native_to_each_manager():
    assert distrodeck.self_update_command("brew") == ["brew", "upgrade", "distrodeck"]
    assert distrodeck.self_update_command("nala") == ["sudo", "nala", "upgrade", "-y", "distrodeck"]
    assert distrodeck.self_update_command("apt-get") == ["sudo", "apt-get", "install", "--only-upgrade", "-y", "distrodeck"]
    assert distrodeck.self_update_command("dnf") == ["sudo", "dnf", "upgrade", "-y", "distrodeck"]
    assert distrodeck.self_update_command("zypper") == ["sudo", "zypper", "update", "-y", "distrodeck"]
    assert distrodeck.self_update_command("pacman") == ["sudo", "pacman", "-Syu", "--noconfirm", "distrodeck"]
