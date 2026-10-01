import argparse
import importlib.util
import subprocess
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)

LIST_OUTPUT = (
    "NAME                ID              SIZE      MODIFIED\n"
    "qwen3-vl:4b         abc123          3.3 GB    2 days ago\n"
)


class FakeRun:
    def __init__(self, fail=()):
        self.calls = []
        self.fail = set(fail)

    def __call__(self, cmd, check=True, capture_output=False, **_):
        self.calls.append(cmd)
        rc = 1 if tuple(cmd) in self.fail else 0
        out = LIST_OUTPUT if cmd[:2] == ["ollama", "list"] else ""
        return subprocess.CompletedProcess(cmd, rc, stdout=out, stderr="")


@pytest.fixture
def fake(monkeypatch):
    fake_run = FakeRun()
    monkeypatch.setattr(distrodeck, "run", fake_run)
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: True)
    monkeypatch.setattr(distrodeck, "write_log", lambda *a, **k: None)
    return fake_run


def parse(*argv):
    return distrodeck.build_parser().parse_args(["ollama", "models", *argv])


def test_groups_are_the_documented_set_and_tags_are_explicit():
    assert list(distrodeck.OLLAMA_MODEL_GROUPS) == [
        "default", "reasoning", "coding", "text", "vision", "embedding"
    ]
    every = [m for models in distrodeck.OLLAMA_MODEL_GROUPS.values() for m in models]
    assert all(":" in m and not m.endswith(":latest") for m in every)
    # Removing one group must never remove a model another group owns.
    assert len(every) == len(set(every))


def test_pull_runs_ollama_pull_for_each_model(fake):
    args = parse("pull", "vision")
    args.func(args)
    assert fake.calls == [["ollama", "pull", "qwen3-vl:4b"], ["ollama", "pull", "qwen3-vl:8b"]]


def test_pull_continues_after_a_failure_and_exits_nonzero(fake):
    fake.fail = {("ollama", "pull", "qwen3-vl:4b")}
    args = parse("pull", "vision")
    with pytest.raises(SystemExit):
        args.func(args)
    assert ["ollama", "pull", "qwen3-vl:8b"] in fake.calls


def test_remove_only_touches_installed_models(fake):
    args = parse("remove", "vision")
    args.func(args)
    assert ["ollama", "rm", "qwen3-vl:4b"] in fake.calls
    assert ["ollama", "rm", "qwen3-vl:8b"] not in fake.calls


def test_pull_without_ollama_fails_without_running_anything(fake, monkeypatch, capsys):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)
    args = parse("pull", "default")
    with pytest.raises(SystemExit) as exc:
        args.func(args)
    assert exc.value.code == 1
    assert fake.calls == []
    assert "ollama is not installed" in capsys.readouterr().err


def test_list_without_ollama_still_prints_groups(fake, monkeypatch, capsys):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)
    args = parse("list")
    args.func(args)
    out = capsys.readouterr().out
    assert "embedding:" in out and "embeddinggemma:300m" in out
    assert fake.calls == []


def test_list_marks_installed_models(fake, capsys):
    args = parse("list")
    args.func(args)
    out = capsys.readouterr().out
    assert "qwen3-vl:4b  [installed]" in out
    assert "qwen3-vl:8b  [installed]" not in out


def test_unknown_group_is_rejected():
    with pytest.raises(SystemExit):
        parse("pull", "everything")
