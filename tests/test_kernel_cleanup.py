import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "distrodeck.py"
SPEC = importlib.util.spec_from_file_location("distrodeck_module", MODULE_PATH)
distrodeck = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(distrodeck)


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
