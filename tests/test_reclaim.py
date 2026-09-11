"""Reclaiming disk that a build can make again.

A workspace of checkouts is mostly not source. Measured on one machine, 90 GB
across roughly a hundred repositories: 33.8 GB of `build/`, 15.5 GB of Rust
`target/`, 5.2 GB of `.dart_tool/`, 3.1 GB of `node_modules/` -- 59.5 GB in
total, plus a further 3.3 GB of hard-linked content deliberately excluded from
that figure. About two thirds of the workspace, none of it authored by anybody.

What is worth testing is not the arithmetic but the refusals. A command that
deletes by directory name is one `build/` away from removing somebody's source,
so most of this file is about what it declines to offer.
"""

import argparse
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
        m = distrodeck._measure(target)
        size, linked = m.total, m.linked
        assert linked > 0, "the linked inode should be reported separately"
        assert size == 0, "and excluded from the total that deletion would free"

    def test_ordinary_files_are_counted(self, repo):
        target = make_dir(repo, "build", size=64 * 1024)
        m = distrodeck._measure(target)
        assert m.total > 0 and m.linked == 0

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


class TestItFailsClosedWhenGitCannotBeAsked:
    """An unanswered question must not be read as a yes.

    `git ls-files` timing out on a huge repository is exactly when the "holds no
    tracked file" half of the promise is most likely to be skipped and least
    likely to be noticed -- and the candidate would still be deleted on the
    strength of the ignore check alone.
    """

    def test_nothing_is_offered_when_only_ls_files_fails(self, repo, monkeypatch):
        """Isolated to `ls-files`, so the ignore guard cannot pass this for it.

        A first version of this test broke every git call, which meant
        `check-ignore` refused the candidate and the test passed while the
        `ls-files` guard was removed. Breaking one call at a time is the only
        way the assertion means what it says.
        """
        make_dir(repo, "build")
        assert len(distrodeck.find_reclaimable(repo.parent, ARTIFACTS)) == 1

        real = distrodeck._git

        def break_only_ls_files(worktree, *args, **kwargs):
            if args[0] == "ls-files":
                return None
            return real(worktree, *args, **kwargs)

        monkeypatch.setattr(distrodeck, "_git", break_only_ls_files)
        # check-ignore still answers, and still says the directory is ignored --
        # so only the completeness flag stands between it and deletion.
        ignored, _, complete = distrodeck._worktree_facts(repo, [repo / "build"])
        assert (repo / "build") in ignored and complete is False
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_nothing_is_offered_when_check_ignore_fails(self, repo, monkeypatch):
        make_dir(repo, "build")
        real = distrodeck._git

        def break_check_ignore(worktree, *args, **kwargs):
            if args[0] == "check-ignore":
                return None
            return real(worktree, *args, **kwargs)

        monkeypatch.setattr(distrodeck, "_git", break_check_ignore)
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_worktree_facts_reports_incompleteness(self, repo, monkeypatch):
        make_dir(repo, "build")
        ignored, tracked, complete = distrodeck._worktree_facts(repo, [repo / "build"])
        assert complete is True
        monkeypatch.setattr(distrodeck, "_git", lambda *a, **k: None)
        _, _, complete = distrodeck._worktree_facts(repo, [repo / "build"])
        assert complete is False


class TestSparseFilesAreNotCountedAsSpace:
    def test_a_fully_sparse_file_reports_its_allocation_not_its_length(self, repo):
        """`st_blocks == 0` with a huge `st_size` is a hole, not reclaimable space.

        Falling back to apparent size whenever `st_blocks` is zero -- rather than
        only when the field is absent -- would report gigabytes of nothing.
        """
        target = repo / "build"
        target.mkdir()
        sparse = target / "sparse.img"
        with open(sparse, "wb") as handle:
            handle.truncate(512 * 1024 * 1024)  # half a gigabyte of hole
        import os as _os

        info = _os.lstat(sparse)
        if getattr(info, "st_blocks", None) is None:
            pytest.skip("platform does not report st_blocks")
        if info.st_blocks * 512 >= info.st_size:
            pytest.skip("filesystem does not support sparse files")
        size = distrodeck._measure(target).total
        assert size < info.st_size, "apparent size must not be reported as reclaimable"


