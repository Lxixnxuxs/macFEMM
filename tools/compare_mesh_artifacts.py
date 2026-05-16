#!/usr/bin/env python3
"""Compare FEMM/Triangle mesh artifacts from Windows and macOS runs.

Usage:
    python3 tools/compare_mesh_artifacts.py \
        /Users/.../Documents/WindowsVM/mesh_after_analyze \
        /private/tmp/femm_mesh_restore_check

The Windows Lua probe writes mesh_after_createmesh/ and mesh_after_analyze/.
The macOS side can be any directory containing tutorial.poly/.node/.ele/.edge.
"""

from __future__ import annotations

import argparse
import hashlib
import math
from collections import Counter
from pathlib import Path


NAMES = ("tutorial.poly", "tutorial.node", "tutorial.ele", "tutorial.edge")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def artifact(base: Path, name: str) -> Path:
    """Return artifact path from either a directory or a flat filename prefix."""
    if base.is_dir():
        return base / name
    return base.with_suffix(Path(name).suffix)


def tokens(path: Path) -> list[str]:
    return path.read_text(errors="replace").split()


def as_float(s: str) -> float | None:
    try:
        return float(s)
    except ValueError:
        return None


def token_equal(a: str, b: str, atol: float) -> bool:
    if a == b:
        return True
    fa = as_float(a)
    fb = as_float(b)
    if fa is None or fb is None:
        return False
    return math.isfinite(fa) and math.isfinite(fb) and abs(fa - fb) <= atol


def compare_tokens(a_path: Path, b_path: Path, atol: float) -> tuple[bool, str]:
    a = tokens(a_path)
    b = tokens(b_path)
    if len(a) != len(b):
        return False, f"token_count {len(a)} != {len(b)}"
    for i, (ta, tb) in enumerate(zip(a, b)):
        if not token_equal(ta, tb, atol):
            return False, f"first_token_diff[{i}] {ta!r} != {tb!r}"
    return True, "tokens match"


def first_ints(path: Path, n: int) -> tuple[int, ...] | None:
    parts = tokens(path)
    if len(parts) < n:
        return None
    try:
        return tuple(int(parts[i]) for i in range(n))
    except ValueError:
        return None


def ele_label_counts(path: Path) -> Counter[int]:
    out: Counter[int] = Counter()
    lines = path.read_text(errors="replace").splitlines()
    if not lines:
        return out
    for line in lines[1:]:
        if line.lstrip().startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 5:
            try:
                out[int(parts[4])] += 1
            except ValueError:
                continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("windows_dir", type=Path)
    ap.add_argument("mac_dir", type=Path)
    ap.add_argument("--atol", type=float, default=1e-12)
    args = ap.parse_args()

    win = args.windows_dir
    mac = args.mac_dir

    print(f"windows_dir {win}")
    print(f"mac_dir     {mac}")
    print(f"numeric_atol {args.atol:g}")

    for name in NAMES:
        wp = artifact(win, name)
        mp = artifact(mac, name)
        print(f"\n[{name}]")
        if not wp.exists() or not mp.exists():
            print(f"missing windows={wp.exists()} mac={mp.exists()}")
            continue
        print(f"sha256 windows={sha256(wp)} mac={sha256(mp)}")
        ok, detail = compare_tokens(wp, mp, args.atol)
        print(f"normalized_match {ok} ({detail})")
        if name == "tutorial.node":
            print(f"header windows={first_ints(wp, 4)} mac={first_ints(mp, 4)}")
        elif name == "tutorial.ele":
            print(f"header windows={first_ints(wp, 3)} mac={first_ints(mp, 3)}")
            wc = ele_label_counts(wp)
            mc = ele_label_counts(mp)
            print(f"label_counts windows={dict(sorted(wc.items()))}")
            print(f"label_counts mac    ={dict(sorted(mc.items()))}")
            keys = sorted(set(wc) | set(mc))
            print(f"label_delta mac-minus-windows={{{', '.join(f'{k}: {mc[k] - wc[k]}' for k in keys)}}}")
        elif name == "tutorial.poly":
            print(f"header windows={first_ints(wp, 4)} mac={first_ints(mp, 4)}")
        elif name == "tutorial.edge":
            print(f"header windows={first_ints(wp, 2)} mac={first_ints(mp, 2)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
