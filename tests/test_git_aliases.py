import importlib.util
import os
import subprocess
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load distrodeck module")
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)


def test_git_alias_help_covers_every_alias_definition():
    aliases = {name for name, _, _ in distrodeck.git_alias_definitions()}
    documented = {row[0] for row in distrodeck.GIT_ALIAS_HELP_ROWS}

    assert documented == aliases
    assert set(distrodeck.GIT_ALIAS_HELP_INVOCATIONS) == documented
    assert "dhelp" in documented


def test_git_dhelp_is_detailed_and_plain_when_no_color(monkeypatch, tmp_path):
    config_path = tmp_path / "gitconfig"
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", str(config_path))
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    monkeypatch.setenv("NO_COLOR", "1")

    assert distrodeck.apply_git_aliases(distrodeck.git_alias_definitions())

    env = os.environ.copy()
    result = subprocess.run(
        ["git", "dhelp"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )

    assert result.returncode == 0
    assert "Distrodeck Git Help" in result.stdout
    assert "What it does:" in result.stdout
    assert "Invokes:" in result.stdout
    assert "git fetch" in result.stdout
    assert "Requires:" in result.stdout
    assert "Example:" in result.stdout
    assert "git dco <branch-or-pathspec>" in result.stdout
    assert "\x1b" not in result.stdout


def test_git_dhelp_command_detects_terminal_and_no_color():
    command = distrodeck.git_alias_help_command()

    assert "[ -t 1 ]" in command
    assert "${NO_COLOR:-}" in command
    assert "\n" not in command


def test_git_dhelp_show_description_matches_its_detailed_output():
    aliases = {name: description for name, _, description in distrodeck.git_alias_definitions()}

    assert aliases["dhelp"] == "show detailed distrodeck alias reference"
