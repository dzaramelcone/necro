#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["hatchling"]
# ///
"""Bump version, build wheels, publish to PyPI.

Usage: ./publish.py --version patch
       ./publish.py --version minor
       ./publish.py --version major
"""

import argparse
import re
import subprocess
from pathlib import Path

PYPROJECT = Path("pyproject.toml")


def read_version() -> tuple[int, int, int]:
    text = PYPROJECT.read_text()
    match = re.search(r'^version\s*=\s*"(\d+)\.(\d+)\.(\d+)"', text, re.MULTILINE)
    if not match:
        raise RuntimeError(f"Could not find semver version in {PYPROJECT}")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def write_version(major: int, minor: int, patch: int) -> str:
    version = f"{major}.{minor}.{patch}"
    text = PYPROJECT.read_text()
    text = re.sub(
        r'^(version\s*=\s*)"[^"]*"',
        f'\\1"{version}"',
        text,
        count=1,
        flags=re.MULTILINE,
    )
    PYPROJECT.write_text(text)
    return version


def bump(current: tuple[int, int, int], part: str) -> tuple[int, int, int]:
    major, minor, patch = current
    if part == "major":
        return major + 1, 0, 0
    if part == "minor":
        return major, minor + 1, 0
    return major, minor, patch + 1


parser = argparse.ArgumentParser(description="Bump, build, publish.")
parser.add_argument("--version", required=True, choices=["major", "minor", "patch"])
parser.add_argument("--dry-run", action="store_true", help="Build but don't publish")
args = parser.parse_args()

old = read_version()
new = bump(old, args.version)
version = f"{new[0]}.{new[1]}.{new[2]}"
print(f"\n  version: {'.'.join(map(str, old))} → {version}")

if args.dry_run:
    print("  --dry-run: would build and publish, but not doing anything\n")
else:
    write_version(*new)
    subprocess.run(["uv", "run", "build.py"], check=True)
    subprocess.run(["uv", "publish", "--sign"], check=True)
    print(f"\n  published necro {version}")
