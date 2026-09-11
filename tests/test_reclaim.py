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
        assert [p.name for p, _, _, _ in found] == ["build"]

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
        assert [p.name for p, _, _, _ in found] == ["build"]


class TestWhatItRefusesToTouch:
    def test_it_never_enters_a_git_directory(self, repo):
        # A repository's history is not build output however large it grows.
        make_dir(repo, ".git/build")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_it_does_not_count_nested_artifacts_twice(self, repo):
        make_dir(repo, "build/node_modules")
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert [p.name for p, _, _, _ in found] == ["build"]

    def test_virtualenvs_are_not_included_by_default(self, repo):
        make_dir(repo, "venv")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_but_they_can_be_asked_for(self, repo):
        make_dir(repo, "venv")
        names = {**ARTIFACTS, **distrodeck.RECLAIM_ENVIRONMENTS}
        assert [p.name for p, _, _, _ in distrodeck.find_reclaimable(repo.parent, names)] == ["venv"]


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
            distrodeck._nonnegative_int("-1")
        assert distrodeck._nonnegative_int("30") == 30


class TestSizeIsWhatDeletionWouldFree:
    def test_hard_linked_content_is_excluded_not_merely_deduplicated(self, repo):
        """Counting the first occurrence still overstates the total.

        Removing one of two names for an inode frees nothing while the other
        survives, and proving every name is inside the deletion set would mean
        indexing the filesystem. So such content is left out and reported
        separately, making the figure an underestimate -- the safe direction for
        a promise about space.
        """
        target = make_dir(repo, "build", size=64 * 1024)
        try:
            os.link(target / "blob", target / "second-name.o")
        except OSError:
            pytest.skip("filesystem does not support hard links")
        size, _, linked = distrodeck._measure(target)
        assert linked > 0, "the linked inode should be reported separately"
        assert size == 0, "and excluded from the total that deletion would free"

    def test_ordinary_files_are_counted(self, repo):
        target = make_dir(repo, "build", size=64 * 1024)
        size, _, linked = distrodeck._measure(target)
        assert size > 0 and linked == 0

    def test_it_reports_something_for_a_real_directory(self, repo):
        make_dir(repo, "build", size=16 * 1024)
        (_, size, _, _), = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
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


class TestContainmentRunsBothWays:
    """`.git` filtered from the walk does not protect a repository *inside* a match.

    An outer repository can ignore `build/`, and `build/vendor` can itself be a
    clone. The candidate passes `check-ignore`, and `rmtree` would then take that
    repository's history with it. The inverse test -- a `.git/build` -- does not
    cover this at all.
    """

    def test_a_candidate_containing_a_repository_is_not_offered(self, repo):
        nested = make_dir(repo, "build/vendor")
        git(nested, "init", "-q")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_a_submodule_or_worktree_marker_file_also_protects_it(self, repo):
        # A submodule and a linked worktree have `.git` as a *file*, not a directory.
        nested = make_dir(repo, "build/vendor")
        (nested / ".git").write_text("gitdir: ../../.git/modules/vendor\n")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_an_ordinary_candidate_is_still_offered(self, repo):
        make_dir(repo, "build/ordinary")
        assert [p.name for p, _, _, _ in distrodeck.find_reclaimable(repo.parent, ARTIFACTS)] == ["build"]


class TestIgnoredIsNotEnoughOnItsOwn:
    def test_a_directory_holding_a_force_added_file_is_not_offered(self, repo):
        """Authored content inside a build directory must survive.

        Which guard stops it is deliberately not asserted. Measured against
        git 2.x, `check-ignore` stops reporting `build/` as ignored as soon as
        anything under it is tracked, so the ignore test refuses it before the
        index is consulted at all -- the `ls-files` check in `_worktree_facts`
        is a second line that no constructible case reaches. Asserting the
        mechanism would be asserting a git implementation detail; the outcome is
        what matters and is what this checks.
        """
        target = make_dir(repo, "build")
        kept = target / "hand-written.sh"
        kept.write_text("#!/bin/sh\necho authored\n")
        git(repo, "add", "-f", str(kept))
        git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "force-add")
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_without_the_forced_file_it_is_offered(self, repo):
        make_dir(repo, "build")
        assert len(distrodeck.find_reclaimable(repo.parent, ARTIFACTS)) == 1


class TestPruningDoesNotHideNestedArtifacts:
    def test_an_ignored_artifact_inside_an_authored_match_is_still_found(self, repo):
        """Pruning at the match, before eligibility is known, loses work.

        An unignored authored `scripts/build/` can contain an ignored `target/`.
        Rejecting the outer candidate is right; never having visited the inner
        one is a miss.
        """
        (repo / ".gitignore").write_text("target/\nnode_modules/\n")
        make_dir(repo, "scripts/build")          # authored, not ignored
        make_dir(repo, "scripts/build/target")   # ignored output inside it
        found = [p for p, _, _, _ in distrodeck.find_reclaimable(repo.parent, ARTIFACTS)]
        assert [p.name for p in found] == ["target"]

    def test_a_descendant_of_an_accepted_candidate_is_counted_once(self, repo):
        make_dir(repo, "build/node_modules")
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        assert [p.name for p, _, _, _ in found] == ["build"]


class TestListCountIsValidated:
    def test_a_negative_list_count_is_refused(self):
        import argparse

        # Quieter than the --older-than case: -1 is truthy, so found[:-1] prints
        # every candidate except the smallest rather than failing.
        with pytest.raises(argparse.ArgumentTypeError):
            distrodeck._nonnegative_int("-1")

    def test_zero_and_positive_are_accepted(self):
        assert distrodeck._nonnegative_int("0") == 0
        assert distrodeck._nonnegative_int("10") == 10
