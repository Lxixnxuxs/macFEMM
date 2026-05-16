#!/usr/bin/env python3
"""Diff two regression reports produced by the headless macOS harness and the
Windows FEMM Lua probe. Reports live next to each other in the shared dir.

Each file is a plain-text `<key> <value>` per line; lines beginning with `#`
are ignored. Missing keys on either side are flagged (non-fatal — useful when
one side has intentionally wider coverage, e.g. reference-only probes).

Exit code: 0 if all present-on-both keys pass the tolerance, 1 otherwise.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path


def parse(path: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # key may contain slashes, commas, letters — always split on last whitespace
        parts = line.rsplit(None, 1)
        if len(parts) != 2:
            continue
        k, v = parts
        try:
            out[k] = float(v)
        except ValueError:
            continue
    return out


def compare(mac: dict[str, float], win: dict[str, float],
            rel_tol: float, abs_tol: float) -> tuple[int, int]:
    keys = sorted(set(mac) | set(win))
    both = 0
    fails = 0

    name_w = max((len(k) for k in keys), default=20)
    for k in keys:
        if k in mac and k in win:
            both += 1
            a, b = mac[k], win[k]
            diff = a - b
            # Symmetric tolerance: |a - b| ≤ abs_tol + rel_tol·max(|a|,|b|)
            scale = max(abs(a), abs(b))
            tol = abs_tol + rel_tol * scale
            ok = abs(diff) <= tol
            tag = "ok " if ok else "FAIL"
            reldisp = (abs(diff) / scale) if scale > 0 else 0.0
            print(f"[{tag}] {k:<{name_w}} mac={a:+.6g}  win={b:+.6g}  "
                  f"Δ={diff:+.3g}  rel={reldisp:.2e}")
            if not ok:
                fails += 1
        elif k in mac:
            print(f"[mac-only ] {k:<{name_w}} mac={mac[k]:+.6g}")
        else:
            print(f"[win-only ] {k:<{name_w}} win={win[k]:+.6g}")
    print(f"\n{both} keys compared, {fails} failed "
          f"(rel_tol={rel_tol}, abs_tol={abs_tol}).")
    return both, fails


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("mac", type=Path, help="macOS report (femm_cli_regression)")
    p.add_argument("win", type=Path, help="Windows report (regression_probe.lua)")
    p.add_argument("--rel", type=float, default=1e-3,
                   help="relative tolerance (default 1e-3)")
    p.add_argument("--abs", type=float, dest="abs_", default=1e-12,
                   help="absolute tolerance for values near zero (default 1e-12)")
    args = p.parse_args()

    mac = parse(args.mac)
    win = parse(args.win)
    _, fails = compare(mac, win, args.rel, args.abs_)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
