"""Magnetics problem — ``mi_*`` surface, writes ``.fem``, runs fknsolve.

Covers the full fkn feature set: static 2D / axi, harmonic 2D / axi, with
anisotropic permeability, BH curves, laminations, wound circuits, AGEs
(not yet exposed via the Python API) and previous-solution restart hooks.
Mirrors fkn/femmedoccore.cpp::OnOpenDocument and femm/FemmeDoc.cpp::OnSaveDocument.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .geometry import BaseProblem, BlockLabel, write_poly
from . import solver as _solver


@dataclass
class PointProp:
    name: str
    Jp: complex = 0j   # prescribed current A
    Ap: complex = 0j   # prescribed vector potential Wb/m


@dataclass
class BdryProp:
    name: str
    bdry_format: int = 0  # 0 prescribed A, 1 mixed, 2 SSB, 3 pbc, 4 apbc, 5 aniso
    A0: float = 0.0
    A1: float = 0.0
    A2: float = 0.0
    phi: float = 0.0
    c0: complex = 0j
    c1: complex = 0j
    Mu: float = 0.0
    Sig: float = 0.0
    InnerAngle: float = 0.0
    OuterAngle: float = 0.0


@dataclass
class BlockProp:
    name: str
    mu_x: float = 1.0
    mu_y: float = 1.0
    H_c: float = 0.0
    Theta_m: float = 0.0  # magnetization angle (deg)
    Jsrc: complex = 0j    # applied current density (MA/m^2)
    Cduct: float = 0.0    # electrical conductivity (MS/m)
    Lam_d: float = 0.0    # lamination thickness (mm)
    Theta_hn: float = 0.0
    Theta_hx: float = 0.0
    Theta_hy: float = 0.0
    LamType: int = 0
    LamFill: float = 1.0
    NStrands: int = 0
    WireD: float = 0.0
    BHdata: list[tuple[float, float]] = field(default_factory=list)  # (B, H) pairs


@dataclass
class CircuitProp:
    name: str
    Amps: complex = 0j
    circ_type: int = 0  # 0 parallel, 1 series


class MagneticsProblem(BaseProblem):
    _file_ext = ".fem"
    _solver_name = "fknsolve"
    _output_ext = ".ans"

    def __init__(self) -> None:
        super().__init__()
        self.frequency: float = 0.0
        self.ac_solver: int = 0       # 0 succ. approx, 1 Newton
        self.prev_type: int = 0       # 0 none, 1 incremental, 2 frozen, 3 restart
        self.prev_soln: str = ""

    # ------------------------------------------------------------------
    # Property adders
    # ------------------------------------------------------------------
    def mi_add_point_prop(self, name: str, Jp: complex = 0j, Ap: complex = 0j) -> None:
        self.point_props.append(PointProp(name=name, Jp=Jp, Ap=Ap))

    def mi_add_bdry_prop(self, name: str, **kw) -> None:
        self.bdry_props.append(BdryProp(name=name, **kw))

    def mi_add_material(
        self,
        name: str,
        mu_x: float = 1.0,
        mu_y: float = 1.0,
        H_c: float = 0.0,
        Jsrc: complex = 0j,
        Cduct: float = 0.0,
        Lam_d: float = 0.0,
        Theta_hn: float = 0.0,
        LamFill: float = 1.0,
        LamType: int = 0,
        NStrands: int = 0,
        WireD: float = 0.0,
    ) -> None:
        self.block_props.append(BlockProp(
            name=name, mu_x=mu_x, mu_y=mu_y, H_c=H_c, Jsrc=Jsrc,
            Cduct=Cduct, Lam_d=Lam_d, Theta_hn=Theta_hn,
            LamFill=LamFill, LamType=LamType,
            NStrands=NStrands, WireD=WireD,
        ))

    def mi_add_bh_point(self, material_name: str, B: float, H: float) -> None:
        for m in self.block_props:
            if m.name == material_name:
                m.BHdata.append((B, H))
                return
        raise KeyError(f"unknown material {material_name!r}")

    def mi_add_circprop(self, name: str, Amps: complex = 0j, circ_type: int = 0) -> None:
        self.conductor_props.append(
            CircuitProp(name=name, Amps=Amps, circ_type=circ_type)
        )

    mi_addnode = BaseProblem.add_node
    mi_addsegment = BaseProblem.add_segment
    mi_addarc = BaseProblem.add_arc
    mi_addblocklabel = BaseProblem.add_block_label
    mi_addpointprop = mi_add_point_prop
    mi_addboundprop = mi_add_bdry_prop
    mi_addmaterial = mi_add_material
    mi_addbhpoint = mi_add_bh_point

    def mi_probdef(
        self,
        frequency: float = 0.0,
        units: str = "millimeters",
        problem_type: str = "planar",
        precision: float = 1.0e-8,
        depth: float = 1.0,
        min_angle: float = 30.0,
        ac_solver: int = 0,
    ) -> None:
        self.frequency = frequency
        self.length_units = units
        self.problem_type = problem_type
        self.precision = precision
        self.depth = depth
        self.min_angle = min_angle
        self.ac_solver = ac_solver

    def mi_saveas(self, path: str | Path) -> Path:
        return self.save(path)

    def mi_analyze(self, path: str | Path) -> Path:
        p = self.save(path)
        write_poly(self, p)
        _solver.run_triangle(p, min_angle=self.min_angle)
        return _solver.run_solver(p, self._solver_name)

    # ------------------------------------------------------------------
    # Magnetics uses richer block-label columns than the other physics:
    #   x  y  BlockType  MaxArea  InCircuit  MagDir  InGroup  Turns  IsExternal
    #   [optional "MagDirFctn"]
    # ------------------------------------------------------------------
    def _write_label_row(self, fp, lbl: BlockLabel) -> None:
        t = self._lookup_block_idx(lbl.block_type) if lbl.block_type else 0
        ma = lbl.max_area if lbl.max_area > 0 else -1
        # In the Windows writer this is sqrt(4*A/pi) — the "characteristic
        # length" of a label. We keep the same emission so the file round-
        # trips through the Windows GUI unchanged.
        if ma < 0:
            ma_s = "-1"
        else:
            import math
            ma_s = f"{math.sqrt(4.0 * ma / math.pi):.17g}"
        c = self._lookup_conductor_idx(lbl.in_circuit) if lbl.in_circuit else 0
        flags = lbl.is_external + 2 * lbl.is_default
        line = (f"{lbl.x:.17g}\t{lbl.y:.17g}\t{t}\t{ma_s}\t{c}"
                f"\t{lbl.mag_dir:.17g}\t{lbl.in_group}\t{lbl.turns}\t{flags}")
        if lbl.mag_dir_fctn:
            line += f'\t"{lbl.mag_dir_fctn}"'
        fp.write(line + "\n")

    def _format_version(self) -> str:
        return "4.0"

    def _write_extra_header(self, fp) -> None:
        fp.write(f"[Frequency]   =  {self.frequency:.17g}\n")
        # The [Precision]/etc. lines are emitted by the base class *after*
        # this hook — ACSolver/PrevType/PrevSoln go here so they appear in
        # the natural FEMM ordering.
        # (Base class emits Precision, MinAngle, DoSmartMesh, Depth next.)
        # We'll emit ACSolver / PrevType / PrevSoln right after Frequency;
        # the parsers don't care about order.
        fp.write(f"[ACSolver]    =  {self.ac_solver}\n")
        fp.write(f"[PrevType]    =  {self.prev_type}\n")
        fp.write(f'[PrevSoln]    =  "{self.prev_soln}"\n')

    def _write_point_props(self, fp) -> None:
        fp.write(f"[PointProps]   = {len(self.point_props)}\n")
        for p in self.point_props:
            fp.write("  <BeginPoint>\n")
            fp.write(f'    <PointName> = "{p.name}"\n')
            fp.write(f"    <I_re> = {p.Jp.real:.17g}\n")
            fp.write(f"    <I_im> = {p.Jp.imag:.17g}\n")
            fp.write(f"    <A_re> = {p.Ap.real:.17g}\n")
            fp.write(f"    <A_im> = {p.Ap.imag:.17g}\n")
            fp.write("  <EndPoint>\n")

    def _write_bdry_props(self, fp) -> None:
        fp.write(f"[BdryProps]   = {len(self.bdry_props)}\n")
        for b in self.bdry_props:
            fp.write("  <BeginBdry>\n")
            fp.write(f'    <BdryName> = "{b.name}"\n')
            fp.write(f"    <BdryType> = {b.bdry_format}\n")
            fp.write(f"    <A_0> = {b.A0:.17g}\n")
            fp.write(f"    <A_1> = {b.A1:.17g}\n")
            fp.write(f"    <A_2> = {b.A2:.17g}\n")
            fp.write(f"    <Phi> = {b.phi:.17g}\n")
            fp.write(f"    <c0> = {b.c0.real:.17g}\n")
            fp.write(f"    <c0i> = {b.c0.imag:.17g}\n")
            fp.write(f"    <c1> = {b.c1.real:.17g}\n")
            fp.write(f"    <c1i> = {b.c1.imag:.17g}\n")
            fp.write(f"    <Mu_ssd> = {b.Mu:.17g}\n")
            fp.write(f"    <Sigma_ssd> = {b.Sig:.17g}\n")
            fp.write(f"    <innerangle> = {b.InnerAngle:.17g}\n")
            fp.write(f"    <outerangle> = {b.OuterAngle:.17g}\n")
            fp.write("  <EndBdry>\n")

    def _write_block_props(self, fp) -> None:
        fp.write(f"[BlockProps]  = {len(self.block_props)}\n")
        for m in self.block_props:
            fp.write("  <BeginBlock>\n")
            fp.write(f'    <BlockName> = "{m.name}"\n')
            fp.write(f"    <Mu_x> = {m.mu_x:.17g}\n")
            fp.write(f"    <Mu_y> = {m.mu_y:.17g}\n")
            fp.write(f"    <H_c> = {m.H_c:.17g}\n")
            fp.write(f"    <H_cAngle> = {m.Theta_m:.17g}\n")
            fp.write(f"    <J_re> = {m.Jsrc.real:.17g}\n")
            fp.write(f"    <J_im> = {m.Jsrc.imag:.17g}\n")
            fp.write(f"    <Sigma> = {m.Cduct:.17g}\n")
            fp.write(f"    <d_lam> = {m.Lam_d:.17g}\n")
            fp.write(f"    <Phi_h> = {m.Theta_hn:.17g}\n")
            fp.write(f"    <Phi_hx> = {m.Theta_hx:.17g}\n")
            fp.write(f"    <Phi_hy> = {m.Theta_hy:.17g}\n")
            fp.write(f"    <LamType> = {m.LamType}\n")
            fp.write(f"    <LamFill> = {m.LamFill:.17g}\n")
            fp.write(f"    <NStrands> = {m.NStrands}\n")
            fp.write(f"    <WireD> = {m.WireD:.17g}\n")
            fp.write(f"    <BHPoints> = {len(m.BHdata)}\n")
            for B, H in m.BHdata:
                fp.write(f"      {B:.17g}\t{H:.17g}\n")
            fp.write("  <EndBlock>\n")

    def _write_conductor_props(self, fp) -> None:
        fp.write(f"[CircuitProps]  = {len(self.conductor_props)}\n")
        for c in self.conductor_props:
            fp.write("  <BeginCircuit>\n")
            fp.write(f'    <CircuitName> = "{c.name}"\n')
            fp.write(f"    <TotalAmps_re> = {c.Amps.real:.17g}\n")
            fp.write(f"    <TotalAmps_im> = {c.Amps.imag:.17g}\n")
            fp.write(f"    <CircuitType> = {c.circ_type}\n")
            fp.write("  <EndCircuit>\n")