class TestBareRepositoriesAreProtectedToo:
    """`git clone --bare` has no `.git` entry at all.

    `HEAD`, `objects` and `refs` sit at the root. Looking only for `.git` missed
    exactly the kind of repository somebody vendors into a build directory --
    ignored, and irreplaceable.
    """

    def test_a_bare_clone_inside_a_candidate_protects_it(self, repo):
        vendor = repo / "build" / "vendor.git"
        vendor.mkdir(parents=True)
        subprocess.run(["git", "init", "--bare", "-q", str(vendor)],
                       check=True, capture_output=True)
        assert not (vendor / ".git").exists(), "a bare repo has no .git to find"
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_the_three_markers_together_are_what_counts(self, repo):
        # A directory that merely contains a file called HEAD is not a repository.
        target = make_dir(repo, "build")
        (target / "HEAD").write_text("not a repo\n")
        assert len(distrodeck.find_reclaimable(repo.parent, ARTIFACTS)) == 1


class TestEligibilityIsRecheckedBeforeDeleting:
    """Everything known about a candidate was learned minutes earlier.

    A scan across a large workspace takes time. A build started in that window
    creates fresh files; somebody can force-add into the directory; a clone can
    appear inside it. `--older-than` exists to protect work in progress and was
    evaluated before that work resumed.
    """

    def test_a_candidate_that_gained_a_repository_is_skipped(self, repo, capsys):
        import argparse

        target = make_dir(repo, "build", age_days=30)
        args = argparse.Namespace(workspace=str(repo.parent), apply=True,
                                  include_environments=False, older_than=7,
                                  list=0, any_directory=False)
        # Simulate the race: eligible at scan time, a clone appears before the
        # deletion loop reaches it.
        real_measure = distrodeck._measure
        state = {"scanned": False}

        def measure_then_plant(path):
            result = real_measure(path)
            if not state["scanned"]:
                state["scanned"] = True
                nested = path / "vendor"
                nested.mkdir(exist_ok=True)
                subprocess.run(["git", "-C", str(nested), "init", "-q"],
                               check=True, capture_output=True)
            return result

        distrodeck._measure = measure_then_plant
        try:
            distrodeck.run_reclaim(args)
        finally:
            distrodeck._measure = real_measure

        assert target.exists(), "a candidate that gained a repository must survive"
        assert "skipping" in capsys.readouterr().out

    def test_still_eligible_refuses_when_only_ls_files_fails(self, repo, monkeypatch):
        """Isolated to `ls-files`, so an earlier guard cannot pass this for it.

        Breaking every git call makes `_worktree_of` return None, and the "no
        longer inside a worktree" check refuses first -- so the assertion would
        hold with the completeness check deleted. One call at a time is the only
        way it means what it says.
        """
        target = make_dir(repo, "build")
        assert distrodeck._still_eligible(target, None, True).reason == ""

        real = distrodeck._git

        def break_only_ls_files(worktree, *args, **kwargs):
            if args[0] == "ls-files":
                return None
            return real(worktree, *args, **kwargs)

        monkeypatch.setattr(distrodeck, "_git", break_only_ls_files)
        reason = distrodeck._still_eligible(target, None, True).reason
        assert reason == "git could not be consulted again", reason

    def test_still_eligible_refuses_a_vanished_directory(self, repo):
        assert distrodeck._still_eligible(repo / "gone", None, True).reason != ""

    def test_an_unchanged_candidate_is_still_deleted(self, repo, capsys):
        import argparse

        target = make_dir(repo, "build", age_days=30)
        args = argparse.Namespace(workspace=str(repo.parent), apply=True,
                                  include_environments=False, older_than=7,
                                  list=0, any_directory=False)
        distrodeck.run_reclaim(args)
        assert not target.exists()
        assert "freed" in capsys.readouterr().out


