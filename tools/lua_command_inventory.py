#!/usr/bin/env python3
"""Extract Windows FEMM lua_register command names and compare macFEMM.

Usage:
  tools/lua_command_inventory.py
  tools/lua_command_inventory.py --check build/libfemm_core/femm_cli_lua
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS_DIR = ROOT / "femm"
EXPECTED = ROOT / "tests" / "lua_expected_commands.txt"
REGISTER_RE = re.compile(r'lua_register\([^,]+,\s*"([^"]+)"')


def windows_commands() -> list[str]:
    names: set[str] = set()
    for path in WINDOWS_DIR.rglob("*"):
        if path.suffix.lower() not in {".cpp", ".c"}:
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        names.update(REGISTER_RE.findall(text))
    return sorted(names)


def mac_commands(binary: pathlib.Path) -> list[str]:
    out = subprocess.check_output([str(binary), "--list"], text=True)
    return sorted(line.strip() for line in out.splitlines() if line.strip())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", type=pathlib.Path, help="macFEMM femm_cli_lua binary")
    parser.add_argument("--write-expected", action="store_true")
    args = parser.parse_args()

    win = windows_commands()
    if args.write_expected:
        EXPECTED.write_text("\n".join(win) + "\n")
        return 0

    expected = [line.strip() for line in EXPECTED.read_text().splitlines() if line.strip()]
    if win != expected:
        print("tests/lua_expected_commands.txt is stale; run with --write-expected", file=sys.stderr)
        return 1

    if args.check:
        mac = set(mac_commands(args.check))
        missing = [name for name in expected if name not in mac]
        if missing:
            print("missing macFEMM Lua commands:", file=sys.stderr)
            for name in missing:
                print(name, file=sys.stderr)
            return 1

    for name in expected:
        print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
