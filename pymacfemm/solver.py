"""Subprocess driver for triangle + the four headless solvers.

FEMM's runtime flow:
  1. Write .fem/.fee/.feh/.fec
  2. Write .poly + .pbc (done by pymacfemm.geometry.write_poly)
  3. Call triangle  → produces .node .ele .edge .poly .pbc (clobbered)
  4. Call solver    → produces .ans (magnetics/heat) or .res (bela/csolv)

Binaries are located via (in order):
  * $FEMM_BIN if set — expected to contain the five executables.
  * Walking up from this file looking for a ``build/`` directory that
    matches the layout produced by ``build_macos.sh``.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


_BUILD_LAYOUT = {
    "triangle": "triangle/triangle",
    "belasolve": "belasolv/belasolve",
    "csolve": "csolv/csolve",
    "hsolve": "hsolv/hsolve",
    "fknsolve": "fkn/fknsolve",
}


def _search_build_roots(start: Path) -> list[Path]:
    roots: list[Path] = []
    env = os.environ.get("FEMM_BIN")
    if env:
        roots.append(Path(env))
    p = start.resolve()
    for parent in [p, *p.parents]:
        cand = parent / "build"
        if cand.is_dir():
            roots.append(cand)
    return roots


def find_binary(name: str) -> Path:
    """Return the absolute path to a named solver binary.

    ``name`` is one of: triangle, belasolve, csolve, hsolve, fknsolve.
    Raises FileNotFoundError if no build directory contains it.
    """
    if name not in _BUILD_LAYOUT:
        raise ValueError(f"unknown binary {name!r}; expected one of {list(_BUILD_LAYOUT)}")

    for root in _search_build_roots(Path(__file__)):
        # FEMM_BIN can either be the flat dir (holds all 5 executables) or
        # the layout build_macos.sh produces.
        flat = root / name
        if flat.is_file() and os.access(flat, os.X_OK):
            return flat
        nested = root / _BUILD_LAYOUT[name]
        if nested.is_file() and os.access(nested, os.X_OK):
            return nested

    raise FileNotFoundError(
        f"{name} not found; run ./build_macos.sh or set FEMM_BIN to the build dir"
    )


def run_triangle(
    problem_file: Path,
    min_angle: float = 30.0,
    enforce_segments: bool = True,
) -> None:
    """Mesh the .poly file written alongside ``problem_file``.

    Equivalent to FEMM's ``triangle.exe -p -P -j -q<min> -e -A -a -z -Q -I``
    command. ``enforce_segments`` corresponds to the -Y flag (don't insert
    Steiner points on segments); only FunnyOnWritePoly uses -Y in FEMM.
    """
    root = problem_file.with_suffix("")
    triangle = find_binary("triangle")
    q = min(min_angle + 3.0, 33.8)
    flags = ["-p", "-P", "-j", f"-q{q:.6f}", "-e", "-A", "-a", "-z", "-Q", "-I"]
    cmd = [str(triangle), *flags, str(root)]
    subprocess.run(cmd, check=True)


def run_solver(problem_file: Path, solver_name: str) -> Path:
    """Invoke a solver binary on ``problem_file`` (extension stripped).

    Returns the path the solver writes its output to (``<root>.ans`` for
    magnetics/heat, ``<root>.res`` for electrostatics/current).
    """
    solver = find_binary(solver_name)
    root = problem_file.with_suffix("")
    subprocess.run([str(solver), str(root)], check=True)

    ext = {
        "fknsolve": ".ans",
        "hsolve":   ".anh",
        "belasolve": ".res",
        "csolve":    ".anc",
    }[solver_name]
    return root.with_suffix(ext)
