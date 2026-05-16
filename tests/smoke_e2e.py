"""End-to-end smoke test for all four physics.

Each problem has a closed-form solution; we compare the solver output
against it and emit a .png visualisation so the results can be eyeballed.

Problems:
  1. Electrostatics: parallel-plate capacitor (V varies linearly from 0 to V0).
  2. Heat: slab with fixed T on both edges (T varies linearly).
  3. Current flow: resistive bar with V0 / 0 end-caps (same shape as #1).
  4. Magnetics: solenoid-like air region surrounded by fixed-A boundary; we
     simply check that B is finite and the peak occurs inside the coil.
"""

from __future__ import annotations

import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "out"
OUT.mkdir(exist_ok=True)

sys.path.insert(0, str(ROOT.parent))

from pymacfemm import (
    ElectrostaticsProblem,
    HeatProblem,
    CurrentProblem,
    MagneticsProblem,
    read_electrostatics,
    read_heat,
    read_current,
    read_magnetics,
)
from pymacfemm import plot as pplot


def _rect_outline(problem, x0, y0, x1, y1, *, bdry_names):
    """Add four corner nodes + four segments for a rectangle.

    bdry_names = (bottom, right, top, left). Use None for no marker.
    """
    n0 = problem.add_node(x0, y0)
    n1 = problem.add_node(x1, y0)
    n2 = problem.add_node(x1, y1)
    n3 = problem.add_node(x0, y1)
    for a, b, name in zip((n0, n1, n2, n3), (n1, n2, n3, n0), bdry_names):
        kw = {"boundary_marker": name} if name else {}
        problem.add_segment(a, b, **kw)
    return n0, n1, n2, n3


# ----------------------------------------------------------------------
def test_electrostatics() -> bool:
    print("=== electrostatics: parallel-plate capacitor ===")
    p = ElectrostaticsProblem()
    p.ei_probdef(units="millimeters", problem_type="planar", depth=1.0, min_angle=30)
    p.ei_add_material("air", ex=1.0, ey=1.0)
    p.ei_add_bdry_prop("V_high", V=100.0, bdry_format=0)
    p.ei_add_bdry_prop("V_low", V=0.0, bdry_format=0)
    # 10 mm wide, 5 mm tall. Bottom = V_low (y=0), Top = V_high (y=5).
    _rect_outline(p, 0, 0, 10, 5,
                  bdry_names=("V_low", None, "V_high", None))
    p.add_block_label(5, 2.5, block_type="air", max_area=0.25)

    res_path = p.ei_analyze(OUT / "cap")
    r = read_electrostatics(res_path)
    V = r["V"]
    y = r["nodes"][:, 1]
    V_expected = 100.0 * y / 5.0
    err = np.max(np.abs(V - V_expected)) / 100.0
    print(f"  nodes={len(V)}  max|ΔV|/V0 = {err:.2e}")

    fig, axes = plt.subplots(1, 2, figsize=(10, 4))
    pplot.plot_potential(r, ax=axes[0], levels=20)
    axes[0].set_title("V [V]")
    pplot.plot_E_field(r, ax=axes[1])
    axes[1].set_title("E field")
    fig.tight_layout()
    fig.savefig(OUT / "cap.png", dpi=100)
    plt.close(fig)

    return err < 1e-3


# ----------------------------------------------------------------------
def test_heat() -> bool:
    print("=== heat: slab T(0)=300, T(L)=400 ===")
    p = HeatProblem()
    p.hi_probdef(units="millimeters", problem_type="planar", depth=1.0, min_angle=30)
    p.hi_add_material("iron", Kx=50.0, Ky=50.0)
    p.hi_add_bdry_prop("T_low", bdry_format=0, Tset=300.0)
    p.hi_add_bdry_prop("T_high", bdry_format=0, Tset=400.0)
    _rect_outline(p, 0, 0, 10, 4,
                  bdry_names=("T_low", None, "T_high", None))
    p.add_block_label(5, 2, block_type="iron", max_area=0.25)

    anh_path = p.hi_analyze(OUT / "slab")
    r = read_heat(anh_path)
    T = r["T"]
    y = r["nodes"][:, 1]
    T_expected = 300.0 + 100.0 * y / 4.0
    err = np.max(np.abs(T - T_expected)) / 100.0
    print(f"  nodes={len(T)}  max|ΔT|/ΔT_bc = {err:.2e}")

    fig, ax = plt.subplots(figsize=(6, 4))
    pplot.plot_potential(r, ax=ax, levels=20)
    ax.set_title("T [°C]")
    fig.tight_layout()
    fig.savefig(OUT / "slab.png", dpi=100)
    plt.close(fig)

    return err < 1e-3