class TestTheExcludedHardLinkFigureIsAccurate:
    """The one number whose only job is to explain the gap must not overstate it.

    Adding a linked file's size once per *name* reports an inode with three links
    as three times its size. It is excluded from the total either way, so this
    does not affect what gets deleted -- but a figure offered as the reason the
    total is lower than expected is worthless if it is itself inflated.
    """

    def test_an_inode_with_three_names_is_counted_once(self, repo):
        target = make_dir(repo, "build", size=64 * 1024)
        try:
            os.link(target / "blob", target / "second")
            os.link(target / "blob", target / "third")
        except OSError:
            pytest.skip("filesystem does not support hard links")
        info = os.lstat(target / "blob")
        one_copy = (info.st_blocks * 512) if getattr(info, "st_blocks", None) else info.st_size
        linked = distrodeck._measure(target).linked
        assert linked <= one_copy * 1.5, f"{linked} looks like more than one copy of {one_copy}"

    def test_a_measurement_reports_its_own_tree_and_leaves_the_ledger_alone(self, repo):
        first = make_dir(repo, "build", size=64 * 1024)
        second = make_dir(repo, "target", size=16)
        try:
            os.link(first / "blob", second / "linked-in")
        except OSError:
            pytest.skip("filesystem does not support hard links")
        # `_measure` keeps no ledger: each tree reports its own multiply-linked
        # bytes, and de-duplicating across candidates is the caller's job.
        first_measured = distrodeck._measure(first)
        second_measured = distrodeck._measure(second)
        shared_inodes = set(first_measured.linked_inodes) & set(second_measured.linked_inodes)
        assert shared_inodes, "the test did not actually share an inode"
        # Both report it, on purpose: a measurement cannot know whether its
        # candidate will survive the age filter, so it is not the place that
        # decides which of the two accounts for the inode. It hands back the
        # inodes it saw and `find_reclaimable` counts each one once -- see
        # `test_find_reclaimable_shares_one_set_across_candidates`.
        assert first_measured.linked > 0 and second_measured.linked > 0
        assert set(first_measured.linked_inodes) >= shared_inodes

    def test_find_reclaimable_shares_one_set_across_candidates(self, repo):
        """Through the real entry point, not by handing `_measure` a set.

        A test that passes the shared set in itself proves only that `_measure`
        can de-duplicate, not that `find_reclaimable` gives it the chance --
        which is the part that would silently regress.
        """
        first = make_dir(repo, "build", size=256 * 1024)
        second = make_dir(repo, "target", size=16)
        try:
            os.link(first / "blob", second / "linked-in")
        except OSError:
            pytest.skip("filesystem does not support hard links")
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        linked_totals = [linked for _, _, _, linked in found]
        assert len([x for x in linked_totals if x > 0]) == 1, (
            f"the shared inode was accounted for more than once: {linked_totals}"
        )


@pytest.fixture
def unreadable():
    """Make a directory impossible to enumerate, and put it back afterwards.

    Skipped as root, which ignores the mode bits entirely -- a test that cannot
    create the condition it asserts about would otherwise pass by doing nothing,
    which is the failure shape this whole file is written against.
    """
    restore = []

    def block(path: Path):
        if os.geteuid() == 0:
            pytest.skip("running as root: permission bits do not apply")
        restore.append((path, os.stat(path).st_mode))
        os.chmod(path, 0o000)
        if os.access(path, os.R_OK):
            pytest.skip("filesystem ignores the read bit")
        return path

    yield block
    for path, mode in restore:
        os.chmod(path, mode)


