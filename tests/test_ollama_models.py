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
    every = [m for g in distrodeck.OLLAMA_MODEL_GROUPS for m in distrodeck.ollama_group_models(g)]
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
    assert "qwen3-vl:4b  3.3 GB  [installed]" in out
    assert "qwen3-vl:8b  6.1 GB  [installed]" not in out


def test_unknown_group_is_rejected():
    with pytest.raises(SystemExit):
        parse("pull", "everything")


def test_every_model_has_a_size_and_groups_total_it():
    for group, models in distrodeck.OLLAMA_MODEL_GROUPS.items():
        for _tag, size in models:
            value, unit = size.split()
            assert float(value) > 0 and unit in {"GB", "MB"}
    assert distrodeck.ollama_group_size("embedding") == "1.3 GB"


def test_main_menu_lists_ollama_and_categories():
    keys = dict(distrodeck.TUI_ACTIONS)
    assert "ollama-models" in keys and "Ollama" in keys["ollama-models"]
    assert "Databases" in keys["install-tools"] and "IDEs" in keys["install-tools"]


class FakeDialog:
    def __init__(self, groups=(), action=None, yes=False):
        self.groups, self.action, self.yes = list(groups), action, yes
        self.messages, self.checklist_items = [], None

    def install(self, monkeypatch):
        monkeypatch.setattr(distrodeck, "dialog_checklist", self.checklist)
        monkeypatch.setattr(distrodeck, "dialog_menu", lambda *a: self.action)
        monkeypatch.setattr(distrodeck, "dialog_yesno", lambda *a: self.yes)
        monkeypatch.setattr(distrodeck, "dialog_msgbox", lambda t, m: self.messages.append(m))
        monkeypatch.setattr(distrodeck, "ensure_sudo", lambda: True)

    def checklist(self, title, prompt, items):
        self.checklist_items = items
        return self.groups


def test_menu_without_ollama_offers_the_opt_in_install(fake, monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)
    dlg = FakeDialog(yes=True)
    dlg.install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    assert ["/x/distrodeck", "install-tools", "--tools", "ollama"] in fake.calls
    assert not any(c[0] == "ollama" for c in fake.calls)


def test_menu_without_ollama_declined_runs_nothing(fake, monkeypatch):
    monkeypatch.setattr(distrodeck, "cmd_exists", lambda name: False)
    FakeDialog(yes=False).install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    assert fake.calls == []


def test_menu_pull_runs_each_model_of_each_picked_group(fake, monkeypatch):
    dlg = FakeDialog(groups=["vision", "embedding"], action="pull")
    dlg.install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    pulls = [c for c in fake.calls if c[:2] == ["ollama", "pull"]]
    assert pulls == [["ollama", "pull", m] for m in
                     ["qwen3-vl:4b", "qwen3-vl:8b", "embeddinggemma:300m", "qwen3-embedding:0.6b"]]
    vision = dict((tag, desc) for tag, desc, _ in dlg.checklist_items)["vision"]
    assert "qwen3-vl:4b [installed]" in vision and "9.4 GB" in vision
    assert "finished" in dlg.messages[-1]


def test_menu_remove_skips_models_that_are_not_installed(fake, monkeypatch):
    FakeDialog(groups=["vision"], action="remove").install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    assert ["ollama", "rm", "qwen3-vl:4b"] in fake.calls
    assert ["ollama", "rm", "qwen3-vl:8b"] not in fake.calls


def test_menu_cancel_changes_nothing(fake, monkeypatch):
    FakeDialog(groups=["vision"], action=None).install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    assert not any(c[:2] in (["ollama", "pull"], ["ollama", "rm"]) for c in fake.calls)


def test_menu_reports_a_failed_pull(fake, monkeypatch):
    fake.fail = {("ollama", "pull", "qwen3-vl:8b")}
    dlg = FakeDialog(groups=["vision"], action="pull")
    dlg.install(monkeypatch)
    distrodeck.run_ollama_models_tui("/x/distrodeck")
    assert "failed for: qwen3-vl:8b" in dlg.messages[-1]
