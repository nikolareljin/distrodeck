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


def _completed(returncode, stdout="", stderr=""):
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


def test_check_ubuntu_release_upgrade_runs_check_only(monkeypatch):
    captured = {}

    def fake_run(cmd, *a, **k):
        captured["cmd"] = cmd
        captured["kwargs"] = k
        return _completed(0)

    monkeypatch.setattr(distrodeck, "run", fake_run)

    result = distrodeck.check_ubuntu_release_upgrade()

    assert result.returncode == distrodeck.RELEASE_UPGRADE_AVAILABLE == 0
    assert captured["cmd"] == ["do-release-upgrade", "-c"]
    # Probe must never raise on a non-zero exit and must capture output.
    assert captured["kwargs"].get("check") is False
    assert captured["kwargs"].get("capture_output") is True


def test_release_upgrade_exit_codes_match_release_upgrader_source():
    # ubuntu-release-upgrader defines RELEASE_AVAILABLE=0, NO_RELEASE_AVAILABLE=1.
    assert distrodeck.RELEASE_UPGRADE_AVAILABLE == 0
    assert distrodeck.RELEASE_UPGRADE_NONE == 1


def test_run_upgrade_exits_cleanly_when_no_release(monkeypatch):
    monkeypatch.setattr(distrodeck, "get_os_id", lambda: "ubuntu")
    monkeypatch.setattr(distrodeck, "get_codename", lambda: "noble")
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    # Exit code 1 == NO_RELEASE_AVAILABLE.
    monkeypatch.setattr(
        distrodeck, "check_ubuntu_release_upgrade", lambda: _completed(1)
    )

    def fail_export(args):  # pragma: no cover - should never be called
        raise AssertionError("export must be skipped when no release is available")

    monkeypatch.setattr(distrodeck, "export_all", fail_export)

    # Must return without raising and without running the upgrade/export.
    distrodeck.run_upgrade(SimpleNamespace())


def test_run_upgrade_proceeds_on_unexpected_check_error(monkeypatch):
    """A non-1 error from the probe must not be reported as 'nothing to upgrade'."""
    monkeypatch.setattr(distrodeck, "get_os_id", lambda: "ubuntu")
    monkeypatch.setattr(distrodeck, "get_codename", lambda: "noble")
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "in_dialog_mode", lambda: True)
    # Exit code 2 == unexpected error (e.g. transient failure), not "no release".
    monkeypatch.setattr(
        distrodeck,
        "check_ubuntu_release_upgrade",
        lambda: _completed(2, stderr="boom"),
    )

    exported = {"called": False}

    def fake_export(args):
        exported["called"] = True

    monkeypatch.setattr(distrodeck, "export_all", fake_export)

    calls = []

    def fake_run(cmd, *a, **k):
        calls.append(cmd)
        return _completed(0)

    monkeypatch.setattr(distrodeck, "run", fake_run)
    monkeypatch.setattr(distrodeck, "update_apt_sources_codename", lambda *a, **k: None)
    monkeypatch.setattr(distrodeck, "import_from_file", lambda args: None)

    distrodeck.run_upgrade(SimpleNamespace(cleanup_kernels=False))

    # Falls through to the real upgrade attempt rather than bailing out as "none".
    assert exported["called"] is True
    assert calls and calls[0][:2] == ["sudo", "do-release-upgrade"]


def test_run_upgrade_does_not_raise_on_nonzero_upgrade(monkeypatch):
    monkeypatch.setattr(distrodeck, "get_os_id", lambda: "ubuntu")
    monkeypatch.setattr(distrodeck, "get_codename", lambda: "noble")
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    # Exit code 0 == RELEASE_AVAILABLE: a release is on offer.
    monkeypatch.setattr(
        distrodeck, "check_ubuntu_release_upgrade", lambda: _completed(0)
    )
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