class TestATreeItCannotReadIsNotOffered:
    """An unreadable subtree is "could not look", not "looked and found nothing".

    Both walks over a candidate -- the nested-repository search and the
    measurement -- used to discard `scandir` failures. A directory the walk
    cannot enter can hold a clone, and with `--older-than` it can hold the fresh
    file whose whole job is to say "somebody is working in here"; neither reached
    the decision. The candidate was then deleted on the strength of a search that
    never happened.
    """

    def test_an_unreadable_subtree_blocks_the_candidate(self, repo, unreadable):
        target = make_dir(repo, "build")
        unreadable(make_dir(repo, "build/nested"))
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == [], (
            f"{target} was offered although part of it could not be read"
        )

    def test_the_nested_repository_search_reports_incompleteness(self, repo, unreadable):
        target = make_dir(repo, "build")
        unreadable(make_dir(repo, "build/nested"))
        nested, readable = distrodeck._contains_nested_git(target)
        assert nested is False, "nothing was found, which is exactly the problem"
        assert readable is False, "and the search must say it could not look"

    def test_the_measurement_reports_incompleteness(self, repo, unreadable):
        target = make_dir(repo, "build")
        unreadable(make_dir(repo, "build/nested"))
        assert distrodeck._measure(target).complete is False

    def test_the_pre_delete_check_refuses_it(self, repo, unreadable):
        """With no cutoff, so only the nested-repository search can refuse.

        Passing `--older-than` here would let the measurement's own completeness
        check answer instead, and both produce a message containing the same
        words -- a test that cannot tell which of two guards fired does not
        establish that either of them does.
        """
        target = make_dir(repo, "build", age_days=30)
        unreadable(make_dir(repo, "build/nested", age_days=30))
        reason = distrodeck._still_eligible(target, None, True).reason
        assert reason, "an unreadable tree must not be approved for deletion"
        assert "repository inside it cannot be ruled out" in reason, reason

    def test_a_subtree_that_becomes_unreadable_between_the_two_walks(self, repo):
        """The measurement's own refusal, which nothing else can reach.

        A candidate is walked twice -- once to rule out a nested repository, once
        to measure -- and the first refusal filters out everything the second
        would have caught, so removing the measurement's guard broke no test. Its
        real subject is the window *between* the walks, which is also the only
        thing that distinguishes it from the first guard. Provoked here rather
        than waited for.
        """
        make_dir(repo, "build")
        nested = make_dir(repo, "build/nested")
        if os.geteuid() == 0:
            pytest.skip("running as root: permission bits do not apply")

        mode = os.stat(nested).st_mode
        os.chmod(nested, 0o000)
        ignores_the_bit = os.access(nested, os.R_OK)
        os.chmod(nested, mode)
        if ignores_the_bit:
            pytest.skip("filesystem ignores the read bit")

        real_search = distrodeck._contains_nested_git

        def search_then_block(path):
            result = real_search(path)
            os.chmod(nested, 0o000)
            return result

        distrodeck._contains_nested_git = search_then_block
        try:
            found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        finally:
            distrodeck._contains_nested_git = real_search
            os.chmod(nested, mode)
        assert found == [], (
            "a tree that stopped being readable after the repository search "
            "was still offered"
        )

    def test_a_readable_tree_still_passes(self, repo):
        """The same assertions with nothing blocked, so the refusal above is
        attributable to the unreadable subtree and not to the nesting itself."""
        target = make_dir(repo, "build", age_days=30)
        make_dir(repo, "build/nested", age_days=30)
        # Creating the child bumped the parent's own mtime to now; re-stamp it,
        # or this control fails for a reason that has nothing to do with reading.
        old = time.time() - 30 * 86400
        os.utime(target, (old, old))
        assert distrodeck._contains_nested_git(target) == (False, True)
        assert distrodeck._measure(target).complete is True
        assert distrodeck._still_eligible(target, time.time() - 7 * 86400, True).reason == ""
        assert [p.name for p, _, _, _ in
                distrodeck.find_reclaimable(repo.parent, ARTIFACTS)] == ["build"]


