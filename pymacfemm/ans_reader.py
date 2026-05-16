"""Parse the solver output files (.res / .ans / .anh) into NumPy arrays.

Each solver's WriteResults/WriteStatic2D/... function echoes the input file
followed by a `[Solution]` section. We skip to `[Solution]`, then parse the
fixed format defined there.

Formats (from `<solver>/*big.cpp`):

belasolve (.res):   NumNodes  rows: x y V Q
                    NumEls    rows: p0 p1 p2 lbl
                    NumCirc   rows: V q

csolve (.res):      NumNodes  rows: x y V.re V.im Q
                    NumEls    rows: p0 p1 p2 lbl
                    NumCirc   rows: V.re V.im q.re q.im

hsolve (.anh):      same as belasolve (scalar V is the temperature T)

fknsolve (.ans)     static 2D: x y A bc [Aprev]
                    harmonic 2D: x y A.re A.im bc [Aprev]
                    elements have extra columns and possibly Jprev.

We return a `dict[str, Any]` keyed the same way across all four readers
so the post-processor can pick the fields it needs.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np


def _skip_to_solution(fp) -> None:
    for line in fp:
        if line.strip().lower().startswith("[solution]"):
            return
    raise ValueError("no [Solution] section found")


def _read_int(fp) -> int:
    return int(fp.readline().strip().split()[0])


def read_electrostatics(path: Path) -> dict:
    """belasolve .res: node rows = x y V Q"""
    with open(path) as fp:
        _skip_to_solution(fp)
        n = _read_int(fp)
        nodes = np.empty((n, 2))
        V = np.empty(n)
        Q = np.empty(n, dtype=int)
        for i in range(n):
            parts = fp.readline().split()
            nodes[i] = (float(parts[0]), float(parts[1]))
            V[i] = float(parts[2])
            Q[i] = int(parts[3])

        m = _read_int(fp)
        elements = np.empty((m, 3), dtype=int)
        labels = np.empty(m, dtype=int)
        for i in range(m):
            parts = fp.readline().split()
            elements[i] = (int(parts[0]), int(parts[1]), int(parts[2]))
            labels[i] = int(parts[3])

        nc = _read_int(fp)
        circ_V = np.empty(nc)
        circ_q = np.empty(nc)
        for i in range(nc):
            parts = fp.readline().split()
            circ_V[i] = float(parts[0])
            circ_q[i] = float(parts[1])

    return {
        "nodes": nodes, "elements": elements, "labels": labels,
        "V": V, "Q": Q,
        "circuit_V": circ_V, "circuit_q": circ_q,
    }


def read_heat(path: Path) -> dict:
    """hsolve output (same shape as belasolve, but the scalar field is T)."""
    r = read_electrostatics(path)
    r["T"] = r.pop("V")
    r["circuit_T"] = r.pop("circuit_V")
    return r


def read_current(path: Path) -> dict:
    """csolve .res: node rows = x y V.re V.im Q; circuit rows = Vre Vim qre qim."""
    with open(path) as fp:
        _skip_to_solution(fp)
        n = _read_int(fp)
        nodes = np.empty((n, 2))
        V = np.empty(n, dtype=complex)
        Q = np.empty(n, dtype=int)
        for i in range(n):
            parts = fp.readline().split()
            nodes[i] = (float(parts[0]), float(parts[1]))
            V[i] = complex(float(parts[2]), float(parts[3]))
            Q[i] = int(parts[4])

        m = _read_int(fp)
        elements = np.empty((m, 3), dtype=int)
        labels = np.empty(m, dtype=int)
        for i in range(m):
            parts = fp.readline().split()
            elements[i] = (int(parts[0]), int(parts[1]), int(parts[2]))
            labels[i] = int(parts[3])

        nc = _read_int(fp)
        circ_V = np.empty(nc, dtype=complex)
        circ_q = np.empty(nc, dtype=complex)
        for i in range(nc):
            parts = fp.readline().split()
            circ_V[i] = complex(float(parts[0]), float(parts[1]))
            circ_q[i] = complex(float(parts[2]), float(parts[3]))

    return {
        "nodes": nodes, "elements": elements, "labels": labels,
        "V": V, "Q": Q,
        "circuit_V": circ_V, "circuit_q": circ_q,
    }


def read_magnetics(path: Path) -> dict:
    """fknsolve .ans: solution block, shape depends on frequency.

    Static 2D:    x  y  A  bc  [Aprev?]
    Harmonic 2D:  x  y  A.re  A.im  bc  [Aprev?]

    We peek at the [Frequency] key earlier in the echoed .fem to decide.
    """
    frequency = 0.0
    with open(path) as fp:
        for line in fp:
            stripped = line.strip()
            if stripped.lower().startswith("[frequency]"):
                try:
                    frequency = float(stripped.split("=", 1)[1])
                except (ValueError, IndexError):
                    pass
            if stripped.lower().startswith("[solution]"):
                break
        else:
            raise ValueError("no [Solution] section found")

        n = _read_int(fp)
        nodes = np.empty((n, 2))
        if frequency == 0.0:
            A = np.empty(n)
        else:
            A = np.empty(n, dtype=complex)
        bc = np.empty(n, dtype=int)
        Aprev = np.full(n, np.nan)

        for i in range(n):
            parts = fp.readline().split()
            nodes[i] = (float(parts[0]), float(parts[1]))
            if frequency == 0.0:
                A[i] = float(parts[2])
                bc[i] = int(parts[3])
                if len(parts) > 4:
                    Aprev[i] = float(parts[4])
            else:
                A[i] = complex(float(parts[2]), float(parts[3]))
                bc[i] = int(parts[4])
                if len(parts) > 5:
                    Aprev[i] = float(parts[5])

        m = _read_int(fp)
        elements = np.empty((m, 3), dtype=int)
        labels = np.empty(m, dtype=int)
        for i in range(m):
            parts = fp.readline().split()
            elements[i] = (int(parts[0]), int(parts[1]), int(parts[2]))
            labels[i] = int(parts[3])
            # remaining columns (e[0]/e[1]/e[2] and possibly Jprev) ignored

    result = {
        "nodes": nodes, "elements": elements, "labels": labels,
        "A": A, "bc": bc, "frequency": frequency,
    }
    if np.any(~np.isnan(Aprev)):
        result["Aprev"] = Aprev
    return result
