import importlib.util
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
assert SPEC is not None, f"Could not load module spec from {MODULE_PATH}"
distrodeck = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(distrodeck)


def test_kernel_base_preserves_debian_revision():
    assert distrodeck._kernel_base("6.1.0-0.deb12.5-amd64") == "6.1.0-0.deb12.5"
    assert distrodeck._kernel_base("6.1.0-0.deb12.5-common") == "6.1.0-0.deb12.5"
    assert distrodeck._kernel_base("6.1.0-0.deb12.5-rt-amd64") == "6.1.0-0.deb12.5"


def test_cleanup_kernels_accepts_keep_kernels_alias():
    parser = distrodeck.build_parser()

    args = parser.parse_args(["cleanup-kernels", "--keep-kernels", "2"])

    assert args.keep == 2


def test_cleanup_kernels_command_does_not_exit_for_unsupported_system(monkeypatch):
    calls = []

    def fake_run_cleanup(args):
        calls.append(args)
        return False

    monkeypatch.setattr(distrodeck, "run_cleanup_kernels", fake_run_cleanup)
    monkeypatch.setattr(distrodeck, "cleanup_kernels_supported", lambda: False)

    distrodeck.run_cleanup_kernels_cmd(distrodeck.argparse.Namespace())

    assert len(calls) == 1


def test_cleanup_kernels_command_exits_for_supported_failure(monkeypatch):
    monkeypatch.setattr(distrodeck, "run_cleanup_kernels", lambda args: False)
    monkeypatch.setattr(distrodeck, "cleanup_kernels_supported", lambda: True)

    with pytest.raises(SystemExit) as exc:
        distrodeck.run_cleanup_kernels_cmd(distrodeck.argparse.Namespace())

    assert exc.value.code == 1


def test_select_old_kernel_packages_keeps_running_and_one_previous():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-modules-6.8.0-47-generic",
        "linux-headers-6.8.0-47",
        "linux-headers-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-modules-6.8.0-46-generic",
        "linux-headers-6.8.0-46",
        "linux-headers-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
        "linux-modules-extra-6.8.0-45-generic",
        "linux-headers-6.8.0-45",
        "linux-headers-6.8.0-45-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-47-generic",
        keep_previous=1,
    )

    assert bases == ["6.8.0-45"]
    assert packages == [
        "linux-headers-6.8.0-45",
        "linux-headers-6.8.0-45-generic",
        "linux-image-6.8.0-45-generic",
        "linux-modules-extra-6.8.0-45-generic",
    ]


def test_select_old_kernel_packages_respects_keep_two():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
        "linux-image-6.8.0-44-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-47-generic",
        keep_previous=2,
    )

    assert bases == ["6.8.0-44"]
    assert packages == ["linux-image-6.8.0-44-generic"]


def test_select_old_kernel_packages_keeps_previous_adjacent_to_running_kernel():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
        "linux-image-6.8.0-44-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-45-generic",
        keep_previous=1,
    )

    assert bases == []
    assert packages == []


def test_select_old_kernel_packages_never_removes_newer_than_running_kernel():
    installed = [
        "linux-image-6.8.0-48-generic",
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
        "linux-image-6.8.0-44-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-46-generic",
        keep_previous=1,
    )

    assert bases == ["6.8.0-44"]
    assert packages == ["linux-image-6.8.0-44-generic"]


def test_select_old_kernel_packages_keeps_newer_when_running_is_manual():
    installed = [
        "linux-image-6.8.0-48-generic",
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
        "linux-image-6.8.0-44-generic",
    ]
    auto = [
        "linux-image-6.8.0-48-generic",
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-45-generic",
        "linux-image-6.8.0-44-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        auto,
        "6.8.0-46-generic",
        keep_previous=1,
    )

    assert bases == ["6.8.0-44"]
    assert packages == ["linux-image-6.8.0-44-generic"]


def test_select_old_kernel_packages_handles_debian_kernel_names():
    installed = [
        "linux-image-6.1.0-0.deb12.5-amd64",
        "linux-headers-6.1.0-0.deb12.5-common",
        "linux-headers-6.1.0-0.deb12.5-amd64",
        "linux-image-6.1.0-0.deb12.4-rt-amd64",
        "linux-headers-6.1.0-0.deb12.4-common",
        "linux-headers-6.1.0-0.deb12.4-rt-amd64",
        "linux-image-6.1.0-0.deb12.3-amd64",
        "linux-headers-6.1.0-0.deb12.3-common",
        "linux-headers-6.1.0-0.deb12.3-amd64",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.1.0-0.deb12.5-amd64",
        keep_previous=1,
    )

    assert bases == ["6.1.0-0.deb12.3"]
    assert packages == [
        "linux-headers-6.1.0-0.deb12.3-amd64",
        "linux-headers-6.1.0-0.deb12.3-common",
        "linux-image-6.1.0-0.deb12.3-amd64",
    ]


def test_select_old_kernel_packages_ignores_manual_kernel_packages():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-image-6.8.0-45-generic",
    ]
    auto = [
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        auto,
        "6.8.0-47-generic",
        keep_previous=1,
    )

    assert bases == []
    assert packages == []


def test_select_old_kernel_packages_ignores_non_kernel_module_packages():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-image-6.8.0-46-generic",
        "linux-modules-nvidia-550-6.8.0-45-generic",
        "linux-modules-ipu6-6.8.0-45-generic",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-47-generic",
        keep_previous=1,
    )

    assert bases == []
    assert packages == []


def test_select_old_kernel_packages_noop_when_only_current_and_previous():
    installed = [
        "linux-image-6.8.0-47-generic",
        "linux-headers-6.8.0-47",
        "linux-image-6.8.0-46-generic",
        "linux-headers-6.8.0-46",
    ]

    packages, bases = distrodeck.select_old_kernel_packages(
        installed,
        installed,
        "6.8.0-47-generic",
        keep_previous=1,
    )

    assert bases == []
    assert packages == []