class TestARejectedCandidateDoesNotConsumeAnInode:
    """The inode ledger is shared across the scan, so it must only record
    candidates that survive.

    Measuring claims a hard-linked inode so it is not counted once per name. A
    candidate the age filter then rejects used to claim on its way out, and the
    accepted candidate that shared the inode found it already seen -- so the
    excluded-hard-link figure lost content that belonged to a tree actually being
    offered. Wrong in the one number whose only job is to explain the total.
    """

    def test_the_accepted_candidate_still_reports_the_shared_inode(self, repo):
        # `build` sorts first (fewer path parts) so it is measured first, and it
        # holds a fresh file, so `--older-than 7` rejects it.
        fresh = make_dir(repo, "build")
        old = make_dir(repo, "sub/target", age_days=30)
        try:
            os.link(old / "blob", fresh / "linked-in")
        except OSError:
            pytest.skip("filesystem does not support hard links")
        # The link shares the old inode's mtime, so it does not make `old` fresh.
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7)
        assert [p.name for p, _, _, _ in found] == ["target"], found
        linked = found[0][3]
        assert linked > 0, (
            "the inode was claimed by the candidate the age filter rejected"
        )


class TestApplyReportsFailureInItsExitStatus:
    """`--apply` printed "could not remove" and exited 0.

    A caller scripting this -- a cron entry, a CI step, the TUI -- had no way to
    learn that some or all of the deletion failed, because `run_reclaim` returned
    normally and the dispatcher ignores its return value. A command that reports
    success while freeing nothing is worse than one that fails.

    Skips are deliberately *not* failures: they are the pre-delete re-check doing
    its job, and conflating them would force a caller to choose between reading
    the exit status and keeping the protection.
    """

    @staticmethod
    def _args(repo, **over):
        base = dict(workspace=str(repo.parent), apply=True, include_environments=False,
                    older_than=0, list=0, any_directory=False)
        base.update(over)
        return argparse.Namespace(**base)

    def test_a_failed_removal_exits_nonzero(self, repo, monkeypatch):
        make_dir(repo, "build")
        monkeypatch.setattr(distrodeck.shutil, "rmtree",
                            lambda *a, **k: (_ for _ in ()).throw(OSError(13, "denied")))
        with pytest.raises(SystemExit) as exit_status:
            distrodeck.run_reclaim(self._args(repo))
        assert exit_status.value.code == 1

    def test_it_attempts_every_candidate_before_exiting(self, repo, monkeypatch):
        """The nonzero exit comes after the work, not instead of it."""
        make_dir(repo, "build")
        make_dir(repo, "target")
        attempted = []

        def refuse(path, *a, **k):
            attempted.append(str(path))
            raise OSError(13, "denied")

        monkeypatch.setattr(distrodeck.shutil, "rmtree", refuse)
        with pytest.raises(SystemExit):
            distrodeck.run_reclaim(self._args(repo))
        assert len(attempted) == 2, attempted

    def test_a_successful_removal_exits_zero(self, repo):
        target = make_dir(repo, "build")
        distrodeck.run_reclaim(self._args(repo))  # no SystemExit
        assert not target.exists()

    def test_a_skip_is_not_a_failure(self, repo, monkeypatch):
        """A candidate the re-check refuses must not make the run fail.

        Without this, the two outcomes would be indistinguishable to a caller and
        the safety re-check would start looking like a malfunction.
        """
        make_dir(repo, "build")
        monkeypatch.setattr(distrodeck, "_still_eligible",
                            lambda *a, **k: distrodeck.Recheck("a clone appeared inside it"))
        distrodeck.run_reclaim(self._args(repo))  # no SystemExit


class TestADescendantSurvivesAnAncestorTheCutoffRejects:
    """Containment de-duplication must come after the age filter, not before.

    A candidate absorbs the candidates inside it only if it is itself going to be
    deleted. De-duplicating first meant `build/node_modules` was discarded because
    `build` matched, and then `build` was rejected for a fresh file somewhere else
    inside it -- so an old, reclaimable `node_modules` was never offered at all.
    The same mistake as pruning matched trees from the walk, one stage later.
    """

    def test_the_old_inner_candidate_is_still_offered(self, repo):
        build = make_dir(repo, "build", age_days=30)
        inner = make_dir(repo, "build/node_modules", age_days=30)
        # Something else in `build` is being worked on right now, so `build`
        # itself must not be deleted.
        (build / "fresh.o").write_bytes(b"x" * 1024)
        old = time.time() - 30 * 86400
        os.utime(inner, (old, old))

        names = [p.name for p, _, _, _ in
                 distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7)]
        assert names == ["node_modules"], names

    def test_an_accepted_ancestor_still_absorbs_it(self, repo):
        """The control: when the ancestor does survive, the descendant is not
        reported separately, or the same bytes would be counted twice."""
        make_dir(repo, "build", age_days=30)
        make_dir(repo, "build/node_modules", age_days=30)
        old = time.time() - 30 * 86400
        os.utime(repo / "build", (old, old))

        names = [p.name for p, _, _, _ in
                 distrodeck.find_reclaimable(repo.parent, ARTIFACTS, older_than_days=7)]
        assert names == ["build"], names


