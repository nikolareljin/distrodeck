import importlib.util
from types import SimpleNamespace
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load distrodeck module")
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)


def test_self_update_commands_are_native_to_each_manager():
    assert distrodeck.self_update_command("brew") == ["brew", "upgrade", "distrodeck"]
    assert distrodeck.self_update_command("nala") == ["sudo", "nala", "install", "-y", "distrodeck"]
    assert distrodeck.self_update_command("apt-get") == ["sudo", "apt-get", "install", "--only-upgrade", "-y", "distrodeck"]
    assert distrodeck.self_update_command("dnf") == ["sudo", "dnf", "upgrade", "-y", "distrodeck"]
    assert distrodeck.self_update_command("zypper") == ["sudo", "zypper", "update", "-y", "distrodeck"]
    assert distrodeck.self_update_command("pacman") == ["sudo", "pacman", "-Syu", "--noconfirm", "distrodeck"]


def test_source_self_update_commands_preserve_prefix():
    root = Path("/tmp/distrodeck-source")
    prefix = Path("/opt/distrodeck")

    assert distrodeck.source_self_update_commands(root, prefix) == [
        ["git", "-C", str(root), "pull", "--ff-only"],
        ["git", "-C", str(root), "submodule", "update", "--init", "--recursive"],
        [str(root / "build")],
        ["sudo", "env", "PREFIX=/opt/distrodeck", str(root / "install")],
    ]


def test_self_update_refuses_dirty_source_checkout(monkeypatch, tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    (root / ".git").mkdir()
    monkeypatch.setattr(distrodeck, "SCRIPT_FILE", root / "distrodeck.py")
    monkeypatch.setattr(distrodeck, "self_update_method", lambda: "source")
    calls = []

    def fake_run(command, **_kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0, stdout="dirty\n")

    monkeypatch.setattr(distrodeck, "run", fake_run)
    distrodeck.run_self_update(SimpleNamespace())

    assert calls == [["git", "-C", str(root), "status", "--porcelain"]]


def test_self_update_refuses_non_fast_forward_source_checkout(monkeypatch, tmp_path):
    root = tmp_path / "source"
    root.mkdir()
    (root / ".git").mkdir()
    monkeypatch.setattr(distrodeck, "SCRIPT_FILE", root / "distrodeck.py")
    monkeypatch.setattr(distrodeck, "self_update_method", lambda: "source")
    calls = []

    def fake_run(command, **_kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=0 if command[-1] == "--porcelain" else 1, stdout="")

    monkeypatch.setattr(distrodeck, "run", fake_run)
    assert distrodeck.run_self_update(SimpleNamespace()) is False
    assert calls == [
        ["git", "-C", str(root), "status", "--porcelain"],
        ["git", "-C", str(root), "merge-base", "--is-ancestor", "HEAD", "@{u}"],
    ]
