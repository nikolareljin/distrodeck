"""Reclaiming disk that a build can make again.

A workspace of checkouts is mostly not source. Measured on one machine, 90 GB
across roughly a hundred repositories: 33.4 GB of `build/`, 20.2 GB of Rust
`target/`, 5.2 GB of `.dart_tool/`, 3.2 GB of `node_modules/` -- about three
quarters of the total, none of it authored by anybody.

What is worth testing is not the arithmetic but the refusals. A command that
deletes by directory name is one `build/` away from removing somebody's source,
so most of this file is about what it declines to offer.
"""

import importlib.util
import os
import subprocess
import time
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)

ARTIFACTS = distrodeck.RECLAIM_ARTIFACTS


def git(repo: Path, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True,
                   capture_output=True, text=True)


@pytest.fixture
def repo(tmp_path):
    """A real Git repository, because 'is it ignored' is the whole safety test.

    Faking the answer would test the mock. `git check-ignore` is what decides in
    production, so it is what decides here.
    """
    root = tmp_path / "repo"
    root.mkdir()
    git(root, "init", "-q")
    (root / ".gitignore").write_text("build/\ntarget/\nnode_modules/\n.dart_tool/\nvenv/\n")
    return root


def make_dir(base: Path, relative: str, size: int = 4096, age_days: float = 0):
    path = base / relative
    path.mkdir(parents=True, exist_ok=True)
    (path / "blob").write_bytes(b"x" * size)
    if age_days:
        old = time.time() - age_days * 86400
        for target in (path / "blob", path):
            os.utime(target, (old, old))
    return path


class TestWhatItFinds:
    def test_it_finds_ignored_build_output(self, repo):
        make_dir(repo, "build")
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert [p.name for p, _, _ in found] == ["build"]

    def test_it_leaves_source_alone(self, repo):
        make_dir(repo, "src")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_biggest_first(self, repo):
        make_dir(repo, "a/build", size=1024)
        make_dir(repo, "b/build", size=256 * 1024)
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert len(found) == 2
        assert found[0][1] > found[1][1]


class TestItWillNotDeleteAuthoredCode:
    """The failure this command must never have.

    `build/` and `target/` are ordinary names for authored code -- a `build/`
    holding release scripts, a `target/` that means something else in the
    project's own vocabulary. A basename match cannot tell those from output.
    Git already knows, because somebody wrote it in `.gitignore`.
    """

    def test_a_tracked_build_directory_is_not_offered(self, repo):
        # The exact disaster: somebody's hand-written build/ is not ignored.
        (repo / ".gitignore").write_text("target/\n")
        make_dir(repo, "build")
        git(repo, "add", "-A")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_an_untracked_but_unignored_build_is_not_offered(self, repo):
        # Not yet committed is not the same as disposable.
        (repo / ".gitignore").write_text("target/\n")
        make_dir(repo, "build")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_a_directory_outside_any_repository_is_not_offered(self, tmp_path):
        # Nothing to ask, so nothing is assumed.
        make_dir(tmp_path, "loose/build")
        assert distrodeck.find_reclaimable(tmp_path, ARTIFACTS) == []

    def test_the_requirement_can_be_waived_explicitly(self, tmp_path):
        # --any-directory exists for trees Git knows nothing about, and says so.
        make_dir(tmp_path, "loose/build")
        found = distrodeck.find_reclaimable(tmp_path, ARTIFACTS, require_git_ignored=False)
        assert [p.name for p, _, _ in found] == ["build"]


class TestWhatItRefusesToTouch:
    def test_it_never_enters_a_git_directory(self, repo):
        # A repository's history is not build output however large it grows.
        make_dir(repo, ".git/build")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_it_does_not_count_nested_artifacts_twice(self, repo):
        make_dir(repo, "build/node_modules")
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert [p.name for p, _, _ in found] == ["build"]

    def test_virtualenvs_are_not_included_by_default(self, repo):
        make_dir(repo, "venv")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_but_they_can_be_asked_for(self, repo):
        make_dir(repo, "venv")
        names = {**ARTIFACTS, **distrodeck.RECLAIM_ENVIRONMENTS}
        assert [p.name for p, _, _ in distrodeck.find_reclaimable(repo.parent, names)] == ["venv"]


