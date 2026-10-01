import importlib.util
import signal
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("distrodeck_module", ROOT / "distrodeck.py")
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)


@pytest.fixture
def captured(monkeypatch):
    calls = []
    result = SimpleNamespace(returncode=0)

    def fake_run(cmd, **_kwargs):
        calls.append(cmd)
        return result

    monkeypatch.setattr(distrodeck, "run", fake_run)
    monkeypatch.setattr(distrodeck, "write_log", lambda *a, **k: None)
    monkeypatch.setattr(distrodeck, "log_action_start", lambda *a: None)
    monkeypatch.setattr(distrodeck, "log_action_end", lambda *a: None)
    return SimpleNamespace(calls=calls, result=result)


def invoke(*argv):
    args = distrodeck.build_parser().parse_args(["install-tools", *argv])
    args.func(args)


def test_list_catalog_forwards_tsv_and_exits_with_the_script(captured):
    with pytest.raises(SystemExit) as exc:
        invoke("--list-catalog", "--java-version", "17")
    assert exc.value.code == 0
    assert captured.calls[0][1:] == ["--list-catalog", "--format", "tsv"]


def test_listing_failure_is_passed_through(captured):
    captured.result.returncode = 2
    with pytest.raises(SystemExit) as exc:
        invoke("--list-catalog")
    assert exc.value.code == 2


def test_a_reader_closing_the_pipe_is_not_a_failure(captured):
    captured.result.returncode = -signal.SIGPIPE
    with pytest.raises(SystemExit) as exc:
        invoke("--list-categories")
    assert exc.value.code == 0


def test_category_is_forwarded(captured):
    invoke("--category", "media,graphics")
    assert captured.calls[0][1:] == ["--category", "media,graphics"]


def test_purge_is_forwarded(captured):
    invoke("--tools", "qdrant", "--purge")
    assert "--purge" in captured.calls[0]


def test_category_with_tools_reaches_the_script_to_be_refused(captured):
    # Dropping --tools here would turn a usage error into an install.
    invoke("--category", "media", "--tools", "vlc")
    assert captured.calls[0][1:] == ["--category", "media", "--tools", "vlc"]


def test_category_with_all_reaches_the_script_to_be_refused(captured):
    invoke("--category", "media", "--all")
    assert captured.calls[0][1:] == ["--category", "media", "--all"]
