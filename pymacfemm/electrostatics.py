"""Electrostatics problem — the ``ei_*`` surface, writes ``.fee``, runs belasolve.

Maps to belasolv/femmedoccore.cpp::OnOpenDocument and the file format written
by femm/beladrawDoc.cpp::OnSaveDocument.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .geometry import BaseProblem, write_poly
from . import solver as _solver


@dataclass
class PointProp:
    name: str
    V: float = 0.0  # prescribed voltage at point
    qp: float = 0.0  # point charge density


@dataclass
class BdryProp:
    name: str
    bdry_format: int = 0  # 0 fixed-V, 1 mixed, 2 surface-charge, 3 pbc, 4 apbc
    V: float = 0.0
    qs: float = 0.0
    c0: float = 0.0
    c1: float = 0.0


@dataclass
class BlockProp:
    name: str
    ex: float = 1.0  # relative permittivity, x
    ey: float = 1.0  # relative permittivity, y
    qv: float = 0.0  # volume charge, C/m^3


@dataclass
class ConductorProp:
    name: str
    V: float = 0.0
    q: float = 0.0
    circ_type: int = 0  # 0 prescribed charge, 1 prescribed voltage


class ElectrostaticsProblem(BaseProblem):
    _file_ext = ".fee"
    _solver_name = "belasolve"
    _output_ext = ".res"

    def ei_add_point_prop(self, name: str, V: float = 0.0, qp: float = 0.0) -> None:
        self.point_props.append(PointProp(name=name, V=V, qp=qp))

    def ei_add_bdry_prop(self, name: str, **kw) -> None:
        self.bdry_props.append(BdryProp(name=name, **kw))

    def ei_add_material(self, name: str, ex: float = 1.0, ey: float = 1.0, qv: float = 0.0) -> None:
        self.block_props.append(BlockProp(name=name, ex=ex, ey=ey, qv=qv))

    def ei_add_conductor(self, name: str, V: float = 0.0, q: float = 0.0, circ_type: int = 0) -> None:
        self.conductor_props.append(
            ConductorProp(name=name, V=V, q=q, circ_type=circ_type)
        )

    # Convenience aliases matching pyfemm's naming
    ei_addnode = BaseProblem.add_node
    ei_addsegment = BaseProblem.add_segment
    ei_addarc = BaseProblem.add_arc
    ei_addblocklabel = BaseProblem.add_block_label
    ei_addpointprop = ei_add_point_prop
    ei_addboundprop = ei_add_bdry_prop
    ei_addmaterial = ei_add_material
    ei_addconductorprop = ei_add_conductor

    def ei_probdef(
        self,
        units: str = "millimeters",
        problem_type: str = "planar",
        precision: float = 1.0e-8,
        depth: float = 1.0,
        min_angle: float = 30.0,
    ) -> None:
        self.length_units = units
        self.problem_type = problem_type
        self.precision = precision
        self.depth = depth
        self.min_angle = min_angle

    def ei_saveas(self, path: str | Path) -> Path:
        return self.save(path)

    def ei_analyze(self, path: str | Path) -> Path:
        """Full pipeline: save → mesh → solve. Returns the .res path."""
        p = self.save(path)
        write_poly(self, p)
        _solver.run_triangle(p, min_angle=self.min_angle)
        return _solver.run_solver(p, self._solver_name)

    # ------------------------------------------------------------------
    # Property emission
    # ------------------------------------------------------------------
    def _write_point_props(self, fp) -> None:
        fp.write(f"[PointProps]   = {len(self.point_props)}\n")
        for p in self.point_props:
            fp.write("  <BeginPoint>\n")
            fp.write(f'    <PointName> = "{p.name}"\n')
            fp.write(f"    <Vp> = {p.V:.17g}\n")
            fp.write(f"    <qp> = {p.qp:.17g}\n")
            fp.write("  <EndPoint>\n")

    def _write_bdry_props(self, fp) -> None:
        fp.write(f"[BdryProps]   = {len(self.bdry_props)}\n")
        for b in self.bdry_props:
            fp.write("  <BeginBdry>\n")
            fp.write(f'    <BdryName> = "{b.name}"\n')
            fp.write(f"    <BdryType> = {b.bdry_format}\n")
            fp.write(f"    <Vs> = {b.V:.17g}\n")
            fp.write(f"    <qs> = {b.qs:.17g}\n")
            fp.write(f"    <c0> = {b.c0:.17g}\n")
            fp.write(f"    <c1> = {b.c1:.17g}\n")
            fp.write("  <EndBdry>\n")

    def _write_block_props(self, fp) -> None:
        fp.write(f"[BlockProps]  = {len(self.block_props)}\n")
        for b in self.block_props:
            fp.write("  <BeginBlock>\n")
            fp.write(f'    <BlockName> = "{b.name}"\n')
            fp.write(f"    <ex> = {b.ex:.17g}\n")
            fp.write(f"    <ey> = {b.ey:.17g}\n")
            fp.write(f"    <qv> = {b.qv:.17g}\n")
            fp.write("  <EndBlock>\n")

    def _write_conductor_props(self, fp) -> None:
        fp.write(f"[ConductorProps]  = {len(self.conductor_props)}\n")
        for c in self.conductor_props:
            fp.write("  <BeginConductor>\n")
            fp.write(f'    <ConductorName> = "{c.name}"\n')
            fp.write(f"    <Vc> = {c.V:.17g}\n")
            fp.write(f"    <qc> = {c.q:.17g}\n")
            fp.write(f"    <ConductorType> = {c.circ_type}\n")
            fp.write("  <EndConductor>\n")
