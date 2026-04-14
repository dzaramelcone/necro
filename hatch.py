"""Hatch build hook - compile the Zig native extension and tag the wheel."""

import os
import shutil
import subprocess
from enum import StrEnum
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface


class ZigOptimize(StrEnum):
    DEBUG = "Debug"
    RELEASE_SAFE = "ReleaseSafe"
    RELEASE_FAST = "ReleaseFast"
    RELEASE_SMALL = "ReleaseSmall"


class WheelTag(StrEnum):
    MACOS_ARM64 = "macosx_11_0_arm64"
    LINUX_X86_64 = "manylinux_2_17_x86_64"
    LINUX_AARCH64 = "manylinux_2_17_aarch64"


class ZigTarget(StrEnum):
    MACOS_ARM64 = "aarch64-macos"
    LINUX_X86_64 = "x86_64-linux-gnu"
    LINUX_AARCH64 = "aarch64-linux-gnu"


class LibExt(StrEnum):
    DYLIB = "dylib"
    SO = "so"


PYTHON_TAG = "cp314"
ABI_TAG = PYTHON_TAG
SOABI_PREFIX = "cpython-314"
LIB_DIR = Path("zig-out/lib")
PKG_DIR = Path("python/necro")
LIB_BASE = "libcore"
SO_BASE = "core"
OPTIMIZE = ZigOptimize.RELEASE_FAST
TARGETS = {
    WheelTag.MACOS_ARM64: (ZigTarget.MACOS_ARM64, LibExt.DYLIB, "darwin"),
    WheelTag.LINUX_X86_64: (ZigTarget.LINUX_X86_64, LibExt.SO, ""),
    WheelTag.LINUX_AARCH64: (ZigTarget.LINUX_AARCH64, LibExt.SO, ""),
}


class ZigBuildHook(BuildHookInterface):
    PLUGIN_NAME = "zig"

    def initialize(self, version, build_data):
        platform = os.environ.get("NECRO_PLATFORM")
        if not platform:
            return

        wheel_tag = WheelTag(platform)
        zig_target, lib_ext, so_suffix = TARGETS[wheel_tag]

        subprocess.run(
            ["zig", "build", f"-Dtarget={zig_target}", f"-Doptimize={OPTIMIZE}"],
            check=True,
        )

        src = LIB_DIR / f"{LIB_BASE}.{lib_ext}"
        so_name = f"{SO_BASE}.{SOABI_PREFIX}-{so_suffix or zig_target}.so"
        dest = PKG_DIR / so_name
        dest.unlink(missing_ok=True)
        shutil.copy2(src, dest)

        build_data["force_include"] = {str(dest): f"necro/{so_name}"}
        build_data["pure_python"] = False
        build_data["tag"] = f"{PYTHON_TAG}-{ABI_TAG}-{wheel_tag}"
