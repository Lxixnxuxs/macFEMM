"""Shared geometry primitives + base Problem class.

All four physics (magnetics, electrostatics, heat, current) share the same
geometric model: nodes, line segments, arc segments, block labels, and a
handful of property lists (point/bdry/block/conductor). The physics-specific
pieces are the property classes themselves and the file extension
(.fem/.fee/.feh/.fec).

This module keeps the geometry wrangling in one place and leaves the
physics subclasses to override the short set of emit_* hooks.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


@dataclass
class Node:
    x: float
    y: float
    boundary_marker: str = ""
    in_group: int = 0
    in_conductor: str = ""


@dataclass
class Segment:
    n0: int
    n1: int
    boundary_marker: str = ""
    max_side_length: float = -1.0
    hidden: int = 0
    in_group: int = 0
    in_conductor: str = ""


@dataclass
class ArcSegment:
    n0: int
    n1: int
    arc_length_deg: float
    max_side_length_deg: float = 1.0
    boundary_marker: str = ""
    hidden: int = 0
    in_group: int = 0
    in_conductor: str = ""


@dataclass
class BlockLabel:
    x: float
    y: float
    block_type: str = ""
    max_area: float = -1.0
    in_circuit: str = ""
    mag_dir: float = 0.0
    in_group: int = 0
    turns: int = 1
    is_external: int = 0
    is_default: int = 0
    mag_dir_fctn: str = ""


# Length units recognized by FEMM's OnOpenDocument parsers.
LENGTH_UNITS = {
    "inches": 0,
    "millimeters": 1,
    "centimeters": 2,
    "meters": 3,
    "mils": 4,
    "microns": 5,
}


def _linelength(n0: Node, n1: Node) -> float:
    return math.hypot(n1.x - n0.x, n1.y - n0.y)


def _arc_circle(n0: Node, n1: Node, arc_deg: float) -> tuple[float, float, float]:
    """Return (cx, cy, radius) for the arc from n0 to n1 sweeping arc_deg.

    Mirrors femm/bd_writepoly.cpp::GetCircle. The arc is traversed
    counterclockwise from n0 to n1 and covers `arc_deg` degrees.
    """
    dx, dy = n1.x - n0.x, n1.y - n0.y
    chord = math.hypot(dx, dy)
    if chord == 0:
        raise ValueError("Arc endpoints coincide")
    half = math.radians(arc_deg) / 2.0
    r = chord / (2.0 * math.sin(half))
    # midpoint
    mx, my = (n0.x + n1.x) / 2.0, (n0.y + n1.y) / 2.0
    # perpendicular unit normal pointing "left" of n0->n1
    nx, ny = -dy / chord, dx / chord
    d = r * math.cos(half)
    return mx + nx * d, my + ny * d, r


class BaseProblem:
    """Common geometry + property lists shared by all four physics.

    Subclasses set:
      * ``_file_ext``       — ``.fem`` / ``.fee`` / ``.feh`` / ``.fec``
      * ``_solver_name``    — ``fknsolve`` / ``belasolve`` / ``hsolve`` / ``csolve``
      * ``_output_ext``     — ``.ans`` (magnetics/heat) or ``.res`` (bela/csolv)
      * ``_format_header``  — list of ``[Key] = value`` lines before the
        point/bdry/block/conductor property sections.
      * ``_write_point_props(fp)``, ``_write_bdry_props(fp)``,
        ``_write_block_props(fp)``, ``_write_conductor_props(fp)``.
      * ``_write_label_row(fp, lbl)`` — per-block-label line (magnetics has
        extra columns for circuit/mag-dir/turns, electrostatics does not).
    """

    _file_ext: str
    _solver_name: str
    _output_ext: str = ".ans"

    def __init__(self) -> None:
        self.precision: float = 1.0e-8
        self.min_angle: float = 30.0
        self.smart_mesh: int = 1
        self.depth: float = 1.0  # mm; only meaningful for planar problems
        self.length_units: str = "millimeters"
        self.problem_type: str = "planar"  # or "axisymmetric"
        self.coordinates: str = "cartesian"  # or "polar"
        self.ext_ro: float = 0.0
        self.ext_ri: float = 0.0
        self.ext_zo: float = 0.0
        self.comment: str = ""

        self.nodes: list[Node] = []
        self.segments: list[Segment] = []
        self.arcs: list[ArcSegment] = []
        self.labels: list[BlockLabel] = []

        # property lists — populated by physics-specific add_* methods
        self.point_props: list = []
        self.bdry_props: list = []
        self.block_props: list = []
        self.conductor_props: list = []

    # ------------------------------------------------------------------
    # Geometry construction (shared surface — the mi_/ei_/hi_/ci_ calls)
    # ------------------------------------------------------------------
    def add_node(self, x: float, y: float) -> int:
        self.nodes.append(Node(x=x, y=y))
        return len(self.nodes) - 1

    def add_segment(self, n0: int, n1: int, **kw) -> int:
        self.segments.append(Segment(n0=n0, n1=n1, **kw))
        return len(self.segments) - 1

    def add_arc(self, n0: int, n1: int, arc_deg: float, max_side_deg: float = 1.0, **kw) -> int:
        self.arcs.append(
            ArcSegment(n0=n0, n1=n1, arc_length_deg=arc_deg, max_side_length_deg=max_side_deg, **kw)
        )
        return len(self.arcs) - 1

    def add_block_label(self, x: float, y: float, **kw) -> int:
        self.labels.append(BlockLabel(x=x, y=y, **kw))
        return len(self.labels) - 1

    # ------------------------------------------------------------------
    # File writing
    # ------------------------------------------------------------------
    def save(self, pathname: str | Path) -> Path:
        """Write the problem file at ``pathname`` (extension appended if missing)."""
        p = Path(pathname)
        if p.suffix.lower() != self._file_ext:
            p = p.with_suffix(self._file_ext)
        with open(p, "wt") as fp:
            self._write_header(fp)
            self._write_point_props(fp)
            self._write_bdry_props(fp)
            self._write_block_props(fp)
            self._write_conductor_props(fp)
            self._write_geometry(fp)
        return p

    # Shared header emission. Subclasses override _format_version and may add
    # extra keys (e.g. magnetics has [Frequency], [ACSolver], [PrevSoln]).
    def _write_header(self, fp) -> None:
        fp.write(f"[Format]      =  {self._format_version()}\n")
        self._write_extra_header(fp)
        fp.write(f"[Precision]   =  {self.precision:.17g}\n")
        fp.write(f"[MinAngle]    =  {self.min_angle:.17g}\n")
        fp.write(f"[DoSmartMesh] =  {self.smart_mesh}\n")
        fp.write(f"[Depth]       =  {self.depth:.17g}\n")
        fp.write(f"[LengthUnits] =  {self.length_units}\n")
        if self.problem_type == "planar":
            fp.write("[ProblemType] =  planar\n")
        else:
            fp.write("[ProblemType] =  axisymmetric\n")
            if self.ext_ro != 0.0 and self.ext_ri != 0.0:
                fp.write(f"[extZo] = {self.ext_zo:.17g}\n")
                fp.write(f"[extRo] = {self.ext_ro:.17g}\n")
                fp.write(f"[extRi] = {self.ext_ri:.17g}\n")
        fp.write(f"[Coordinates] =  {self.coordinates}\n")
        fp.write(f"[Comment]     =  \"{self.comment}\"\n")

    def _format_version(self) -> str:
        return "1"  # electrostatics/heat/current all use 1; magnetics overrides with 4.0

    def _write_extra_header(self, fp) -> None:
        """Override for magnetics (frequency, ACSolver, PrevSoln, etc.)."""

    # ------------------------------------------------------------------
    # Property emission hooks — subclasses must implement each.
    # ------------------------------------------------------------------
    def _write_point_props(self, fp) -> None:
        raise NotImplementedError

    def _write_bdry_props(self, fp) -> None:
        raise NotImplementedError

    def _write_block_props(self, fp) -> None:
        raise NotImplementedError

    def _write_conductor_props(self, fp) -> None:
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Geometry section — the [NumPoints]/[NumSegments]/[NumArcSegments]/
    # [NumHoles]/[NumBlockLabels] block, identical in shape across the
    # four physics except for the block-label row, which has extra columns
    # for magnetics. Physics that need extra columns override
    # ``_format_label_extra``.
    # ------------------------------------------------------------------
    def _lookup_point_idx(self, name: str) -> int:
        for j, p in enumerate(self.point_props):
            if getattr(p, "name", "") == name:
                return j + 1
        return 0

    def _lookup_bdry_idx(self, name: str) -> int:
        for j, p in enumerate(self.bdry_props):
            if getattr(p, "name", "") == name:
                return j + 1
        return 0

    def _lookup_block_idx(self, name: str) -> int:
        for j, p in enumerate(self.block_props):
            if getattr(p, "name", "") == name:
                return j + 1
        return 0

    def _lookup_conductor_idx(self, name: str) -> int:
        for j, p in enumerate(self.conductor_props):
            if getattr(p, "name", "") == name:
                return j + 1
        return 0

    def _write_geometry(self, fp) -> None:
        fp.write(f"[NumPoints] = {len(self.nodes)}\n")
        for n in self.nodes:
            t = self._lookup_point_idx(n.boundary_marker) if n.boundary_marker else 0
            c = self._lookup_conductor_idx(n.in_conductor) if n.in_conductor else 0
            fp.write(f"{n.x:.17g}\t{n.y:.17g}\t{t}\t{n.in_group}\t{c}\n")

        fp.write(f"[NumSegments] = {len(self.segments)}\n")
        for s in self.segments:
            t = self._lookup_bdry_idx(s.boundary_marker) if s.boundary_marker else 0
            c = self._lookup_conductor_idx(s.in_conductor) if s.in_conductor else 0
            msl = -1 if s.max_side_length < 0 else s.max_side_length
            if msl == -1:
                msl_s = "-1"
            else:
                msl_s = f"{msl:.17g}"
            fp.write(f"{s.n0}\t{s.n1}\t{msl_s}\t{t}\t{s.hidden}\t{s.in_group}\t{c}\n")

        fp.write(f"[NumArcSegments] = {len(self.arcs)}\n")
        for a in self.arcs:
            t = self._lookup_bdry_idx(a.boundary_marker) if a.boundary_marker else 0
            c = self._lookup_conductor_idx(a.in_conductor) if a.in_conductor else 0
            fp.write(
                f"{a.n0}\t{a.n1}\t{a.arc_length_deg:.17g}\t{a.max_side_length_deg:.17g}"
                f"\t{t}\t{a.hidden}\t{a.in_group}\t{c}\n"
            )

        # No <No Mesh> hole blocks in the Python API yet — just write 0.
        fp.write("[NumHoles] = 0\n")

        fp.write(f"[NumBlockLabels] = {len(self.labels)}\n")
        for lbl in self.labels:
            self._write_label_row(fp, lbl)

    def _write_label_row(self, fp, lbl: BlockLabel) -> None:
        """Default row format (used by belasolv/csolv/hsolv):

            x  y  blocktype  MaxArea  InGroup  IsExternal+IsDefault
        """
        t = self._lookup_block_idx(lbl.block_type) if lbl.block_type else 0
        ma = math.sqrt(4.0 * lbl.max_area / math.pi) if lbl.max_area > 0 else -1
        ma_s = "-1" if ma == -1 else f"{ma:.17g}"
        flags = lbl.is_external + 2 * lbl.is_default
        fp.write(f"{lbl.x:.17g}\t{lbl.y:.17g}\t{t}\t{ma_s}\t{lbl.in_group}\t{flags}\n")


# ----------------------------------------------------------------------
# .poly writer — invokes triangle. This is the pymacfemm equivalent of
# femm/*_writepoly.cpp::OnWritePoly.
# ----------------------------------------------------------------------
def write_poly(problem: BaseProblem, pathname: Path) -> Path:
    """Discretize segments + arcs into Triangle's .poly format.

    Returns the path to the .poly file (``<root>.poly``). Also writes a
    trivial ``.pbc`` file (zero periodic boundary conditions). Periodic BCs
    are a solver-side concern; the Python side punts on them for now.
    """
    root = pathname.with_suffix("")
    poly = root.with_suffix(".poly")
    pbc = root.with_suffix(".pbc")

    # Build the discretized node / segment lists.
    nodelst: list[Node] = [Node(x=n.x, y=n.y, boundary_marker=n.boundary_marker,
                                in_group=n.in_group, in_conductor=n.in_conductor)
                           for n in problem.nodes]
    linelst: list[Segment] = []

    # FEMM's SmartMesh writer adds two short subsegments around long segment
    # endpoints. Triangle then refines near corners in the same way as the
    # Windows GUI. Use a fresh Node for these Steiner points so point/conductor
    # markers do not leak from the original boundary nodes.
    line_fraction = 500.0
    if problem.segments:
        avg_len = sum(
            _linelength(problem.nodes[s.n0], problem.nodes[s.n1])
            for s in problem.segments
        ) / len(problem.segments)
        dL = avg_len / line_fraction
    else:
        dL = 0.0

    for seg in problem.segments:
        a0 = problem.nodes[seg.n0]
        a1 = problem.nodes[seg.n1]
        chord = _linelength(a0, a1)
        if seg.max_side_length <= 0 or chord == 0:
            k = 1
        else:
            k = max(1, math.ceil(chord / seg.max_side_length))
        if k == 1:
            if problem.smart_mesh and dL > 0 and chord >= 3.0 * dL:
                ux = (a1.x - a0.x) / chord
                uy = (a1.y - a0.y) / chord
                nodelst.append(Node(x=a0.x + dL * ux, y=a0.y + dL * uy))
                mid0 = len(nodelst) - 1
                nodelst.append(Node(x=a1.x - dL * ux, y=a1.y - dL * uy))
                mid1 = len(nodelst) - 1
                linelst.append(Segment(n0=seg.n0, n1=mid0,
                                       boundary_marker=seg.boundary_marker,
                                       in_conductor=seg.in_conductor))
                linelst.append(Segment(n0=mid0, n1=mid1,
                                       boundary_marker=seg.boundary_marker,
                                       in_conductor=seg.in_conductor))
                linelst.append(Segment(n0=mid1, n1=seg.n1,
                                       boundary_marker=seg.boundary_marker,
                                       in_conductor=seg.in_conductor))
            else:
                linelst.append(Segment(n0=seg.n0, n1=seg.n1,
                                       boundary_marker=seg.boundary_marker,
                                       in_conductor=seg.in_conductor))
        else:
            prev_idx = seg.n0
            for j in range(1, k):
                frac = j / k
                nx = a0.x + (a1.x - a0.x) * frac
                ny = a0.y + (a1.y - a0.y) * frac
                nodelst.append(Node(x=nx, y=ny,
                                    in_conductor=seg.in_conductor))
                this_idx = len(nodelst) - 1
                linelst.append(Segment(n0=prev_idx, n1=this_idx,
                                       boundary_marker=seg.boundary_marker,
                                       in_conductor=seg.in_conductor))
                prev_idx = this_idx
            linelst.append(Segment(n0=prev_idx, n1=seg.n1,
                                   boundary_marker=seg.boundary_marker,
                                   in_conductor=seg.in_conductor))

    for arc in problem.arcs:
        a0 = problem.nodes[arc.n0]
        a1 = problem.nodes[arc.n1]
        k = max(1, math.ceil(arc.arc_length_deg / arc.max_side_length_deg))
        cx, cy, r = _arc_circle(a0, a1, arc.arc_length_deg)
        step = math.radians(arc.arc_length_deg) / k
        if k == 1:
            linelst.append(Segment(n0=arc.n0, n1=arc.n1,
                                   boundary_marker=arc.boundary_marker,
                                   in_conductor=arc.in_conductor))
        else:
            prev_idx = arc.n0
            # rotate from n0
            dx, dy = a0.x - cx, a0.y - cy
            for j in range(1, k):
                ang = j * step
                cosv, sinv = math.cos(ang), math.sin(ang)
                nx = cx + dx * cosv - dy * sinv
                ny = cy + dx * sinv + dy * cosv
                nodelst.append(Node(x=nx, y=ny, in_conductor=arc.in_conductor))
                this_idx = len(nodelst) - 1
                linelst.append(Segment(n0=prev_idx, n1=this_idx,
                                       boundary_marker=arc.boundary_marker,
                                       in_conductor=arc.in_conductor))
                prev_idx = this_idx
            linelst.append(Segment(n0=prev_idx, n1=arc.n1,
                                   boundary_marker=arc.boundary_marker,
                                   in_conductor=arc.in_conductor))

    with open(poly, "wt") as fp:
        # node list — FEMM encodes the point bdry as +(j+2) and packs the
        # conductor number into the upper 16 bits (see bd_writepoly.cpp).
        fp.write(f"{len(nodelst)}\t2\t0\t1\n")
        for i, n in enumerate(nodelst):
            t = 0
            if n.boundary_marker:
                pidx = problem._lookup_point_idx(n.boundary_marker)
                if pidx:
                    t = pidx + 1  # pidx is already 1-based; we want j+2
            if n.in_conductor:
                cidx = problem._lookup_conductor_idx(n.in_conductor)
                if cidx:
                    t += cidx * 0x10000
            fp.write(f"{i}\t{n.x:.17g}\t{n.y:.17g}\t{t}\n")

        # segment list — bdry is -(j+2), conductor packed into upper 16 bits
        # with the opposite sign.
        fp.write(f"{len(linelst)}\t1\n")
        for i, s in enumerate(linelst):
            t = 0
            if s.boundary_marker:
                bidx = problem._lookup_bdry_idx(s.boundary_marker)
                if bidx:
                    t = -(bidx + 1)
            if s.in_conductor:
                cidx = problem._lookup_conductor_idx(s.in_conductor)
                if cidx:
                    t -= cidx * 0x10000
            fp.write(f"{i}\t{s.n0}\t{s.n1}\t{t}\n")

        # no holes
        fp.write("0\n")

        # regional attributes — one per block label, using label index+1 as
        # the region marker; triangle propagates this marker to every
        # element it produces inside that region.
        if nodelst:
            xs = [n.x for n in nodelst]
            ys = [n.y for n in nodelst]
            bbox = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
            default_mesh = (bbox / 100.0) ** 2  # BoundingBoxFraction=100 in FEMM
            if not problem.smart_mesh:
                default_mesh = bbox / 100.0
        else:
            default_mesh = -1

        fp.write(f"{len(problem.labels)}\n")
        for i, lbl in enumerate(problem.labels):
            area = lbl.max_area if (0 < lbl.max_area < default_mesh) else default_mesh
            fp.write(f"{i}\t{lbl.x:.17g}\t{lbl.y:.17g}\t{i + 1}\t{area:.17g}\n")

    with open(pbc, "wt") as fp:
        fp.write("0\n")

    return poly
