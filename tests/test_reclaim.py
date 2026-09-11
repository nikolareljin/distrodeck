"""Reclaiming disk that a build can make again.

A workspace of checkouts is mostly not source. Measured on one machine, 90 GB
across roughly a hundred repositories: 33.4 GB of `build/`, 20.2 GB of Rust
`target/`, 5.2 GB of `.dart_tool/` -- about three quarters of the total, none of
it authored by anybody.

What is worth testing is not the arithmetic but the refusals: that it does not
enter a repository's history, does not count the same bytes twice, does not
touch work in progress, and does not delete anything unless asked twice.
"""

import importlib.util
import os
import time
from pathlib import Path

import pytest

MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
distrodeck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(distrodeck)

ARTIFACTS = distrodeck.RECLAIM_ARTIFACTS


def make_dir(base: Path, relative: str, size: int = 1024, age_days: float = 0):
    path = base / relative
    path.mkdir(parents=True, exist_ok=True)
    (path / "blob").write_bytes(b"x" * size)
    if age_days:
        old = time.time() - age_days * 86400
        os.utime(path, (old, old))
    return path


class TestWhatItFinds:
    def test_it_finds_build_output(self, tmp_path):
        make_dir(tmp_path, "repo/build", size=4096)
        found = distrodeck.find_reclaimable(tmp_path, ARTIFACTS)
        assert [p.name for p, _, _ in found] == ["build"]

    def test_it_reports_the_size(self, tmp_path):
        make_dir(tmp_path, "repo/target", size=8192)
        (_, size, _), = distrodeck.find_reclaimable(tmp_path, ARTIFACTS)
        assert size >= 8192

    def test_it_leaves_source_alone(self, tmp_path):
        make_dir(tmp_path, "repo/src")
        assert distrodeck.find_reclaimable(tmp_path, ARTIFACTS) == []

    def test_biggest_first(self, tmp_path):
        make_dir(tmp_path, "a/build", size=1024)
        make_dir(tmp_path, "b/build", size=64 * 1024)
        found = distrodeck.find_reclaimable(tmp_path, ARTIFACTS)
        assert found[0][1] > found[1][1]


class TestWhatItRefusesToTouch:
    def test_it_never_enters_a_git_directory(self, tmp_path):
        # A repository's history is not build output, however large it grows,
        # and a command that can delete must be obviously incapable of deleting
        # that. `.git/build` is a plausible internal path, not a contrivance.
        make_dir(tmp_path, "repo/.git/build", size=4096)
        assert distrodeck.find_reclaimable(tmp_path, ARTIFACTS) == []

    def test_it_does_not_count_nested_artifacts_twice(self, tmp_path):
        # node_modules inside build is one directory's worth of bytes, not two,
        # and walking into it after claiming the parent also costs minutes on a
        # real dependency tree.
        make_dir(tmp_path, "repo/build/node_modules", size=4096)
        found = distrodeck.find_reclaimable(tmp_path, ARTIFACTS)
        assert [p.name for p, _, _ in found] == ["build"]

    def test_virtualenvs_are_not_included_by_default(self, tmp_path):
        # Rebuildable, but restoring one that holds torch is a multi-gigabyte
        # download that fails entirely without a network -- a different risk
        # from re-running a compiler, so a different flag.
        make_dir(tmp_path, "repo/venv", size=4096)
        assert distrodeck.find_reclaimable(tmp_path, ARTIFACTS) == []

    def test_but_they_can_be_asked_for(self, tmp_path):
        make_dir(tmp_path, "repo/venv", size=4096)
        names = {**ARTIFACTS, **distrodeck.RECLAIM_ENVIRONMENTS}
        assert [p.name for p, _, _ in distrodeck.find_reclaimable(tmp_path, names)] == ["venv"]


class TestAgeProtectsWorkInProgress:
    def test_recent_output_is_left_alone(self, tmp_path):
        make_dir(tmp_path, "repo/build", age_days=0)
        assert distrodeck.find_reclaimable(tmp_path, ARTIFACTS, older_than_days=7) == []

    def test_old_output_is_offered(self, tmp_path):
        make_dir(tmp_path, "repo/build", age_days=30)
        assert len(distrodeck.find_reclaimable(tmp_path, ARTIFACTS, older_than_days=7)) == 1

    def test_zero_days_means_everything(self, tmp_path):
        make_dir(tmp_path, "repo/build", age_days=0)
        assert len(distrodeck.find_reclaimable(tmp_path, ARTIFACTS, older_than_days=0)) == 1


class TestItDoesNotDeleteUnlessAskedTwice:
    def _args(self, tmp_path, **overrides):
        import argparse

        defaults = dict(
            workspace=str(tmp_path), apply=False, include_environments=False,
            older_than=0, list=0,
        )
        defaults.update(overrides)
        return argparse.Namespace(**defaults)

    def test_a_report_deletes_nothing(self, tmp_path, capsys):
        target = make_dir(tmp_path, "repo/build", size=4096)
        distrodeck.run_reclaim(self._args(tmp_path))
        assert target.exists()
        assert "Nothing was deleted" in capsys.readouterr().out

    def test_apply_deletes(self, tmp_path, capsys):
        target = make_dir(tmp_path, "repo/build", size=4096)
        distrodeck.run_reclaim(self._args(tmp_path, apply=True))
        assert not target.exists()
        assert "freed" in capsys.readouterr().out

    def test_apply_leaves_the_repository_behind(self, tmp_path):
        # The point is to reclaim output, not to remove checkouts.
        make_dir(tmp_path, "repo/build", size=4096)
        make_dir(tmp_path, "repo/src", size=16)
        distrodeck.run_reclaim(self._args(tmp_path, apply=True))
        assert (tmp_path / "repo" / "src").exists()

    def test_an_empty_workspace_says_so_rather_than_failing(self, tmp_path, capsys):
        distrodeck.run_reclaim(self._args(tmp_path))
        assert "Nothing reclaimable" in capsys.readouterr().out