class TestFreedBytesDescribeWhatWasRemoved:
    """The summary used the size the *scan* measured, minutes earlier.

    A `target/` that kept compiling between the report and the deletion is not
    the size it was found at, so "N GB freed" was a figure about the past. The
    pre-delete re-check already walks the tree; it now hands its measurement back
    and that is what the total accumulates.
    """

    @staticmethod
    def _args(repo):
        return argparse.Namespace(workspace=str(repo.parent), apply=True,
                                  include_environments=False, older_than=0,
                                  list=0, any_directory=False)

    def test_it_reports_the_size_at_deletion_not_at_scan(self, repo, capsys, monkeypatch):
        target = make_dir(repo, "build", size=4096)
        real_recheck = distrodeck._still_eligible

        def grow_then_check(path, *a, **k):
            # The build carried on after the scan: 2 MiB more than was reported.
            extra = path / "late.o"
            if not extra.exists():
                extra.write_bytes(b"x" * 2 * 1024 * 1024)
            return real_recheck(path, *a, **k)

        monkeypatch.setattr(distrodeck, "_still_eligible", grow_then_check)
        distrodeck.run_reclaim(self._args(repo))
        assert not target.exists()
        freed = [line for line in capsys.readouterr().out.splitlines() if "freed" in line]
        assert freed, "no freed summary was printed"
        assert "2.0MB" in freed[0] or "2.1MB" in freed[0], freed[0]

    def test_the_recheck_hands_back_its_measurement(self, repo):
        make_dir(repo, "build", size=4096)
        check = distrodeck._still_eligible(repo / "build", None, True)
        assert check.reason == ""
        assert check.measured is not None, (
            "the freed total has nothing current to add without it"
        )
        assert check.measured.total > 0

    def test_a_refusal_carries_no_measurement(self, repo):
        check = distrodeck._still_eligible(repo / "gone", None, True)
        assert check.reason and check.measured is None


