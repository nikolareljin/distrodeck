"""The pre-commit hook compares VERSION with the newest CHANGELOG section."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

HOOK = Path(__file__).resolve().parent.parent / ".githooks" / "pre-commit"


def run_hook(root: Path, version: str, changelog: str) -> subprocess.CompletedProcess:
    if shutil.which("git") is None:
        pytest.skip("git not installed")
    root.mkdir(parents=True, exist_ok=True)
    env = {"PATH": os.environ["PATH"], "HOME": str(root)}
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=env)
    (root / "VERSION").write_text(version + "\n")
    (root / "CHANGELOG.md").write_text(changelog)
    (root / "docs" / "man").mkdir(parents=True, exist_ok=True)
    (root / "docs" / "man" / "distrodeck.1").write_text(
        f'.TH DISTRODECK 1 "2026-11-12" "distrodeck {version}" "User Commands"\n'
    )
    (root / "distrodeck.py").write_text(f"VERSION = '{version}'\n")
    return subprocess.run(["bash", str(HOOK)], cwd=root, env=env, capture_output=True, text=True)


DATED = (
    "# Changelog\n\n## [Unreleased]\n\n"
    "## 2026-11-12 — 1.2.0\n\n### Added\n- x\n\n"
    "## 2026-10-01 — 1.1.0\n"
)


def test_dated_section_matches(tmp_path):
    r = run_hook(tmp_path, "1.2.0", DATED)
    assert r.returncode == 0, r.stderr


def test_dated_section_mismatch_fails(tmp_path):
    r = run_hook(tmp_path, "1.3.0", DATED)
    assert r.returncode == 1
    assert "does not match CHANGELOG.md (1.2.0)" in r.stderr


def test_unreleased_only_is_not_a_version(tmp_path):
    r = run_hook(tmp_path, "1.2.0", "# Changelog\n\n## [Unreleased]\n\n### Added\n- x\n")
    assert r.returncode == 0, r.stderr


def test_bracket_section(tmp_path):
    log = "# Changelog\n\n## [Unreleased]\n\n## [1.2.0] - 2026-11-12\n"
    assert run_hook(tmp_path / "a", "1.2.0", log).returncode == 0
    assert run_hook(tmp_path / "b", "1.1.0", log).returncode == 1


def test_plain_hyphen_heading(tmp_path):
    r = run_hook(tmp_path, "1.2.0", "# Changelog\n\n## 2026-11-12 - 1.2.0\n")
    assert r.returncode == 0, r.stderr
