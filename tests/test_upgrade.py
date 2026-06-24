import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
if SPEC is None:
    raise RuntimeError(f"Could not load module spec from {MODULE_PATH}")
distrodeck = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise RuntimeError(f"Could not load module loader from {MODULE_PATH}")
SPEC.loader.exec_module(distrodeck)


def _completed(returncode):
    return SimpleNamespace(returncode=returncode)


def test_ubuntu_release_available_true_on_zero_exit(monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "run", lambda *a, **k: _completed(0))

    assert distrodeck.ubuntu_release_available() is True


def test_ubuntu_release_available_false_on_nonzero_exit(monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "run", lambda *a, **k: _completed(1))

    assert distrodeck.ubuntu_release_available() is False


def test_ubuntu_release_available_false_without_tool(monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)

    def fail_run(*a, **k):  # pragma: no cover - should never be called
        raise AssertionError("run should not be invoked when tool is missing")

    monkeypatch.setattr(distrodeck, "run", fail_run)

    assert distrodeck.ubuntu_release_available() is False


def test_run_upgrade_exits_cleanly_when_no_release(monkeypatch):
    monkeypatch.setattr(distrodeck, "get_os_id", lambda: "ubuntu")
    monkeypatch.setattr(distrodeck, "get_codename", lambda: "noble")
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "ubuntu_release_available", lambda: False)

    def fail_export(args):  # pragma: no cover - should never be called
        raise AssertionError("export must be skipped when no release is available")

    monkeypatch.setattr(distrodeck, "export_all", fail_export)
    monkeypatch.setattr(
        distrodeck, "run", lambda *a, **k: pytest.fail("run should not be called")
    )

    # Must return without raising (no traceback) and without running anything.
    distrodeck.run_upgrade(SimpleNamespace())


def test_run_upgrade_does_not_raise_on_nonzero_upgrade(monkeypatch):
    monkeypatch.setattr(distrodeck, "get_os_id", lambda: "ubuntu")
    monkeypatch.setattr(distrodeck, "get_codename", lambda: "noble")
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "ubuntu_release_available", lambda: True)
    monkeypatch.setattr(distrodeck, "export_all", lambda args: None)
    monkeypatch.setattr(distrodeck, "in_dialog_mode", lambda: True)

    calls = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)
        # do-release-upgrade exits non-zero (e.g. nothing to do / failure).
        assert k.get("check") is False
        return _completed(1)

    monkeypatch.setattr(distrodeck, "run", fake_run)

    def fail_import(args):  # pragma: no cover - should never be called
        raise AssertionError("import must not run after a failed upgrade")

    monkeypatch.setattr(distrodeck, "import_from_file", fail_import)

    # Must return gracefully instead of raising CalledProcessError.
    distrodeck.run_upgrade(SimpleNamespace())

    assert calls and calls[0][:2] == ["sudo", "do-release-upgrade"]