class TestItRefusesToDeleteThroughAMountPoint:
    """`rmtree` walks through a mount point like any other directory.

    An ignored `build/` holding a bind mount, an NFS share or a mounted image
    would have the *mounted* filesystem's contents deleted -- data that is not the
    candidate's to free, that no build reproduces, and whose space does not come
    back to this disk anyway. Mounting needs root, so the detection is tested
    through both of its signals rather than by mounting something.
    """

    def test_a_differing_device_inside_the_tree_is_a_crossing(self, repo):
        target = make_dir(repo, "build")
        real = distrodeck._measure(target)
        assert real.crosses_mount is False, "nothing is mounted in a temp dir"
        two_devices = real._replace(crosses_mount=True)
        assert (distrodeck._mount_refusal(target, two_devices, set())
                == "a filesystem is mounted inside it")

    def test_a_mount_point_inside_the_tree_is_a_crossing(self, repo):
        target = make_dir(repo, "build")
        inside = str(target / "data")
        assert (distrodeck._mount_refusal(target, None, {inside})
                == "a filesystem is mounted inside it")

    def test_the_candidate_itself_being_a_mount_is_a_crossing(self, repo):
        """`rmtree` empties it and leaves the mount behind: nothing is reclaimed."""
        target = make_dir(repo, "build")
        assert distrodeck._mount_refusal(target, None, {str(target)})

    def test_a_sibling_mount_is_not(self, repo):
        """The prefix test must not match a directory that merely starts the same."""
        target = make_dir(repo, "build")
        assert distrodeck._mount_refusal(target, None, {str(target) + "-output"}) == ""

    def test_an_unreadable_mount_table_does_not_refuse_on_its_own(self, repo):
        """`None` means that half of the check did not run, not "no mounts".

        Refusing every candidate when `/proc` is unavailable would make the
        command useless in a container; the `st_dev` signal still covers a
        separate filesystem, which is the common case.
        """
        target = make_dir(repo, "build")
        assert distrodeck._mount_refusal(target, distrodeck._measure(target), None) == ""

    def test_the_scan_skips_a_candidate_with_a_mount_inside(self, repo, monkeypatch):
        target = make_dir(repo, "build")
        monkeypatch.setattr(distrodeck, "_mount_points", lambda: {str(target / "share")})
        assert distrodeck.find_reclaimable(repo.parent, ARTIFACTS) == []

    def test_the_pre_delete_check_refuses_one(self, repo, monkeypatch):
        target = make_dir(repo, "build")
        monkeypatch.setattr(distrodeck, "_mount_points", lambda: {str(target / "share")})
        check = distrodeck._still_eligible(target, None, True)
        assert check.reason == "a filesystem is mounted inside it", check.reason

    def test_a_mount_appearing_after_the_scan_is_still_caught(self, repo, monkeypatch):
        """The scan and the deletion are minutes apart; the table is re-read."""
        target = make_dir(repo, "build")
        # The table is clean while the scan reads it and dirty by the time the
        # deletion loop re-reads it. Patching it before `run_reclaim` would let the
        # scan's own refusal answer, and this test would pass with the pre-delete
        # check removed -- which it did, the first time it was written.
        reads = {"n": 0}

        def table_then_mount():
            reads["n"] += 1
            return set() if reads["n"] == 1 else {str(target / "share")}

        monkeypatch.setattr(distrodeck, "_mount_points", table_then_mount)
        args = argparse.Namespace(workspace=str(repo.parent), apply=True,
                                  include_environments=False, older_than=0,
                                  list=0, any_directory=False)
        distrodeck.run_reclaim(args)
        assert reads["n"] >= 2, "the mount table was not re-read before deleting"
        assert target.exists(), "it was deleted through a mount that appeared late"

    def test_the_real_mount_table_is_read(self, repo):
        """Against this machine, not a fixture: `/` has mounts under it."""
        points = distrodeck._mount_points()
        if points is None:
            pytest.skip("no /proc/self/mountinfo on this platform")
        assert len(points) > 1
        assert distrodeck._mount_refusal(Path("/"), None, points)

    def test_escaped_paths_are_decoded(self):
        """A mount under a directory with a space would otherwise compare against
        a truncated string and match nothing."""
        line = "22 1 0:5 / /mnt/my\\040disk rw,relatime shared:2 - tmpfs tmpfs rw"
        assert distrodeck._parse_mountinfo([line]) == {"/mnt/my disk"}


