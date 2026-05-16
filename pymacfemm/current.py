"""Current-flow problem — ``ci_*`` surface, writes ``.fec``, runs csolve.

Complex material properties everywhere (AC current flow supports a
frequency; set ``frequency=0`` for DC). Mirrors csolv/femmedoccore.cpp
and femm/CDRAWDOC.CPP::OnSaveDocument.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .geometry import BaseProblem, write_poly
from . import solver as _solver


@dataclass
class PointProp:
    name: str
    vp_re: float = 0.0
    vp_im: float = 0.0
    qp_re: float = 0.0
    qp_im: float = 0.0


@dataclass
class BdryProp:
    name: str
    bdry_format: int = 0
    vs_re: float = 0.0
    vs_im: float = 0.0
    qs_re: float = 0.0
    qs_im: float = 0.0
    c0_re: float = 0.0
    c0_im: float = 0.0
    c1_re: float = 0.0
    c1_im: float = 0.0


@dataclass
class BlockProp:
    name: str
    ox: float = 1.0  # conductivity, S/m (x)
    oy: float = 1.0  # conductivity, S/m (y)
    ex: float = 1.0  # relative permittivity (x)
    ey: float = 1.0  # relative permittivity (y)
    ltx: float = 0.0  # dielectric loss tangent (x)
    lty: float = 0.0  # dielectric loss tangent (y)


@dataclass
class ConductorProp:
    name: str
    vc_re: float = 0.0
    vc_im: float = 0.0
    qc_re: float = 0.0
    qc_im: float = 0.0
    circ_type: int = 0


class CurrentProblem(BaseProblem):
    _file_ext = ".fec"
    _solver_name = "csolve"
    _output_ext = ".anc"

    def __init__(self) -> None:
        super().__init__()
        self.frequency: float = 0.0

    # ------------------------------------------------------------------
    # Property adders
    # ------------------------------------------------------------------
    def ci_add_point_prop(self, name: str, Vp: complex = 0j, qp: complex = 0j) -> None:
        self.point_props.append(PointProp(
            name=name,
            vp_re=Vp.real, vp_im=Vp.imag,
            qp_re=qp.real, qp_im=qp.imag,
        ))

    def ci_add_bdry_prop(self, name: str, bdry_format: int = 0,
                         Vs: complex = 0j, qs: complex = 0j,
                         c0: complex = 0j, c1: complex = 0j) -> None:
        self.bdry_props.append(BdryProp(
            name=name, bdry_format=bdry_format,
            vs_re=Vs.real, vs_im=Vs.imag,
            qs_re=qs.real, qs_im=qs.imag,
            c0_re=c0.real, c0_im=c0.imag,
            c1_re=c1.real, c1_im=c1.imag,
        ))

    def ci_add_material(self, name: str, ox: float = 1.0, oy: float = 1.0,
                        ex: float = 1.0, ey: float = 1.0,
                        ltx: float = 0.0, lty: float = 0.0) -> None:
        self.block_props.append(BlockProp(
            name=name, ox=ox, oy=oy, ex=ex, ey=ey, ltx=ltx, lty=lty,
        ))

    def ci_add_conductor(self, name: str, Vc: complex = 0j, qc: complex = 0j,
                         circ_type: int = 0) -> None:
        self.conductor_props.append(ConductorProp(
            name=name,
            vc_re=Vc.real, vc_im=Vc.imag,
            qc_re=qc.real, qc_im=qc.imag,
            circ_type=circ_type,
        ))

    ci_addnode = BaseProblem.add_node
    ci_addsegment = BaseProblem.add_segment
    ci_addarc = BaseProblem.add_arc
    ci_addblocklabel = BaseProblem.add_block_label
    ci_addpointprop = ci_add_point_prop
    ci_addboundprop = ci_add_bdry_prop
    ci_addmaterial = ci_add_material
    ci_addconductorprop = ci_add_conductor

    def ci_probdef(self, units: str = "millimeters", problem_type: str = "planar",
                   frequency: float = 0.0, precision: float = 1.0e-8,
                   depth: float = 1.0, min_angle: float = 30.0) -> None:
        self.length_units = units
        self.problem_type = problem_type
        self.frequency = frequency
        self.precision = precision
        self.depth = depth
        self.min_angle = min_angle

    def ci_saveas(self, path: str | Path) -> Path:
        return self.save(path)

    def ci_analyze(self, path: str | Path) -> Path:
        p = self.save(path)
        write_poly(self, p)
        _solver.run_triangle(p, min_angle=self.min_angle)
        return _solver.run_solver(p, self._solver_name)

    # ------------------------------------------------------------------
    # File emission
    # ------------------------------------------------------------------
    def _write_extra_header(self, fp) -> None:
        fp.write(f"[Frequency]   =  {self.frequency:.17g}\n")

    def _write_point_props(self, fp) -> None:
        fp.write(f"[PointProps]   = {len(self.point_props)}\n")
        for p in self.point_props:
            fp.write("  <BeginPoint>\n")
            fp.write(f'    <PointName> = "{p.name}"\n')
            fp.write(f"    <vpr> = {p.vp_re:.17g}\n")
            fp.write(f"    <vpi> = {p.vp_im:.17g}\n")
            fp.write(f"    <qpr> = {p.qp_re:.17g}\n")
            fp.write(f"    <qpi> = {p.qp_im:.17g}\n")
            fp.write("  <EndPoint>\n")

    def _write_bdry_props(self, fp) -> None:
        fp.write(f"[BdryProps]   = {len(self.bdry_props)}\n")
        for b in self.bdry_props:
            fp.write("  <BeginBdry>\n")
            fp.write(f'    <BdryName> = "{b.name}"\n')
            fp.write(f"    <BdryType> = {b.bdry_format}\n")
            fp.write(f"    <vsr> = {b.vs_re:.17g}\n")
            fp.write(f"    <vsi> = {b.vs_im:.17g}\n")
            fp.write(f"    <qsr> = {b.qs_re:.17g}\n")
            fp.write(f"    <qsi> = {b.qs_im:.17g}\n")
            fp.write(f"    <c0r>  = {b.c0_re:.17g}\n")
            fp.write(f"    <c0i>  = {b.c0_im:.17g}\n")
            fp.write(f"    <c1r>  = {b.c1_re:.17g}\n")
            fp.write(f"    <c1i>  = {b.c1_im:.17g}\n")
            fp.write("  <EndBdry>\n")

    def _write_block_props(self, fp) -> None:
        fp.write(f"[BlockProps]  = {len(self.block_props)}\n")
        for b in self.block_props:
            fp.write("  <BeginBlock>\n")
            fp.write(f'    <BlockName> = "{b.name}"\n')
            fp.write(f"    <ox> = {b.ox:.17g}\n")
            fp.write(f"    <oy> = {b.oy:.17g}\n")
            fp.write(f"    <ex> = {b.ex:.17g}\n")
            fp.write(f"    <ey> = {b.ey:.17g}\n")
            fp.write(f"    <ltx> = {b.ltx:.17g}\n")
            fp.write(f"    <lty> = {b.lty:.17g}\n")
            fp.write("  <EndBlock>\n")

    def _write_conductor_props(self, fp) -> None:
        fp.write(f"[ConductorProps]  = {len(self.conductor_props)}\n")
        for c in self.conductor_props:
            fp.write("  <BeginConductor>\n")
            fp.write(f'    <ConductorName> = "{c.name}"\n')
            fp.write(f"    <vcr> = {c.vc_re:.17g}\n")
            fp.write(f"    <vci> = {c.vc_im:.17g}\n")
            fp.write(f"    <qcr> = {c.qc_re:.17g}\n")
            fp.write(f"    <qci> = {c.qc_im:.17g}\n")
            fp.write(f"    <ConductorType> = {c.circ_type}\n")
            fp.write("  <EndConductor>\n")
