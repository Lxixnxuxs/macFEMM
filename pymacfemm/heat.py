"""Heat-flow problem — ``hi_*`` surface, writes ``.feh``, runs hsolve.

Mirrors hsolv/femmedoccore-style parsers (the hsolv doc file is called
``hsolvdoc.cpp``) and femm/HDRAWDOC.CPP::OnSaveDocument.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .geometry import BaseProblem, write_poly
from . import solver as _solver


@dataclass
class PointProp:
    name: str
    T: float = 0.0
    qp: float = 0.0


@dataclass
class BdryProp:
    name: str
    bdry_format: int = 0  # 0 fixed-T, 1 heat flux, 2 convection, 3 radiation, 4/5 pbc/apbc
    Tset: float = 0.0
    qs: float = 0.0
    beta: float = 0.0
    h: float = 0.0
    Tinf: float = 0.0
    TinfRad: float = 0.0


@dataclass
class BlockProp:
    name: str
    Kx: float = 1.0
    Ky: float = 1.0
    Kt: float = 0.0  # temperature-dependent thermal capacitance (for transient)
    qv: float = 0.0  # volumetric heat generation W/m^3
    Kn_re: list = field(default_factory=list)
    Kn_im: list = field(default_factory=list)


@dataclass
class ConductorProp:
    name: str
    T: float = 0.0
    q: float = 0.0
    circ_type: int = 0


class HeatProblem(BaseProblem):
    _file_ext = ".feh"
    _solver_name = "hsolve"
    _output_ext = ".anh"

    def __init__(self) -> None:
        super().__init__()
        self.prev_soln: str = ""
        self.dT: float = 0.0

    def hi_add_point_prop(self, name: str, T: float = 0.0, qp: float = 0.0) -> None:
        self.point_props.append(PointProp(name=name, T=T, qp=qp))

    def hi_add_bdry_prop(self, name: str, **kw) -> None:
        self.bdry_props.append(BdryProp(name=name, **kw))

    def hi_add_material(self, name: str, Kx: float = 1.0, Ky: float = 1.0,
                        qv: float = 0.0, Kt: float = 0.0) -> None:
        self.block_props.append(BlockProp(name=name, Kx=Kx, Ky=Ky, Kt=Kt, qv=qv))

    def hi_add_conductor(self, name: str, T: float = 0.0, q: float = 0.0,
                         circ_type: int = 0) -> None:
        self.conductor_props.append(
            ConductorProp(name=name, T=T, q=q, circ_type=circ_type)
        )

    hi_addnode = BaseProblem.add_node
    hi_addsegment = BaseProblem.add_segment
    hi_addarc = BaseProblem.add_arc
    hi_addblocklabel = BaseProblem.add_block_label
    hi_addpointprop = hi_add_point_prop
    hi_addboundprop = hi_add_bdry_prop
    hi_addmaterial = hi_add_material
    hi_addconductorprop = hi_add_conductor

    def hi_probdef(self, units: str = "millimeters", problem_type: str = "planar",
                   precision: float = 1.0e-8, depth: float = 1.0,
                   min_angle: float = 30.0) -> None:
        self.length_units = units
        self.problem_type = problem_type
        self.precision = precision
        self.depth = depth
        self.min_angle = min_angle

    def hi_saveas(self, path: str | Path) -> Path:
        return self.save(path)

    def hi_analyze(self, path: str | Path) -> Path:
        p = self.save(path)
        write_poly(self, p)
        _solver.run_triangle(p, min_angle=self.min_angle)
        return _solver.run_solver(p, self._solver_name)

    # ------------------------------------------------------------------
    def _write_extra_header(self, fp) -> None:
        fp.write(f'[PrevSoln] = "{self.prev_soln}"\n')
        fp.write(f"[dT] = {self.dT:.17g}\n")

    def _write_point_props(self, fp) -> None:
        fp.write(f"[PointProps]   = {len(self.point_props)}\n")
        for p in self.point_props:
            fp.write("  <BeginPoint>\n")
            fp.write(f'    <PointName> = "{p.name}"\n')
            fp.write(f"    <Tp> = {p.T:.17g}\n")
            fp.write(f"    <qp> = {p.qp:.17g}\n")
            fp.write("  <EndPoint>\n")

    def _write_bdry_props(self, fp) -> None:
        fp.write(f"[BdryProps]   = {len(self.bdry_props)}\n")
        for b in self.bdry_props:
            fp.write("  <BeginBdry>\n")
            fp.write(f'    <BdryName> = "{b.name}"\n')
            fp.write(f"    <BdryType> = {b.bdry_format}\n")
            fp.write(f"    <Tset> = {b.Tset:.17g}\n")
            fp.write(f"    <qs>   = {b.qs:.17g}\n")
            fp.write(f"    <beta> = {b.beta:.17g}\n")
            fp.write(f"    <h>    = {b.h:.17g}\n")
            fp.write(f"    <Tinf> = {b.Tinf:.17g}\n")
            fp.write(f"    <TinfRad> = {b.TinfRad:.17g}\n")
            fp.write("  <EndBdry>\n")

    def _write_block_props(self, fp) -> None:
        fp.write(f"[BlockProps]  = {len(self.block_props)}\n")
        for b in self.block_props:
            fp.write("  <BeginBlock>\n")
            fp.write(f'    <BlockName> = "{b.name}"\n')
            fp.write(f"    <Kx> = {b.Kx:.17g}\n")
            fp.write(f"    <Ky> = {b.Ky:.17g}\n")
            fp.write(f"    <Kt> = {b.Kt:.17g}\n")
            fp.write(f"    <qv> = {b.qv:.17g}\n")
            if b.Kn_re:
                fp.write(f"    <TKPoints> = {len(b.Kn_re)}\n")
                for re, im in zip(b.Kn_re, b.Kn_im):
                    fp.write(f"      {re:.17g}\t{im:.17g}\n")
            fp.write("  <EndBlock>\n")

    def _write_conductor_props(self, fp) -> None:
        fp.write(f"[ConductorProps]  = {len(self.conductor_props)}\n")
        for c in self.conductor_props:
            fp.write("  <BeginConductor>\n")
            fp.write(f'    <ConductorName> = "{c.name}"\n')
            fp.write(f"    <Tc> = {c.T:.17g}\n")
            fp.write(f"    <qc> = {c.q:.17g}\n")
            fp.write(f"    <ConductorType> = {c.circ_type}\n")
            fp.write("  <EndConductor>\n")