class TestWorktreeLookupCostsOneCallPerRepository:
    """A `rev-parse` per candidate made the per-worktree batching pointless.

    The git calls were batched two-per-repository precisely because subprocesses
    are the expensive part -- and then deciding which repository each candidate
    belonged to spent one subprocess per candidate, thousands of them on a real
    workspace. Counted here rather than timed, because a timing assertion on a
    shared machine fails for reasons that have nothing to do with this.
    """

    def test_many_candidates_in_one_repository_ask_git_once(self, repo, monkeypatch):
        for name in ("build", "target", "node_modules", ".dart_tool", ".gradle"):
            make_dir(repo, name)
        make_dir(repo, "deep/nested/further/build")

        calls = []
        real_git = distrodeck._git

        def counted(worktree, *args, **kwargs):
            if args and args[0] == "rev-parse":
                calls.append(str(worktree))
            return real_git(worktree, *args, **kwargs)

        monkeypatch.setattr(distrodeck, "_git", counted)
        found = distrodeck.find_reclaimable(repo.parent, ARTIFACTS)
        # Five: the fixture's .gitignore does not list `.gradle`, so that one is
        # correctly not offered -- which is itself worth asserting on.
        assert len(found) == 5, [str(path) for path, _, _, _ in found]
        assert len(calls) == 1, (
            f"{len(calls)} rev-parse calls for {len(found)} candidates: {calls}"
        )

    def test_two_repositories_ask_twice(self, repo, tmp_path):
        """The control: the cache must not collapse distinct repositories."""
        other = tmp_path / "other"
        other.mkdir()
        git(other, "init", "-q")
        (other / ".gitignore").write_text("build/\n")
        make_dir(repo, "build")
        make_dir(other, "build")
        found = distrodeck.find_reclaimable(tmp_path, ARTIFACTS)
        roots = {str(p.parent) for p, _, _, _ in found}
        assert roots == {str(repo), str(other)}, roots

    def test_a_submodule_resolves_to_the_submodule(self, repo, tmp_path):
        """Innermost wins, as `git` itself does -- the cache must not hand a
        nested repository its parent's worktree, or the ignore question would be
        asked of the wrong `.gitignore`."""
        inner = repo / "vendor" / "lib"
        inner.mkdir(parents=True)
        git(inner, "init", "-q")
        (inner / ".gitignore").write_text("build/\n")
        target = make_dir(inner, "build")
        assert distrodeck._worktree_of(target) == inner
        # and through the cache, with the outer repository resolved first
        cache: dict = {}
        assert distrodeck._worktree_of(make_dir(repo, "build"), cache) == repo
        assert distrodeck._worktree_of(target, cache) == inner

    def test_a_directory_outside_any_repository_asks_nothing(self, tmp_path, monkeypatch):
        loose = tmp_path / "loose" / "build"
        loose.mkdir(parents=True)
        calls = []
        monkeypatch.setattr(distrodeck, "_git",
                            lambda *a, **k: calls.append(a) or None)
        assert distrodeck._worktree_of(loose) is None
        assert calls == [], f"asked git about a tree with no .git anywhere: {calls}"


class TestACandidateThatIsItselfAMountIsCaughtWithoutTheTable:
    """Everything under a mount point is one device, so the tree looks ordinary.

    The first version of this check asked two questions -- more than one device
    *inside* the candidate, and the mount table -- and a candidate that was itself
    a separate-filesystem mount answered no to both: one device throughout, and
    nothing to consult where `/proc/self/mountinfo` could not be read. `--apply`
    would then have emptied the mounted filesystem, against the refusal the
    documentation promises. Comparing the candidate's device with its parent's is
    the question that needs no table.
    """

    @staticmethod
    def _a_real_mount_point():
        for candidate in ("/dev/shm", "/run", "/proc", "/sys"):
            path = Path(candidate)
            own, parent = distrodeck._device_of(path), distrodeck._device_of(path.parent)
            if path.is_dir() and own is not None and parent is not None and own != parent:
                return path
        return None

    def test_with_no_mount_table_at_all(self):
        """Against this machine's real filesystems, with `points=None`."""
        mount = self._a_real_mount_point()
        if mount is None:
            pytest.skip("no separate-filesystem mount point found to test against")
        assert (distrodeck._mount_refusal(mount, None, None)
                == "it is itself a mount point"), mount

    def test_a_measurement_inside_it_sees_nothing_wrong(self):
        """Why the parent comparison is necessary and not redundant."""
        mount = self._a_real_mount_point()
        if mount is None:
            pytest.skip("no separate-filesystem mount point found to test against")
        try:
            measured = distrodeck._measure(mount)
        except OSError:
            pytest.skip(f"cannot measure {mount}")
        assert measured.crosses_mount is False, (
            "one device throughout, which is exactly why this case slipped through"
        )

    def test_an_ordinary_directory_is_not_a_mount_point(self, repo):
        target = make_dir(repo, "build")
        assert distrodeck._mount_refusal(target, None, None) == ""

    def test_an_unreadable_device_fails_closed(self, repo):
        missing = repo / "build"
        assert (distrodeck._mount_refusal(missing, None, None)
                == "its filesystem could not be identified")
