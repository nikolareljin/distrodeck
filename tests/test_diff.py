import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
if SPEC is None:
    raise RuntimeError(f"Could not load module spec from {MODULE_PATH}")
distrodeck = importlib.util.module_from_spec(SPEC)
if SPEC.loader is None:
    raise RuntimeError(f"Could not load module loader from {MODULE_PATH}")
SPEC.loader.exec_module(distrodeck)


EXPORT_TEXT = """# distrodeck export v1
exported_at=2026-08-21T00:00:00Z
distro_id=ubuntu
codename=noble

[apt_manual]
curl
git
htop

[snap]
code channel=latest/stable classic=true

[flatpak]
remote=flathub app=org.gimp.GIMP
"""


@pytest.fixture
def export_file(tmp_path):
    path = tmp_path / "backup.txt"
    path.write_text(EXPORT_TEXT, encoding="utf-8")
    return path


def _args(**overrides):
    defaults = {
        "input": None,
        "sections": None,
        "detailed": False,
        "json": False,
        "exit_code": False,
        "appimage_dirs": None,
    }
    defaults.update(overrides)
    return SimpleNamespace(**defaults)


def test_compute_diff_reports_missing_and_extra():
    desired = {"apt_manual": ["curl", "git", "htop"]}
    current = {"apt_manual": ["git", "vim"]}

    result = distrodeck.compute_diff(desired, current, ["apt_manual"])

    assert result["apt_manual"]["missing"] == ["curl", "htop"]
    assert result["apt_manual"]["extra"] == ["vim"]


def test_compute_diff_is_sorted_regardless_of_input_order():
    desired = {"apt_manual": ["zsh", "curl", "git"]}
    current = {"apt_manual": ["vim", "aria2"]}

    result = distrodeck.compute_diff(desired, current, ["apt_manual"])

    assert result["apt_manual"]["missing"] == ["curl", "git", "zsh"]
    assert result["apt_manual"]["extra"] == ["aria2", "vim"]


def test_compute_diff_honours_section_filter():
    desired = {"apt_manual": ["curl"], "snap": ["code"]}
    current = {"apt_manual": [], "snap": []}

    result = distrodeck.compute_diff(desired, current, ["snap"])

    assert list(result) == ["snap"]


def test_compute_diff_skips_unknown_sections():
    result = distrodeck.compute_diff({}, {}, ["not_a_section"])

    assert result == {}


def test_compute_diff_normalizes_snap_and_flatpak_entries():
    # Export entries carry extra columns; current state must be compared on the
    # normalized name, not the raw line.
    desired = {
        "snap": ["code channel=latest/stable classic=true"],
        "flatpak": ["remote=flathub app=org.gimp.GIMP"],
    }
    # Current state as collected from a machine where the channel and remote
    # differ: the comparison must key on the package name only.
    current = {
        "snap": ["code channel=latest/edge classic=false"],
        "flatpak": ["remote=fedora app=org.gimp.GIMP"],
    }

    result = distrodeck.compute_diff(desired, current, ["snap", "flatpak"])

    assert result["snap"] == {"missing": [], "extra": []}
    assert result["flatpak"] == {"missing": [], "extra": []}


def test_run_diff_json_output_is_parseable(export_file, monkeypatch, capsys):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {
            "apt_manual": ["git", "vim"],
            "snap": ["code channel=latest/stable classic=true"],
            "flatpak": [],
        },
    )

    distrodeck.run_diff(_args(input=str(export_file), json=True))

    payload = json.loads(capsys.readouterr().out)
    assert payload["schema"] == 1
    assert payload["export_distro_id"] == "ubuntu"
    assert payload["current_distro_id"] == distrodeck.get_os_id()
    assert payload["sections"]["apt_manual"]["missing"] == ["curl", "htop"]
    assert payload["sections"]["apt_manual"]["extra"] == ["vim"]
    assert payload["sections"]["snap"] == {"missing": [], "extra": []}
    assert payload["sections"]["flatpak"]["missing"] == ["org.gimp.GIMP"]
    assert payload["summary"]["missing"] == 3
    assert payload["summary"]["extra"] == 1


def test_run_diff_text_output_summarizes_each_section(export_file, monkeypatch, capsys):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {
            "apt_manual": ["git"],
            "snap": ["code channel=latest/stable classic=true"],
        },
    )

    distrodeck.run_diff(_args(input=str(export_file)))

    out = capsys.readouterr().out
    assert "apt_manual" in out
    # Not detailed: package names must not be listed.
    assert "curl" not in out


def test_run_diff_detailed_lists_entries(export_file, monkeypatch, capsys):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {
            "apt_manual": ["git"],
            "snap": ["code channel=latest/stable classic=true"],
        },
    )

    distrodeck.run_diff(_args(input=str(export_file), detailed=True))

    out = capsys.readouterr().out
    assert "curl" in out
    assert "htop" in out


def test_run_diff_exit_code_flag_signals_differences(export_file, monkeypatch):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {"apt_manual": [], "snap": []},
    )

    with pytest.raises(SystemExit) as excinfo:
        distrodeck.run_diff(_args(input=str(export_file), exit_code=True))

    assert excinfo.value.code == 1


def test_run_diff_exit_code_flag_is_zero_when_in_sync(export_file, monkeypatch):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {
            "apt_manual": ["curl", "git", "htop"],
            "snap": ["code channel=latest/stable classic=true"],
            "flatpak": ["remote=flathub app=org.gimp.GIMP"],
        },
    )

    # No SystemExit: an in-sync system exits 0 even with --exit-code.
    distrodeck.run_diff(_args(input=str(export_file), exit_code=True))


def test_run_diff_without_exit_code_flag_returns_normally(export_file, monkeypatch):
    monkeypatch.setattr(
        distrodeck,
        "collect_current_state",
        lambda sections, appimage_dirs=None: {"apt_manual": [], "snap": []},
    )

    distrodeck.run_diff(_args(input=str(export_file)))


def test_run_diff_missing_file_fails(tmp_path):
    with pytest.raises(SystemExit) as excinfo:
        distrodeck.run_diff(_args(input=str(tmp_path / "nope.txt")))

    assert excinfo.value.code != 0
