import importlib.util
import os
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

BASH = shutil.which("bash")
ZSH = shutil.which("zsh")
UBUNTU_PS1 = r"${debian_chroot:+($debian_chroot)}\u@\h:\w\$ "
UBUNTU_COLOR_PS1 = (
    r"${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ "
)
MACOS_ZSH_PROMPT = "%n@%m %1~ %# "


@pytest.fixture
def script(tmp_path):
    path = tmp_path / "git-status.sh"
    path.write_text(distrodeck.git_status_shell_script(), encoding="utf-8")
    return path


@pytest.fixture
def repo(tmp_path):
    path = tmp_path / "repo"
    path.mkdir()
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.com",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.com",
    }
    subprocess.run(["git", "init", "-q", str(path)], check=True, env=env)
    subprocess.run(["git", "-C", str(path), "checkout", "-q", "-b", "main"], check=True, env=env)
    subprocess.run(["git", "-C", str(path), "commit", "-q", "--allow-empty", "-m", "init"], check=True, env=env)
    return path


def run_shell(shell, script, body, cwd=None, inherited_flag=True):
    env = {k: v for k, v in os.environ.items() if not k.startswith("DISTRODECK_GIT_STATUS")}
    env["TERM"] = "xterm-256color"
    if inherited_flag:
        # Older versions exported this flag; child shells inherit it.
        env["DISTRODECK_GIT_STATUS_ENABLED"] = "1"
    args = [shell, "-f", "-c"] if shell == ZSH else [shell, "--norc", "--noprofile", "-c"]
    result = subprocess.run(
        [*args, f'. "{script}"\n{body}'],
        check=True,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
    )
    return result.stdout


@pytest.mark.skipif(BASH is None, reason="bash not available")
@pytest.mark.parametrize("ps1", [UBUNTU_PS1, UBUNTU_COLOR_PS1, r"\h:\W \u\$ "])
def test_bash_inserts_status_before_prompt_char(script, ps1):
    out = run_shell(
        BASH,
        script,
        f"PS1='{ps1}'; distrodeck_git_status_enable; distrodeck_git_status_enable; printf '%s' \"$PS1\"",
    )
    expected = ps1[: ps1.rindex(r"\$ ")] + "$(distrodeck_git_status)" + r"\$ "
    assert out == expected


@pytest.mark.skipif(BASH is None, reason="bash not available")
def test_bash_keeps_existing_parse_git_branch_prompt(script):
    ps1 = r"\u@\h \w$(parse_git_branch)\$ "
    out = run_shell(
        BASH,
        script,
        f"PS1='{ps1}'; distrodeck_git_status_enable; printf '%s|' \"$PS1\"; type parse_git_branch >/dev/null && echo hooked",
    )
    assert out == ps1 + "|hooked\n"


@pytest.mark.skipif(BASH is None, reason="bash not available")
def test_bash_status_marks_color_codes_as_zero_width(script, repo):
    out = run_shell(BASH, script, "distrodeck_git_status", cwd=repo)
    assert "(main" in out
    if "\x1b" in out:
        # Every escape sequence must sit inside \001...\002 for readline.
        stripped = out
        while "\x01" in stripped:
            start = stripped.index("\x01")
            end = stripped.index("\x02", start)
            stripped = stripped[:start] + stripped[end + 1 :]
        assert "\x1b" not in stripped


@pytest.mark.skipif(BASH is None, reason="bash not available")
def test_status_reports_dirty_tree_and_is_silent_outside_repos(script, repo, tmp_path):
    (repo / "new.txt").write_text("x", encoding="utf-8")
    assert " *" in run_shell(BASH, script, "distrodeck_git_status", cwd=repo)
    outside = tmp_path / "plain"
    outside.mkdir()
    assert run_shell(BASH, script, "distrodeck_git_status", cwd=outside) == ""


@pytest.mark.skipif(ZSH is None, reason="zsh not available")
def test_zsh_inserts_status_before_prompt_char_with_inherited_flag(script):
    out = run_shell(
        ZSH,
        script,
        f"PROMPT='{MACOS_ZSH_PROMPT}'; distrodeck_git_status_enable; distrodeck_git_status_enable; print -rn -- \"$PROMPT\"",
    )
    assert out == "%n@%m %1~ $(distrodeck_git_status)%# "


@pytest.mark.skipif(ZSH is None, reason="zsh not available")
def test_zsh_status_renders_in_repo(script, repo):
    out = run_shell(ZSH, script, "distrodeck_git_status", cwd=repo)
    assert out.startswith("%F{green}(main")


def test_fish_script_uses_supported_redirection_and_no_exported_guard():
    fish = distrodeck.git_status_fish_script()
    assert "^/dev/null" not in fish
    assert "set -gx" not in fish
    assert "set -g __distrodeck_git_status_hooked 1" in fish


def test_shell_script_does_not_export_a_guard_flag():
    script = distrodeck.git_status_shell_script()
    assert "export DISTRODECK_GIT_STATUS_ENABLED" not in script
    assert "local branch upstream counts ahead behind status_text dirty" in script


def test_write_shell_block_is_stable_across_reruns(tmp_path):
    rc = tmp_path / ".zshrc"
    rc.write_text('export PATH="$HOME/.local/bin:$PATH"\n', encoding="utf-8")
    block = distrodeck.git_status_block("zsh", tmp_path / "git-status.sh")

    distrodeck.write_shell_block(rc, block)
    first = rc.read_text(encoding="utf-8")
    distrodeck.write_shell_block(rc, block)

    assert rc.read_text(encoding="utf-8") == first
    assert first.count("\n\n") == 1