# ----------------------------------------------------------------------
def test_current() -> bool:
    print("=== current: resistive bar, DC ===")
    p = CurrentProblem()
    p.ci_probdef(units="millimeters", problem_type="planar",
                 frequency=0.0, depth=1.0, min_angle=30)
    p.ci_add_material("copper", ox=5.8e7, oy=5.8e7, ex=1.0, ey=1.0)
    p.ci_add_bdry_prop("V_high", bdry_format=0, Vs=10.0 + 0j)
    p.ci_add_bdry_prop("V_low", bdry_format=0, Vs=0.0 + 0j)
    _rect_outline(p, 0, 0, 20, 5,
                  bdry_names=(None, "V_high", None, "V_low"))
    p.add_block_label(10, 2.5, block_type="copper", max_area=1.0)

    res_path = p.ci_analyze(OUT / "bar")
    r = read_current(res_path)
    V = r["V"].real
    x = r["nodes"][:, 0]
    V_expected = 10.0 * x / 20.0
    err = np.max(np.abs(V - V_expected)) / 10.0
    print(f"  nodes={len(V)}  max|ΔV|/V0 = {err:.2e}")

    fig, ax = plt.subplots(figsize=(8, 3))
    pplot.plot_potential(r, ax=ax, levels=20)
    ax.set_title("V [V]  — resistive bar")
    fig.tight_layout()
    fig.savefig(OUT / "bar.png", dpi=100)
    plt.close(fig)

    return err < 1e-3


# ----------------------------------------------------------------------
def test_magnetics() -> bool:
    print("=== magnetics: long solenoid in 2D planar (strip of current) ===")
    p = MagneticsProblem()
    p.mi_probdef(frequency=0.0, units="millimeters", problem_type="planar",
                 depth=1.0, min_angle=30)
    # Uniform current density strip of width 2a, surrounded by air; outer
    # box held at A=0. For a strip at |x|<a the B field between infinite
    # parallel planes would be ±mu0*J*a, but we'll just sanity-check that
    # peak B sits inside the strip.
    p.mi_add_material("air", mu_x=1.0, mu_y=1.0)
    p.mi_add_material("coil", mu_x=1.0, mu_y=1.0, Jsrc=1.0 + 0j)  # 1 MA/m^2
    p.mi_add_bdry_prop("A0", bdry_format=0, A0=0.0)
    # Outer box 40 x 40, coil strip 4 x 20 at center.
    _rect_outline(p, -20, -20, 20, 20,
                  bdry_names=("A0", "A0", "A0", "A0"))
    # Inner strip: -2 <= x <= 2, -10 <= y <= 10.
    ci0 = p.add_node(-2, -10)
    ci1 = p.add_node(2, -10)
    ci2 = p.add_node(2, 10)
    ci3 = p.add_node(-2, 10)
    for a, b in ((ci0, ci1), (ci1, ci2), (ci2, ci3), (ci3, ci0)):
        p.add_segment(a, b)
    # Two labels: one inside the coil, one in the surrounding air.
    p.add_block_label(0, 0, block_type="coil", max_area=0.5)
    p.add_block_label(10, 10, block_type="air", max_area=5.0)

    ans_path = p.mi_analyze(OUT / "coil")
    r = read_magnetics(ans_path)
    A = r["A"]
    Bx, By = pplot.magnetics_B(r)
    Bmag = np.hypot(Bx, By)
    # Sanity: the centroids with the largest |B| should lie near the strip
    # boundary (x = ±2), not in the outer corners.
    cents = r["nodes"][r["elements"]].mean(axis=1)
    idx = int(np.argmax(Bmag))
    cx, cy = cents[idx]
    ok_location = abs(abs(cx) - 2.0) < 3.0 and abs(cy) < 12.0
    print(f"  nodes={len(A)}  max|B|={Bmag.max():.3e}  at ({cx:.2f},{cy:.2f})  ok_loc={ok_location}")

    fig, axes = plt.subplots(1, 2, figsize=(11, 5))
    pplot.plot_flux_lines(r, ax=axes[0], levels=25)
    axes[0].set_title("Flux lines (contours of A)")
    pplot.plot_B_density(r, ax=axes[1])
    axes[1].set_title("|B|")
    fig.tight_layout()
    fig.savefig(OUT / "coil.png", dpi=100)
    plt.close(fig)

    return bool(np.isfinite(Bmag.max())) and Bmag.max() > 0 and ok_location


# ----------------------------------------------------------------------
if __name__ == "__main__":
    results = {
        "electrostatics": test_electrostatics(),
        "heat":           test_heat(),
        "current":        test_current(),
        "magnetics":      test_magnetics(),
    }
    print()
    print("Results:")
    for k, v in results.items():
        print(f"  {k:15s}  {'PASS' if v else 'FAIL'}")
    sys.exit(0 if all(results.values()) else 1)
