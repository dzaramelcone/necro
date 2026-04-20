"""necro CLI - run a necro app.

Usage: necro host app
       necro host app --port 9000
       necro host app --host 0.0.0.0 --port 8080
       necro host app --reload
       necro host app --threads 4
"""

import argparse
import importlib
import os
import signal
import subprocess
import sys
import time
import tomllib
from pathlib import Path

from necro import core, __version__


def load_config() -> dict:
    """Load [tool.necro] from pyproject.toml in cwd, or return empty dict."""
    path = Path("pyproject.toml")
    if not path.exists():
        return {}
    data = tomllib.loads(path.read_text())
    return data.get("tool", {}).get("necro", {})


def apply_config_env(config: dict) -> None:
    """Set PG_*/REDIS_* env vars from config, only if not already set."""
    pg = config.get("postgres", {})
    env_map = {
        "PG_HOST": pg.get("host"),
        "PG_PORT": pg.get("port"),
        "PG_USER": pg.get("user"),
        "PG_PASS": pg.get("password"),
        "PG_DB": pg.get("database"),
        "PG_POOL_SIZE": pg.get("pool_size"),
    }
    redis = config.get("redis", {})
    env_map["REDIS_HOST"] = redis.get("host")

    for key, value in env_map.items():
        if value is not None and key not in os.environ:
            os.environ[key] = str(value)


WATCH_EXCLUDE = {
    ".venv",
    "venv",
    "__pycache__",
    "refs",
    "build",
    "zig-out",
    ".zig-cache",
    "node_modules",
}


def collect_py_mtimes(directory: str = ".") -> dict[str, float]:
    mtimes: dict[str, float] = {}
    for p in Path(directory).rglob("*.py"):
        if any(part in WATCH_EXCLUDE for part in p.parts):
            continue
        mtimes[str(p)] = p.stat().st_mtime
    return mtimes


def run_with_reload(args: argparse.Namespace) -> None:
    """Supervisor process: spawn the server, watch .py files, restart on change."""
    cmd = [
        sys.executable,
        "-m",
        "necro.cli",
        *[a for a in sys.argv[1:] if a != "--reload"],
    ]
    proc: subprocess.Popen | None = None

    def cleanup(signum, frame):
        if proc and proc.poll() is None:
            proc.terminate()
            proc.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    while True:
        mtimes = collect_py_mtimes()
        proc = subprocess.Popen(cmd)
        print(f"  [reload] watching for .py changes (pid {proc.pid})\n")

        changed = False
        while not changed:
            time.sleep(1)
            if proc.poll():
                sys.exit(proc.returncode)
            current = collect_py_mtimes()
            for path, old_mtime in mtimes.items():
                if current.get(path, 0) != old_mtime:
                    print(f"\n  [reload] {path} changed, restarting...")
                    changed = True
                    break
            if not changed and set(current) - set(mtimes):
                print("\n  [reload] new file detected, restarting...")
                changed = True

        proc.terminate()
        proc.wait()


def run_server(args: argparse.Namespace) -> None:
    """Run the server directly (no reload)."""
    sys.path.insert(0, ".")
    mod = importlib.import_module(args.module)
    search_path = os.path.dirname(os.path.abspath(mod.__file__))
    core.run(
        args.host,
        args.port,
        args.threads,
        args.module,
        search_path,
        args.backlog,
        __version__,
        args.cert or "",
        args.key or "",
    )


def main():
    config = load_config()

    parser = argparse.ArgumentParser(
        prog="necro", description="Run a necro application."
    )
    sub = parser.add_subparsers(dest="command")

    host_parser = sub.add_parser("host", help="Run a necro application")
    host_parser.add_argument("module", help="module to import (e.g. myapp)")
    host_parser.add_argument("--host", default=config.get("host", "0.0.0.0"))
    host_parser.add_argument("--port", type=int, default=config.get("port", 8080))
    host_parser.add_argument("--threads", type=int, default=config.get("threads", 1))
    host_parser.add_argument("--backlog", type=int, default=config.get("backlog", 2048))
    host_parser.add_argument("--cert", default=None)
    host_parser.add_argument("--key", default=None)
    host_parser.add_argument(
        "--reload", action="store_true", help="auto-reload on .py changes"
    )

    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        sys.exit(0)

    if args.command == "host":
        apply_config_env(config)

        if args.reload:
            run_with_reload(args)
        else:
            run_server(args)


if __name__ == "__main__":
    main()
