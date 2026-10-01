import importlib.util
import os
import pty
import shutil
import subprocess
from pathlib import Path

import pytest


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
    monkeypatch.setenv("NO_COLOR", "")

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
    assert "--json number,title,state --template" in result.stdout
    assert "{{tablerender}}" in result.stdout
    assert "Requires:" in result.stdout
    assert "Example:" in result.stdout
    assert "git dco <branch-or-pathspec>" in result.stdout
    assert "\x1b" not in result.stdout


def test_git_dhelp_command_detects_terminal_and_no_color():
    command = distrodeck.git_alias_help_command()

    assert "[ -t 1 ]" in command
    assert "${NO_COLOR+x}" in command
    assert "\n" not in command


def test_git_dhelp_show_description_matches_its_detailed_output():
    aliases = {name: description for name, _, description in distrodeck.git_alias_definitions()}

    assert aliases["dhelp"] == "show detailed distrodeck alias reference"


def _dhelp_body() -> str:
    command = distrodeck.git_alias_help_command()
    assert command.startswith("!")
    return command[1:]


# Linux runs git's `!` aliases with /bin/sh (dash on Debian/Ubuntu); macOS
# /bin/sh is bash 3.2 in POSIX mode. zsh in sh emulation covers a user whose
# sh is zsh. Each shell that exists here must render the same plain text.
SHELLS = {
    "dash": ["dash", "-c"],
    "bash-posix": ["bash", "--posix", "-c"],
    "zsh-sh": ["zsh", "--emulate", "sh", "-c"],
}


@pytest.mark.parametrize("shell", sorted(SHELLS))
def test_git_dhelp_renders_plain_under_linux_and_macos_shells(shell):
    argv = SHELLS[shell]
    if shutil.which(argv[0]) is None:
        pytest.skip(f"{argv[0]} not installed")
    env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
    result = subprocess.run(argv + [_dhelp_body()], capture_output=True, text=True, env=env)
    assert result.returncode == 0, result.stderr
    assert "Distrodeck Git Help" in result.stdout
    assert "git dhelp" in result.stdout
    assert "\x1b" not in result.stdout
    # Rendered from the table, never from `git config`.
    assert "alias." not in result.stdout


def _run_on_tty(argv, env):
    output = bytearray()

    def read(fd):
        data = os.read(fd, 1024)
        output.extend(data)
        return data

    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    try:
        while True:
            try:
                if not read(fd):
                    break
            except OSError:
                break
    finally:
        os.waitpid(pid, 0)
    return output.decode(errors="replace")


def test_git_dhelp_colors_a_terminal_and_honours_no_color():
    env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
    colored = _run_on_tty(["sh", "-c", _dhelp_body()], env)
    assert "\x1b[1;36m" in colored
    plain = _run_on_tty(["sh", "-c", _dhelp_body()], {**env, "NO_COLOR": "1"})
    assert "Distrodeck Git Help" in plain
    assert "\x1b" not in plain
