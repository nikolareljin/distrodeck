import importlib.util
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("distrodeck_module", ROOT / "distrodeck.py")
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)


@pytest.fixture
def env(monkeypatch, tmp_path):
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path))
    monkeypatch.setattr(distrodeck, "write_log", lambda *a, **k: None)
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)
    calls = []
    failing = set()

    def fake_run(command, **_kwargs):
        calls.append(command)
        return SimpleNamespace(returncode=1 if tuple(command) in failing else 0, stdout="")

    monkeypatch.setattr(distrodeck, "run", fake_run)
    return SimpleNamespace(calls=calls, failing=failing, state=tmp_path / "distrodeck" / "tools")


def test_updater_keys_are_catalog_tools():
    script = ROOT / "scripts" / "install-tools-tui.sh"
    if not (ROOT / "scripts" / "script-helpers" / "helpers.sh").exists():
        pytest.skip("script-helpers submodule not checked out")
    catalog = subprocess.run([str(script), "--list-tools"], capture_output=True, text=True, check=True).stdout.split()
    assert set(distrodeck.TOOL_UPDATERS) <= set(catalog)
    assert {"git-lantern", "ai-runner"} <= set(catalog)


def test_no_installed_tools_runs_nothing_and_succeeds(env, capsys):
    assert distrodeck.refresh_catalog_tools() is True
    assert env.calls == []
    assert "No installed catalog tools" in capsys.readouterr().out


def test_checkouts_are_refreshed_without_a_state_file_entry(env):
    (env.state / "git-lantern" / ".git").mkdir(parents=True)
    assert distrodeck.refresh_catalog_tools() is True
    assert env.calls == [["git", "-C", str(env.state / "git-lantern"), "pull", "--ff-only"]]


def test_a_failure_does_not_stop_later_updaters(env, monkeypatch, capsys):
    (env.state / "git-lantern" / ".git").mkdir(parents=True)
    (env.state / "ai-runner" / ".git").mkdir(parents=True)
    env.failing.add(("git", "-C", str(env.state / "git-lantern"), "pull", "--ff-only"))
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: name == "claude")
    assert distrodeck.refresh_catalog_tools() is False
    assert ["git", "-C", str(env.state / "ai-runner"), "pull", "--ff-only"] in env.calls
    assert ["claude", "update"] in env.calls
    err = capsys.readouterr().err
    assert "Tool refresh failed: git-lantern" in err


def test_npm_tools_are_detected_by_npm_and_reinstalled_at_latest(env, monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: name == "npm")
    distrodeck.refresh_catalog_tools()
    assert ["npm", "ls", "-g", "--depth=0", "@openai/codex"] in env.calls
    assert ["sudo", "npm", "install", "-g", "@openai/codex@latest"] in env.calls


def test_update_dispatches_tool_refresh_and_reports_its_failure(env, monkeypatch):
    refreshed = []
    monkeypatch.setattr(distrodeck, "refresh_catalog_tools", lambda: refreshed.append(1) or False)
    monkeypatch.setattr(distrodeck, "allow_nala", lambda: False)
    monkeypatch.setattr(distrodeck, "log_action_start", lambda *a: None)
    monkeypatch.setattr(distrodeck, "log_action_end", lambda *a: None)
    monkeypatch.setattr(distrodeck, "warn", lambda *a: None)
    assert distrodeck.run_update() is False
    assert refreshed == [1]
