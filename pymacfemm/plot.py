"""Matplotlib post-processing for the four physics.

Partial replacement for ``femmplot``. Everything is driven off the
``dict`` returned by ``ans_reader`` — a bag of NumPy arrays keyed by
``nodes``, ``elements``, and one or more field arrays.

Derived fields (per element, linear-triangle FEM):
  * Magnetics 2D planar:    B = (dAz/dy, -dAz/dx)
  * Magnetics axisymmetric: Bphi = 0; Br = -(1/r) d(rA)/dz;  Bz = (1/r) d(rA)/dr
  * Electrostatics:          E = -grad V
  * Heat:                    q = -k grad T (k handled by caller if needed)
  * Current flow:            J = -sigma grad V (sigma handled by caller)
"""

from __future__ import annotations

from typing import Any

import numpy as np


def _tri_gradients(nodes: np.ndarray, elements: np.ndarray, field: np.ndarray):
    """Per-element gradient of a scalar (or complex scalar) field.

    Returns (grad_x, grad_y), each shape (M,). For a linear triangle with
    vertices p0, p1, p2 and nodal values f0, f1, f2 the gradient is
    constant over the element and equals (1/2A) * [ (y12 y20 y01) · f,
                                                    (x21 x02 x10) · f ].
    """
    p = nodes[elements]  # (M, 3, 2)
    x = p[..., 0]
    y = p[..., 1]
    f = field[elements]  # (M, 3)
    twoA = (x[:, 1] - x[:, 0]) * (y[:, 2] - y[:, 0]) - (x[:, 2] - x[:, 0]) * (y[:, 1] - y[:, 0])
    dfdx = ((y[:, 1] - y[:, 2]) * f[:, 0] + (y[:, 2] - y[:, 0]) * f[:, 1] + (y[:, 0] - y[:, 1]) * f[:, 2]) / twoA
    dfdy = ((x[:, 2] - x[:, 1]) * f[:, 0] + (x[:, 0] - x[:, 2]) * f[:, 1] + (x[:, 1] - x[:, 0]) * f[:, 2]) / twoA
    return dfdx, dfdy


def _element_centroids(nodes: np.ndarray, elements: np.ndarray) -> np.ndarray:
    return nodes[elements].mean(axis=1)


def _triangulation(result: dict):
    import matplotlib.tri as mtri
    nodes = result["nodes"]
    return mtri.Triangulation(nodes[:, 0], nodes[:, 1], triangles=result["elements"])


# ----------------------------------------------------------------------
# Magnetics
# ----------------------------------------------------------------------
def magnetics_B(result: dict) -> tuple[np.ndarray, np.ndarray]:
    """Return per-element (Bx, By) from the vector potential A.

    For harmonic problems A is complex — Bx/By come back complex too and
    the caller typically takes ``np.abs`` for a snapshot of |B| amplitude.
    """
    A = result["A"]
    dAdx, dAdy = _tri_gradients(result["nodes"], result["elements"], A)
    return dAdy, -dAdx


def plot_flux_lines(result: dict, ax=None, levels: int = 20, **kw):
    """Draw contours of ``A`` — in planar 2D these are magnetic flux lines."""
    import matplotlib.pyplot as plt
    if ax is None:
        _, ax = plt.subplots()
    A = result["A"]
    if np.iscomplexobj(A):
        A = A.real
    tri = _triangulation(result)
    cs = ax.tricontour(tri, A, levels=levels, **kw)
    ax.set_aspect("equal")
    return cs


def plot_B_density(result: dict, ax=None, **kw):
    """Filled contour of |B| over the mesh (per-element, shown at centroids)."""
    import matplotlib.pyplot as plt
    if ax is None:
        _, ax = plt.subplots()
    Bx, By = magnetics_B(result)
    Bmag = np.abs(np.hypot(Bx, By))
    tri = _triangulation(result)
    tpc = ax.tripcolor(tri, facecolors=Bmag, **kw)
    ax.set_aspect("equal")
    return tpc


# ----------------------------------------------------------------------
# Electrostatics / current flow — same math (Laplacian of V)
# ----------------------------------------------------------------------
def _grad_V(result: dict):
    V = result["V"]
    return _tri_gradients(result["nodes"], result["elements"], V)


def electrostatic_E(result: dict) -> tuple[np.ndarray, np.ndarray]:
    """E = -grad V — per-element."""
    dVdx, dVdy = _grad_V(result)
    return -dVdx, -dVdy


def plot_potential(result: dict, ax=None, levels: int = 25, filled: bool = True, **kw):
    """Scalar-field contour for V or T. Picks the right key automatically."""
    import matplotlib.pyplot as plt
    if ax is None:
        _, ax = plt.subplots()
    tri = _triangulation(result)
    for key in ("V", "T"):
        if key in result:
            f = result[key]
            break
    else:
        raise KeyError("result has neither V nor T to plot")
    if np.iscomplexobj(f):
        f = f.real
    if filled:
        cs = ax.tricontourf(tri, f, levels=levels, **kw)
    else:
        cs = ax.tricontour(tri, f, levels=levels, **kw)
    ax.set_aspect("equal")
    return cs


def plot_E_field(result: dict, ax=None, scale: float | None = None, **kw):
    """Quiver plot of E at element centroids."""
    import matplotlib.pyplot as plt
    if ax is None:
        _, ax = plt.subplots()
    Ex, Ey = electrostatic_E(result)
    if np.iscomplexobj(Ex):
        Ex, Ey = Ex.real, Ey.real
    cents = _element_centroids(result["nodes"], result["elements"])
    q = ax.quiver(cents[:, 0], cents[:, 1], Ex, Ey, scale=scale, **kw)
    ax.set_aspect("equal")
    return q


# ----------------------------------------------------------------------
# Heat
# ----------------------------------------------------------------------
def heat_flux(result: dict, k: float = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """q = -k grad T. Caller supplies an isotropic k (W/m/K)."""
    T = result["T"]
    dTdx, dTdy = _tri_gradients(result["nodes"], result["elements"], T)
    return -k * dTdx, -k * dTdy


# ----------------------------------------------------------------------
# Current flow
# ----------------------------------------------------------------------
def current_density(result: dict, sigma: complex = 1.0) -> tuple[np.ndarray, np.ndarray]:
    """J = -sigma grad V. sigma may be complex (AC)."""
    dVdx, dVdy = _grad_V(result)
    return -sigma * dVdx, -sigma * dVdy


def plot_mesh(result: dict, ax=None, **kw):
    """Draw the triangulation itself — mostly a sanity check."""
    import matplotlib.pyplot as plt
    if ax is None:
        _, ax = plt.subplots()
    tri = _triangulation(result)
    ax.triplot(tri, **kw)
    ax.set_aspect("equal")
    return ax
