#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["hatchling"]
# ///
"""Build one wheel per platform."""

import os
import subprocess
from pathlib import Path

from hatch import WheelTag

dist = Path("dist")
dist.mkdir(exist_ok=True)

for tag in WheelTag:
    print(f"  building {tag}...", end=" ", flush=True)
    subprocess.run(
        ["hatch", "build", "-t", "wheel"],
        check=True,
        capture_output=True,
        env={**os.environ, "NECRO_PLATFORM": tag},
    )
    print("ok")

print("\n=== Wheels ===")
for whl in sorted(dist.glob("*.whl")):
    print(f"  {whl.name}")