class TestAgeIsTakenFromTheNewestThingInside:
    """A directory's own mtime is not its age.

    It changes only when its immediate entries are added or removed, so editing
    a file three levels down does not touch it. An actively compiling `target/`
    whose root entry was created weeks ago looks weeks old -- and would have
    been offered for deletion mid-build.
    """

    def test_recent_output_is_left_alone(self, repo):
        make_dir(repo, "build", age_days=0)
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7) == []

    def test_old_output_is_offered(self, repo):
        make_dir(repo, "build", age_days=30)
        assert len(distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7)) == 1

    def test_a_fresh_file_under_an_old_directory_protects_it(self, repo):
        # The bug this exists for. The root is stale; something inside is not.
        target = make_dir(repo, "build", age_days=60)
        nested = target / "deep" / "fresh"
        nested.mkdir(parents=True)
        (nested / "just-compiled.o").write_bytes(b"y" * 128)
        old = time.time() - 60 * 86400
        os.utime(target, (old, old))
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7) == []

    def test_zero_days_means_everything(self, repo):
        make_dir(repo, "build", age_days=0)
        assert len(distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=0)) == 1

    def test_a_negative_cutoff_is_refused(self, repo):
        # A negative cutoff is in the future, marking every directory old and
        # silently disabling the protection it appears to be using.
        with pytest.raises(ValueError):
            distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=-1)

    def test_argparse_refuses_it_too(self):
        import argparse

        with pytest.raises(argparse.ArgumentTypeError):
            distrodeck._nonnegative_days("-1")
        assert distrodeck._nonnegative_days("30") == 30


class TestSizeIsWhatDeletionWouldFree:
    def test_hard_links_are_counted_once(self, repo):
        # A build tree that links rather than copies would otherwise bill the
        # same inode to every path naming it, inflating the promise.
        first = make_dir(repo, "build", size=64 * 1024)
        linked = first / "linked.o"
        try:
            os.link(first / "blob", linked)
        except OSError:
            pytest.skip("filesystem does not support hard links")
        seen: set = set()
        size, _ = distrodeck._measure(first, seen)
        standalone = make_dir(repo, "target", size=64 * 1024)
        alone, _ = distrodeck._measure(standalone, set())
        # Two names, one inode: no more than a single copy is counted.
        assert size < alone * 2

    def test_it_reports_something_for_a_real_directory(self, repo):
        make_dir(repo, "build", size=16 * 1024)
        (_, size, _), = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert size > 0


class TestItDoesNotDeleteUnlessAskedTwice:
    def _args(self, workspace, **overrides):
        import argparse

        defaults = dict(
            workspace=str(workspace), apply=False, include_environments=False,
            older_than=0, list=0, any_directory=False,
        )
        defaults.update(overrides)
        return argparse.Namespace(**defaults)

    def test_a_report_deletes_nothing(self, repo, capsys):
        target = make_dir(repo, "build")
        distrodeck.run_reclaim(self._args(repo.parent))
        assert target.exists()
        assert "Nothing was deleted" in capsys.readouterr().out

    def test_apply_deletes(self, repo, capsys):
        target = make_dir(repo, "build")
        distrodeck.run_reclaim(self._args(repo.parent, apply=True))
        assert not target.exists()
        assert "freed" in capsys.readouterr().out

    def test_apply_leaves_the_repository_behind(self, repo):
        make_dir(repo, "build")
        make_dir(repo, "src", size=16)
        distrodeck.run_reclaim(self._args(repo.parent, apply=True))
        assert (repo / "src").exists()
        assert (repo / ".git").exists()

    def test_an_empty_workspace_says_so_rather_than_failing(self, tmp_path, capsys):
        distrodeck.run_reclaim(self._args(tmp_path))
        assert "Nothing reclaimable" in capsys.readouterr().out
