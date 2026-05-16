// femm_io.cpp — .fem/.fee/.feh/.fec writer and loader.
//
// The writer matches pymacfemm/geometry.py + the four physics writers
// byte-for-byte (same key order, same `%.17g` format). The reader is a
// minimal round-trip parser — enough to reopen files we wrote, not a full
// FEMM-dialect parser. Later phases will harden it against upstream files
// (comments, extra whitespace, Windows absolute paths, etc.).

#include "femm_doc.hpp"
#include "femm_c.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

namespace femmcore {

namespace {

const char* units_str(femm_length_units_t u) {
    switch (u) {
        case FEMM_UNITS_INCHES:      return "inches";
        case FEMM_UNITS_MILLIMETERS: return "millimeters";
        case FEMM_UNITS_CENTIMETERS: return "centimeters";
        case FEMM_UNITS_METERS:      return "meters";
        case FEMM_UNITS_MILS:        return "mils";
        case FEMM_UNITS_MICROMETERS: return "micrometers";
    }
    return "millimeters";
}

femm_length_units_t units_from(const std::string& s) {
    if (s == "inches") return FEMM_UNITS_INCHES;
    if (s == "millimeters") return FEMM_UNITS_MILLIMETERS;
    if (s == "centimeters") return FEMM_UNITS_CENTIMETERS;
    if (s == "meters") return FEMM_UNITS_METERS;
    if (s == "mils") return FEMM_UNITS_MILS;
    if (s == "microns" || s == "micrometers") return FEMM_UNITS_MICROMETERS;
    return FEMM_UNITS_MILLIMETERS;
}

void fp_g(std::ostream& os, double v) {
    // Match Python's `%.17g` output for identity round-trips.
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    os << buf;
}

void write_header_common(std::ostream& os, const Document& d, const char* version) {
    os << "[Format]      =  " << version << "\n";

    // Physics-specific extra header lines, in FEMM's natural order.
    switch (d.physics) {
        case FEMM_PHYSICS_MAGNETICS:
            os << "[Frequency]   =  "; fp_g(os, d.frequency); os << "\n";
            os << "[ACSolver]    =  " << d.ac_solver << "\n";
            os << "[PrevType]    =  " << d.prev_type << "\n";
            os << "[PrevSoln]    =  \"" << d.prev_soln << "\"\n";
            break;
        case FEMM_PHYSICS_CURRENT:
            os << "[Frequency]   =  "; fp_g(os, d.frequency); os << "\n";
            break;
        case FEMM_PHYSICS_HEAT:
            os << "[PrevSoln] = \"" << d.prev_soln << "\"\n";
            os << "[dT] = "; fp_g(os, d.dT); os << "\n";
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            break;
    }

    os << "[Precision]   =  "; fp_g(os, d.precision); os << "\n";
    os << "[MinAngle]    =  "; fp_g(os, d.min_angle); os << "\n";
    os << "[DoSmartMesh] =  " << d.smart_mesh << "\n";
    os << "[Depth]       =  "; fp_g(os, d.depth); os << "\n";
    os << "[LengthUnits] =  " << units_str(d.length_units) << "\n";
    if (d.problem_type == FEMM_PROBLEM_PLANAR) {
        os << "[ProblemType] =  planar\n";
    } else {
        os << "[ProblemType] =  axisymmetric\n";
        if (d.ext_ro != 0.0 && d.ext_ri != 0.0) {
            os << "[extZo] = "; fp_g(os, d.ext_zo); os << "\n";
            os << "[extRo] = "; fp_g(os, d.ext_ro); os << "\n";
            os << "[extRi] = "; fp_g(os, d.ext_ri); os << "\n";
        }
    }
    os << "[Coordinates] =  " << (d.coordinates.empty() ? "cartesian" : d.coordinates) << "\n";
    os << "[Comment]     =  \"" << d.comment << "\"\n";
}

void write_props_magnetics(std::ostream& os, const Document& d) {
    os << "[PointProps]   = " << d.mag_pointprops.size() << "\n";
    for (auto const& p : d.mag_pointprops) {
        os << "  <BeginPoint>\n";
        os << "    <PointName> = \"" << p.name << "\"\n";
        os << "    <I_re> = "; fp_g(os, p.Jp.real()); os << "\n";
        os << "    <I_im> = "; fp_g(os, p.Jp.imag()); os << "\n";
        os << "    <A_re> = "; fp_g(os, p.Ap.real()); os << "\n";
        os << "    <A_im> = "; fp_g(os, p.Ap.imag()); os << "\n";
        os << "  <EndPoint>\n";
    }
    os << "[BdryProps]   = " << d.mag_boundaries.size() << "\n";
    for (auto const& b : d.mag_boundaries) {
        os << "  <BeginBdry>\n";
        os << "    <BdryName> = \"" << b.name << "\"\n";
        os << "    <BdryType> = " << b.fmt << "\n";
        os << "    <A_0> = "; fp_g(os, b.A0); os << "\n";
        os << "    <A_1> = "; fp_g(os, b.A1); os << "\n";
        os << "    <A_2> = "; fp_g(os, b.A2); os << "\n";
        os << "    <Phi> = "; fp_g(os, b.phi); os << "\n";
        os << "    <c0> = "; fp_g(os, b.c0.real()); os << "\n";
        os << "    <c0i> = "; fp_g(os, b.c0.imag()); os << "\n";
        os << "    <c1> = "; fp_g(os, b.c1.real()); os << "\n";
        os << "    <c1i> = "; fp_g(os, b.c1.imag()); os << "\n";
        os << "    <Mu_ssd> = "; fp_g(os, b.mu); os << "\n";
        os << "    <Sigma_ssd> = "; fp_g(os, b.sig); os << "\n";
        os << "    <innerangle> = "; fp_g(os, b.inner_angle); os << "\n";
        os << "    <outerangle> = "; fp_g(os, b.outer_angle); os << "\n";
        os << "  <EndBdry>\n";
    }
    os << "[BlockProps]  = " << d.mag_materials.size() << "\n";
    for (auto const& m : d.mag_materials) {
        os << "  <BeginBlock>\n";
        os << "    <BlockName> = \"" << m.name << "\"\n";
        os << "    <Mu_x> = "; fp_g(os, m.mu_x); os << "\n";
        os << "    <Mu_y> = "; fp_g(os, m.mu_y); os << "\n";
        os << "    <H_c> = "; fp_g(os, m.H_c); os << "\n";
        os << "    <H_cAngle> = "; fp_g(os, m.theta_m); os << "\n";
        os << "    <J_re> = "; fp_g(os, m.J_src.real()); os << "\n";
        os << "    <J_im> = "; fp_g(os, m.J_src.imag()); os << "\n";
        os << "    <Sigma> = "; fp_g(os, m.c_duct); os << "\n";
        os << "    <d_lam> = "; fp_g(os, m.lam_d); os << "\n";
        os << "    <Phi_h> = "; fp_g(os, m.theta_hn); os << "\n";
        os << "    <Phi_hx> = "; fp_g(os, m.theta_hx); os << "\n";
        os << "    <Phi_hy> = "; fp_g(os, m.theta_hy); os << "\n";
        os << "    <LamType> = " << m.lam_type << "\n";
        os << "    <LamFill> = "; fp_g(os, m.lam_fill); os << "\n";
        os << "    <NStrands> = " << m.n_strands << "\n";
        os << "    <WireD> = "; fp_g(os, m.wire_d); os << "\n";
        os << "    <BHPoints> = " << m.bh.size() << "\n";
        for (auto& [B, H] : m.bh) {
            os << "      "; fp_g(os, B); os << "\t"; fp_g(os, H); os << "\n";
        }
        os << "  <EndBlock>\n";
    }
    os << "[CircuitProps]  = " << d.mag_circuits.size() << "\n";
    for (auto const& c : d.mag_circuits) {
        os << "  <BeginCircuit>\n";
        os << "    <CircuitName> = \"" << c.name << "\"\n";
        os << "    <TotalAmps_re> = "; fp_g(os, c.amps.real()); os << "\n";
        os << "    <TotalAmps_im> = "; fp_g(os, c.amps.imag()); os << "\n";
        os << "    <CircuitType> = " << c.circ_type << "\n";
        os << "  <EndCircuit>\n";
    }
}

void write_props_electrostatics(std::ostream& os, const Document& d) {
    os << "[PointProps]   = " << d.es_pointprops.size() << "\n";
    for (auto const& p : d.es_pointprops) {
        os << "  <BeginPoint>\n";
        os << "    <PointName> = \"" << p.name << "\"\n";
        os << "    <Vp> = "; fp_g(os, p.V); os << "\n";
        os << "    <qp> = "; fp_g(os, p.qp); os << "\n";
        os << "  <EndPoint>\n";
    }
    os << "[BdryProps]   = " << d.es_boundaries.size() << "\n";
    for (auto const& b : d.es_boundaries) {
        os << "  <BeginBdry>\n";
        os << "    <BdryName> = \"" << b.name << "\"\n";
        os << "    <BdryType> = " << b.fmt << "\n";
        os << "    <Vs> = "; fp_g(os, b.V); os << "\n";
        os << "    <qs> = "; fp_g(os, b.qs); os << "\n";
        os << "    <c0> = "; fp_g(os, b.c0); os << "\n";
        os << "    <c1> = "; fp_g(os, b.c1); os << "\n";
        os << "  <EndBdry>\n";
    }
    os << "[BlockProps]  = " << d.es_materials.size() << "\n";
    for (auto const& m : d.es_materials) {
        os << "  <BeginBlock>\n";
        os << "    <BlockName> = \"" << m.name << "\"\n";
        os << "    <ex> = "; fp_g(os, m.ex); os << "\n";
        os << "    <ey> = "; fp_g(os, m.ey); os << "\n";
        os << "    <qv> = "; fp_g(os, m.qv); os << "\n";
        os << "  <EndBlock>\n";
    }
    os << "[ConductorProps]  = " << d.es_conductors.size() << "\n";
    for (auto const& c : d.es_conductors) {
        os << "  <BeginConductor>\n";
        os << "    <ConductorName> = \"" << c.name << "\"\n";
        os << "    <Vc> = "; fp_g(os, c.V); os << "\n";
        os << "    <qc> = "; fp_g(os, c.q); os << "\n";
        os << "    <ConductorType> = " << c.circ_type << "\n";
        os << "  <EndConductor>\n";
    }
}

void write_props_heat(std::ostream& os, const Document& d) {
    os << "[PointProps]   = " << d.heat_pointprops.size() << "\n";
    for (auto const& p : d.heat_pointprops) {
        os << "  <BeginPoint>\n";
        os << "    <PointName> = \"" << p.name << "\"\n";
        os << "    <Tp> = "; fp_g(os, p.T); os << "\n";
        os << "    <qp> = "; fp_g(os, p.qp); os << "\n";
        os << "  <EndPoint>\n";
    }
    os << "[BdryProps]   = " << d.heat_boundaries.size() << "\n";
    for (auto const& b : d.heat_boundaries) {
        os << "  <BeginBdry>\n";
        os << "    <BdryName> = \"" << b.name << "\"\n";
        os << "    <BdryType> = " << b.fmt << "\n";
        os << "    <Tset> = "; fp_g(os, b.Tset); os << "\n";
        os << "    <qs>   = "; fp_g(os, b.qs); os << "\n";
        os << "    <beta> = "; fp_g(os, b.beta); os << "\n";
        os << "    <h>    = "; fp_g(os, b.h); os << "\n";
        os << "    <Tinf> = "; fp_g(os, b.Tinf); os << "\n";
        os << "    <TinfRad> = "; fp_g(os, b.TinfRad); os << "\n";
        os << "  <EndBdry>\n";
    }
    os << "[BlockProps]  = " << d.heat_materials.size() << "\n";
    for (auto const& m : d.heat_materials) {
        os << "  <BeginBlock>\n";
        os << "    <BlockName> = \"" << m.name << "\"\n";
        os << "    <Kx> = "; fp_g(os, m.Kx); os << "\n";
        os << "    <Ky> = "; fp_g(os, m.Ky); os << "\n";
        os << "    <Kt> = "; fp_g(os, m.Kt); os << "\n";
        os << "    <qv> = "; fp_g(os, m.qv); os << "\n";
        os << "  <EndBlock>\n";
    }
    os << "[ConductorProps]  = " << d.heat_conductors.size() << "\n";
    for (auto const& c : d.heat_conductors) {
        os << "  <BeginConductor>\n";
        os << "    <ConductorName> = \"" << c.name << "\"\n";
        os << "    <Tc> = "; fp_g(os, c.T); os << "\n";
        os << "    <qc> = "; fp_g(os, c.q); os << "\n";
        os << "    <ConductorType> = " << c.circ_type << "\n";
        os << "  <EndConductor>\n";
    }
}

void write_props_current(std::ostream& os, const Document& d) {
    os << "[PointProps]   = " << d.curr_pointprops.size() << "\n";
    for (auto const& p : d.curr_pointprops) {
        os << "  <BeginPoint>\n";
        os << "    <PointName> = \"" << p.name << "\"\n";
        os << "    <vpr> = "; fp_g(os, p.Vp.real()); os << "\n";
        os << "    <vpi> = "; fp_g(os, p.Vp.imag()); os << "\n";
        os << "    <qpr> = "; fp_g(os, p.qp.real()); os << "\n";
        os << "    <qpi> = "; fp_g(os, p.qp.imag()); os << "\n";
        os << "  <EndPoint>\n";
    }
    os << "[BdryProps]   = " << d.curr_boundaries.size() << "\n";
    for (auto const& b : d.curr_boundaries) {
        os << "  <BeginBdry>\n";
        os << "    <BdryName> = \"" << b.name << "\"\n";
        os << "    <BdryType> = " << b.fmt << "\n";
        os << "    <vsr> = "; fp_g(os, b.Vs.real()); os << "\n";
        os << "    <vsi> = "; fp_g(os, b.Vs.imag()); os << "\n";
        os << "    <qsr> = "; fp_g(os, b.qs.real()); os << "\n";
        os << "    <qsi> = "; fp_g(os, b.qs.imag()); os << "\n";
        os << "    <c0r>  = "; fp_g(os, b.c0.real()); os << "\n";
        os << "    <c0i>  = "; fp_g(os, b.c0.imag()); os << "\n";
        os << "    <c1r>  = "; fp_g(os, b.c1.real()); os << "\n";
        os << "    <c1i>  = "; fp_g(os, b.c1.imag()); os << "\n";
        os << "  <EndBdry>\n";
    }
    os << "[BlockProps]  = " << d.curr_materials.size() << "\n";
    for (auto const& m : d.curr_materials) {
        os << "  <BeginBlock>\n";
        os << "    <BlockName> = \"" << m.name << "\"\n";
        os << "    <ox> = "; fp_g(os, m.ox); os << "\n";
        os << "    <oy> = "; fp_g(os, m.oy); os << "\n";
        os << "    <ex> = "; fp_g(os, m.ex); os << "\n";
        os << "    <ey> = "; fp_g(os, m.ey); os << "\n";
        os << "    <ltx> = "; fp_g(os, m.ltx); os << "\n";
        os << "    <lty> = "; fp_g(os, m.lty); os << "\n";
        os << "  <EndBlock>\n";
    }
    os << "[ConductorProps]  = " << d.curr_conductors.size() << "\n";
    for (auto const& c : d.curr_conductors) {
        os << "  <BeginConductor>\n";
        os << "    <ConductorName> = \"" << c.name << "\"\n";
        os << "    <vcr> = "; fp_g(os, c.Vc.real()); os << "\n";
        os << "    <vci> = "; fp_g(os, c.Vc.imag()); os << "\n";
        os << "    <qcr> = "; fp_g(os, c.qc.real()); os << "\n";
        os << "    <qci> = "; fp_g(os, c.qc.imag()); os << "\n";
        os << "    <ConductorType> = " << c.circ_type << "\n";
        os << "  <EndConductor>\n";
    }
}

// Magnetics labels have extra columns; the others use the short form.
void write_label_row(std::ostream& os, const Document& d, const BlockLabel& lbl) {
    const int t = lbl.block_idx;
    const bool is_mag = d.physics == FEMM_PHYSICS_MAGNETICS;

    // Characteristic length: sqrt(4*A/pi), matching the Windows writer.
    char ma_buf[64];
    if (lbl.max_area <= 0) {
        std::snprintf(ma_buf, sizeof ma_buf, "-1");
    } else {
        const double ma = is_mag
            ? std::sqrt(4.0 * lbl.max_area / M_PI)   // magnetics emits char length
            : std::sqrt(4.0 * lbl.max_area / M_PI);  // other physics likewise (pymacfemm confirmed)
        std::snprintf(ma_buf, sizeof ma_buf, "%.17g", ma);
    }

    const int flags = lbl.is_external + 2 * lbl.is_default;

    if (is_mag) {
        char xb[64], yb[64], mdb[64];
        std::snprintf(xb, sizeof xb, "%.17g", lbl.x);
        std::snprintf(yb, sizeof yb, "%.17g", lbl.y);
        std::snprintf(mdb, sizeof mdb, "%.17g", lbl.mag_dir);
        os << xb << "\t" << yb << "\t" << t << "\t" << ma_buf << "\t"
           << lbl.circuit_idx << "\t" << mdb << "\t" << lbl.group << "\t"
           << lbl.turns << "\t" << flags;
        if (!lbl.mag_dir_fctn.empty()) os << "\t\"" << lbl.mag_dir_fctn << "\"";
        os << "\n";
    } else {
        char xb[64], yb[64];
        std::snprintf(xb, sizeof xb, "%.17g", lbl.x);
        std::snprintf(yb, sizeof yb, "%.17g", lbl.y);
        os << xb << "\t" << yb << "\t" << t << "\t" << ma_buf << "\t"
           << lbl.group << "\t" << flags << "\n";
    }
}

void write_geometry(std::ostream& os, const Document& d) {
    const bool is_mag = d.physics == FEMM_PHYSICS_MAGNETICS;

    os << "[NumPoints] = " << d.nodes.size() << "\n";
    for (auto const& n : d.nodes) {
        char xb[64], yb[64];
        std::snprintf(xb, sizeof xb, "%.17g", n.x);
        std::snprintf(yb, sizeof yb, "%.17g", n.y);
        os << xb << "\t" << yb << "\t" << n.bdry_idx << "\t" << n.group;
        if (!is_mag) os << "\t" << n.in_conductor;
        os << "\n";
    }

    os << "[NumSegments] = " << d.segments.size() << "\n";
    for (auto const& s : d.segments) {
        char mb[64];
        if (s.max_side <= 0) std::snprintf(mb, sizeof mb, "-1");
        else                  std::snprintf(mb, sizeof mb, "%.17g", s.max_side);
        os << s.n0 << "\t" << s.n1 << "\t" << mb << "\t" << s.bdry_idx
           << "\t" << s.hidden << "\t" << s.group;
        if (!is_mag) os << "\t" << s.in_conductor;
        os << "\n";
    }

    os << "[NumArcSegments] = " << d.arcs.size() << "\n";
    for (auto const& a : d.arcs) {
        char ab[64], msb[64];
        std::snprintf(ab, sizeof ab, "%.17g", a.arc_deg);
        std::snprintf(msb, sizeof msb, "%.17g", a.max_side_deg);
        os << a.n0 << "\t" << a.n1 << "\t" << ab << "\t" << msb
           << "\t" << a.bdry_idx << "\t" << a.hidden << "\t" << a.group;
        if (!is_mag) os << "\t" << a.in_conductor;
        /* Magnetics: emit placeholder mySideLength (MaxSideLength) so round-trip is stable. */
        if (is_mag) {
            char mb[64];
            std::snprintf(mb, sizeof mb, "%.17g", a.max_side_deg);
            os << "\t" << mb;
        }
        os << "\n";
    }

    os << "[NumHoles] = 0\n";

    os << "[NumBlockLabels] = " << d.labels.size() << "\n";
    for (auto const& lbl : d.labels) write_label_row(os, d, lbl);
}

std::string ensure_ext(const std::string& path, const char* ext) {
    // Append `ext` if the path doesn't already end with it (case-insensitive).
    const size_t n = path.size(), e = std::strlen(ext);
    if (n >= e) {
        bool match = true;
        for (size_t i = 0; i < e; ++i) {
            char a = path[n - e + i];
            char b = ext[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) { match = false; break; }
        }
        if (match) return path;
    }
    return path + ext;
}

} // namespace

femm_status_t write_document(const Document& d, const std::string& path) {
    const std::string p = ensure_ext(path, file_ext_for(d.physics));
    std::ofstream os(p);
    if (!os) {
        set_last_error("cannot open output file: " + p);
        return FEMM_ERR_IO;
    }

    const char* version = (d.physics == FEMM_PHYSICS_MAGNETICS) ? "4.0" : "1";
    write_header_common(os, d, version);

    switch (d.physics) {
        case FEMM_PHYSICS_MAGNETICS:      write_props_magnetics(os, d);      break;
        case FEMM_PHYSICS_ELECTROSTATICS: write_props_electrostatics(os, d); break;
        case FEMM_PHYSICS_HEAT:           write_props_heat(os, d);           break;
        case FEMM_PHYSICS_CURRENT:        write_props_current(os, d);        break;
    }
    write_geometry(os, d);

    if (!os.good()) {
        set_last_error("write error on " + p);
        return FEMM_ERR_IO;
    }
    return FEMM_OK;
}

/* --- Read-back --------------------------------------------------------- */
namespace {

// Very small, forgiving parser for files produced by write_document().
// Tolerates extra whitespace; recognizes [key] = value and <tag> = value.
// Only parses geometry sufficiently for identity round-trip; property bodies
// are tracked by [BlockProps]=N style counts.

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

std::string strip_quotes(std::string s) {
    s = trim(s);
    if (s.size() >= 2 && s.front() == '"' && s.back() == '"')
        return s.substr(1, s.size() - 2);
    return s;
}

// Extract the value after `=` (trimmed; quotes stripped).
bool split_kv(const std::string& line, std::string& key, std::string& val) {
    size_t eq = line.find('=');
    if (eq == std::string::npos) return false;
    key = trim(line.substr(0, eq));
    val = trim(line.substr(eq + 1));
    return true;
}

femm_physics_t detect_physics(const std::string& path) {
    // Extension-based detection. Lowercase compare.
    auto dot = path.find_last_of('.');
    std::string e = (dot == std::string::npos) ? "" : path.substr(dot);
    for (auto& c : e) c = (char)std::tolower((unsigned char)c);
    if (e == ".fem") return FEMM_PHYSICS_MAGNETICS;
    if (e == ".fee") return FEMM_PHYSICS_ELECTROSTATICS;
    if (e == ".feh") return FEMM_PHYSICS_HEAT;
    if (e == ".fec") return FEMM_PHYSICS_CURRENT;
    return FEMM_PHYSICS_MAGNETICS;
}

// Parse a single <Tag> = value line into (tag, value) for body lines inside a
// <BeginX>...<EndX> block. Tag comes back without the angle brackets.
bool split_tag_value(const std::string& s, std::string& tag, std::string& val) {
    std::string t = trim(s);
    if (t.size() < 2 || t[0] != '<') return false;
    auto gt = t.find('>');
    if (gt == std::string::npos) return false;
    tag = t.substr(1, gt - 1);
    auto eq = t.find('=', gt + 1);
    if (eq == std::string::npos) { val.clear(); return true; }
    val = trim(t.substr(eq + 1));
    return true;
}

double parse_d(const std::string& v) { try { return std::stod(v); } catch (...) { return 0.0; } }
int    parse_i(const std::string& v) { try { return std::stoi(v); } catch (...) { return 0; } }

// Read N blocks of <BeginX>...<EndX>, calling `on_line` for every tagged
// body line inside, and `on_block_end` after each inner block closes. Any
// nested BHPoints rows are delivered to `on_extra` (raw line).
template <typename LineFn, typename EndFn, typename ExtraFn>
void read_blocks(std::istream& is, int n, LineFn on_line, EndFn on_end, ExtraFn on_extra) {
    std::string line;
    int depth = 0;
    bool collect_extras = false;
    int extras_left = 0;
    while (n > 0 && std::getline(is, line)) {
        std::string tl = trim(line);
        if (tl.rfind("<Begin", 0) == 0) { depth++; continue; }
        if (tl.rfind("<End", 0) == 0) {
            if (--depth == 0) { on_end(); n--; collect_extras = false; extras_left = 0; }
            continue;
        }
        if (collect_extras && extras_left > 0) {
            on_extra(tl);
            extras_left--;
            if (extras_left == 0) collect_extras = false;
            continue;
        }
        std::string tag, val;
        if (!split_tag_value(tl, tag, val)) continue;
        int extras = on_line(tag, val);
        if (extras > 0) { collect_extras = true; extras_left = extras; }
    }
}

void parse_mag_points(std::istream& is, int n, Document& d) {
    mag::PointProp cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "PointName") cur.name = strip_quotes(val);
            else if (tag == "I_re") cur.Jp.real(parse_d(val));
            else if (tag == "I_im") cur.Jp.imag(parse_d(val));
            else if (tag == "A_re") cur.Ap.real(parse_d(val));
            else if (tag == "A_im") cur.Ap.imag(parse_d(val));
            return 0;
        },
        [&]() { d.mag_pointprops.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

void parse_mag_boundaries(std::istream& is, int n, Document& d) {
    mag::Boundary cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BdryName")  cur.name = strip_quotes(val);
            else if (tag == "BdryType")  cur.fmt = parse_i(val);
            else if (tag == "A_0")       cur.A0 = parse_d(val);
            else if (tag == "A_1")       cur.A1 = parse_d(val);
            else if (tag == "A_2")       cur.A2 = parse_d(val);
            else if (tag == "Phi")       cur.phi = parse_d(val);
            else if (tag == "c0")        cur.c0.real(parse_d(val));
            else if (tag == "c0i")       cur.c0.imag(parse_d(val));
            else if (tag == "c1")        cur.c1.real(parse_d(val));
            else if (tag == "c1i")       cur.c1.imag(parse_d(val));
            else if (tag == "Mu_ssd")    cur.mu = parse_d(val);
            else if (tag == "Sigma_ssd") cur.sig = parse_d(val);
            else if (tag == "innerangle") cur.inner_angle = parse_d(val);
            else if (tag == "outerangle") cur.outer_angle = parse_d(val);
            return 0;
        },
        [&]() { d.mag_boundaries.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

void parse_mag_blocks(std::istream& is, int n, Document& d) {
    mag::Material cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BlockName") cur.name = strip_quotes(val);
            else if (tag == "Mu_x")     cur.mu_x = parse_d(val);
            else if (tag == "Mu_y")     cur.mu_y = parse_d(val);
            else if (tag == "H_c")      cur.H_c = parse_d(val);
            else if (tag == "H_cAngle") cur.theta_m = parse_d(val);
            else if (tag == "J_re")     cur.J_src.real(parse_d(val));
            else if (tag == "J_im")     cur.J_src.imag(parse_d(val));
            else if (tag == "Sigma")    cur.c_duct = parse_d(val);
            else if (tag == "d_lam")    cur.lam_d = parse_d(val);
            else if (tag == "Phi_h")    cur.theta_hn = parse_d(val);
            else if (tag == "Phi_hx")   cur.theta_hx = parse_d(val);
            else if (tag == "Phi_hy")   cur.theta_hy = parse_d(val);
            else if (tag == "LamType")  cur.lam_type = parse_i(val);
            else if (tag == "LamFill")  cur.lam_fill = parse_d(val);
            else if (tag == "NStrands") cur.n_strands = parse_i(val);
            else if (tag == "WireD")    cur.wire_d = parse_d(val);
            else if (tag == "BHPoints") {
                int k = parse_i(val);
                cur.bh.clear();
                return k; // triggers extras-collection for `k` BH rows
            }
            return 0;
        },
        [&]() { d.mag_materials.push_back(cur); cur = {}; },
        [&](const std::string& raw) {
            std::istringstream ss(raw);
            double B = 0, H = 0;
            if (ss >> B >> H) cur.bh.emplace_back(B, H);
        });
}

void parse_mag_circuits(std::istream& is, int n, Document& d) {
    mag::Circuit cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "CircuitName")   cur.name = strip_quotes(val);
            else if (tag == "TotalAmps_re")  cur.amps.real(parse_d(val));
            else if (tag == "TotalAmps_im")  cur.amps.imag(parse_d(val));
            else if (tag == "CircuitType")   cur.circ_type = parse_i(val);
            return 0;
        },
        [&]() { d.mag_circuits.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

void parse_es_points(std::istream& is, int n, Document& d) {
    es::PointProp cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "PointName") cur.name = strip_quotes(val);
            else if (tag == "Vp")        cur.V  = parse_d(val);
            else if (tag == "qp")        cur.qp = parse_d(val);
            return 0;
        },
        [&]() { d.es_pointprops.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_es_boundaries(std::istream& is, int n, Document& d) {
    es::Boundary cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BdryName") cur.name = strip_quotes(val);
            else if (tag == "BdryType") cur.fmt = parse_i(val);
            else if (tag == "Vs")       cur.V = parse_d(val);
            else if (tag == "qs")       cur.qs = parse_d(val);
            else if (tag == "c0")       cur.c0 = parse_d(val);
            else if (tag == "c1")       cur.c1 = parse_d(val);
            return 0;
        },
        [&]() { d.es_boundaries.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_es_blocks(std::istream& is, int n, Document& d) {
    es::Material cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BlockName") cur.name = strip_quotes(val);
            else if (tag == "ex") cur.ex = parse_d(val);
            else if (tag == "ey") cur.ey = parse_d(val);
            else if (tag == "qv") cur.qv = parse_d(val);
            return 0;
        },
        [&]() { d.es_materials.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_es_conductors(std::istream& is, int n, Document& d) {
    es::Conductor cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "ConductorName") cur.name = strip_quotes(val);
            else if (tag == "Vc")            cur.V = parse_d(val);
            else if (tag == "qc")            cur.q = parse_d(val);
            else if (tag == "ConductorType") cur.circ_type = parse_i(val);
            return 0;
        },
        [&]() { d.es_conductors.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

void parse_heat_points(std::istream& is, int n, Document& d) {
    heat::PointProp cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "PointName") cur.name = strip_quotes(val);
            else if (tag == "Tp")        cur.T = parse_d(val);
            else if (tag == "qp")        cur.qp = parse_d(val);
            return 0;
        },
        [&]() { d.heat_pointprops.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_heat_boundaries(std::istream& is, int n, Document& d) {
    heat::Boundary cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BdryName") cur.name = strip_quotes(val);
            else if (tag == "BdryType") cur.fmt = parse_i(val);
            else if (tag == "Tset") cur.Tset = parse_d(val);
            else if (tag == "qs")   cur.qs   = parse_d(val);
            else if (tag == "beta") cur.beta = parse_d(val);
            else if (tag == "h")    cur.h    = parse_d(val);
            else if (tag == "Tinf") cur.Tinf = parse_d(val);
            else if (tag == "TinfRad") cur.TinfRad = parse_d(val);
            return 0;
        },
        [&]() { d.heat_boundaries.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_heat_blocks(std::istream& is, int n, Document& d) {
    heat::Material cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BlockName") cur.name = strip_quotes(val);
            else if (tag == "Kx") cur.Kx = parse_d(val);
            else if (tag == "Ky") cur.Ky = parse_d(val);
            else if (tag == "Kt") cur.Kt = parse_d(val);
            else if (tag == "qv") cur.qv = parse_d(val);
            return 0;
        },
        [&]() { d.heat_materials.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_heat_conductors(std::istream& is, int n, Document& d) {
    heat::Conductor cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "ConductorName") cur.name = strip_quotes(val);
            else if (tag == "Tc") cur.T = parse_d(val);
            else if (tag == "qc") cur.q = parse_d(val);
            else if (tag == "ConductorType") cur.circ_type = parse_i(val);
            return 0;
        },
        [&]() { d.heat_conductors.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

void parse_curr_points(std::istream& is, int n, Document& d) {
    curr::PointProp cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "PointName") cur.name = strip_quotes(val);
            else if (tag == "vpr") cur.Vp.real(parse_d(val));
            else if (tag == "vpi") cur.Vp.imag(parse_d(val));
            else if (tag == "qpr") cur.qp.real(parse_d(val));
            else if (tag == "qpi") cur.qp.imag(parse_d(val));
            return 0;
        },
        [&]() { d.curr_pointprops.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_curr_boundaries(std::istream& is, int n, Document& d) {
    curr::Boundary cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BdryName") cur.name = strip_quotes(val);
            else if (tag == "BdryType") cur.fmt = parse_i(val);
            else if (tag == "vsr") cur.Vs.real(parse_d(val));
            else if (tag == "vsi") cur.Vs.imag(parse_d(val));
            else if (tag == "qsr") cur.qs.real(parse_d(val));
            else if (tag == "qsi") cur.qs.imag(parse_d(val));
            else if (tag == "c0r") cur.c0.real(parse_d(val));
            else if (tag == "c0i") cur.c0.imag(parse_d(val));
            else if (tag == "c1r") cur.c1.real(parse_d(val));
            else if (tag == "c1i") cur.c1.imag(parse_d(val));
            return 0;
        },
        [&]() { d.curr_boundaries.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_curr_blocks(std::istream& is, int n, Document& d) {
    curr::Material cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "BlockName") cur.name = strip_quotes(val);
            else if (tag == "ox") cur.ox = parse_d(val);
            else if (tag == "oy") cur.oy = parse_d(val);
            else if (tag == "ex") cur.ex = parse_d(val);
            else if (tag == "ey") cur.ey = parse_d(val);
            else if (tag == "ltx") cur.ltx = parse_d(val);
            else if (tag == "lty") cur.lty = parse_d(val);
            return 0;
        },
        [&]() { d.curr_materials.push_back(cur); cur = {}; },
        [](const std::string&) {});
}
void parse_curr_conductors(std::istream& is, int n, Document& d) {
    curr::Conductor cur{};
    read_blocks(is, n,
        [&](const std::string& tag, const std::string& val) -> int {
            if      (tag == "ConductorName") cur.name = strip_quotes(val);
            else if (tag == "vcr") cur.Vc.real(parse_d(val));
            else if (tag == "vci") cur.Vc.imag(parse_d(val));
            else if (tag == "qcr") cur.qc.real(parse_d(val));
            else if (tag == "qci") cur.qc.imag(parse_d(val));
            else if (tag == "ConductorType") cur.circ_type = parse_i(val);
            return 0;
        },
        [&]() { d.curr_conductors.push_back(cur); cur = {}; },
        [](const std::string&) {});
}

} // namespace

femm_status_t read_document(const std::string& path, Document& d) {
    std::ifstream is(path);
    if (!is) {
        set_last_error("cannot open file: " + path);
        return FEMM_ERR_IO;
    }
    d = Document{};
    d.physics = detect_physics(path);

    std::string line;
    auto next_ints = [&](int& a, int& b) {
        if (!std::getline(is, line)) return false;
        std::istringstream ss(line);
        return (bool)(ss >> a >> b);
    };
    (void)next_ints;

    size_t num_points = 0, num_segs = 0, num_arcs = 0, num_labels = 0;

    while (std::getline(is, line)) {
        std::string l = trim(line);
        if (l.empty()) continue;

        std::string key, val;
        if (l[0] == '[' && split_kv(l, key, val)) {
            if      (key == "[Format]")      { /* version; ignored */ }
            else if (key == "[Frequency]")   d.frequency = std::stod(val);
            else if (key == "[ACSolver]")    d.ac_solver = std::stoi(val);
            else if (key == "[PrevType]")    d.prev_type = std::stoi(val);
            else if (key == "[PrevSoln]")    d.prev_soln = strip_quotes(val);
            else if (key == "[Precision]")   d.precision = std::stod(val);
            else if (key == "[MinAngle]")    d.min_angle = std::stod(val);
            else if (key == "[DoSmartMesh]") d.smart_mesh = std::stoi(val);
            else if (key == "[Depth]")       d.depth = std::stod(val);
            else if (key == "[dT]")          d.dT = std::stod(val);
            else if (key == "[LengthUnits]") d.length_units = units_from(val);
            else if (key == "[ProblemType]")
                d.problem_type = (val == "axisymmetric") ? FEMM_PROBLEM_AXISYMMETRIC : FEMM_PROBLEM_PLANAR;
            else if (key == "[Coordinates]") d.coordinates = val;
            else if (key == "[Comment]")     d.comment = strip_quotes(val);
            else if (key == "[extZo]")       d.ext_zo = std::stod(val);
            else if (key == "[extRo]")       d.ext_ro = std::stod(val);
            else if (key == "[extRi]")       d.ext_ri = std::stod(val);
            else if (key == "[PointProps]") {
                int n = std::stoi(val);
                switch (d.physics) {
                    case FEMM_PHYSICS_MAGNETICS:      parse_mag_points(is, n, d);  break;
                    case FEMM_PHYSICS_ELECTROSTATICS: parse_es_points(is, n, d);   break;
                    case FEMM_PHYSICS_HEAT:           parse_heat_points(is, n, d); break;
                    case FEMM_PHYSICS_CURRENT:        parse_curr_points(is, n, d); break;
                }
            }
            else if (key == "[BdryProps]") {
                int n = std::stoi(val);
                switch (d.physics) {
                    case FEMM_PHYSICS_MAGNETICS:      parse_mag_boundaries(is, n, d);  break;
                    case FEMM_PHYSICS_ELECTROSTATICS: parse_es_boundaries(is, n, d);   break;
                    case FEMM_PHYSICS_HEAT:           parse_heat_boundaries(is, n, d); break;
                    case FEMM_PHYSICS_CURRENT:        parse_curr_boundaries(is, n, d); break;
                }
            }
            else if (key == "[BlockProps]") {
                int n = std::stoi(val);
                switch (d.physics) {
                    case FEMM_PHYSICS_MAGNETICS:      parse_mag_blocks(is, n, d);  break;
                    case FEMM_PHYSICS_ELECTROSTATICS: parse_es_blocks(is, n, d);   break;
                    case FEMM_PHYSICS_HEAT:           parse_heat_blocks(is, n, d); break;
                    case FEMM_PHYSICS_CURRENT:        parse_curr_blocks(is, n, d); break;
                }
            }
            else if (key == "[CircuitProps]") {
                int n = std::stoi(val);
                if (d.physics == FEMM_PHYSICS_MAGNETICS) parse_mag_circuits(is, n, d);
            }
            else if (key == "[ConductorProps]") {
                int n = std::stoi(val);
                switch (d.physics) {
                    case FEMM_PHYSICS_ELECTROSTATICS: parse_es_conductors(is, n, d);   break;
                    case FEMM_PHYSICS_HEAT:           parse_heat_conductors(is, n, d); break;
                    case FEMM_PHYSICS_CURRENT:        parse_curr_conductors(is, n, d); break;
                    default: break;
                }
            }
            else if (key == "[NumPoints]")      num_points = (size_t)std::stoi(val);
            else if (key == "[NumSegments]")    num_segs   = (size_t)std::stoi(val);
            else if (key == "[NumArcSegments]") num_arcs   = (size_t)std::stoi(val);
            else if (key == "[NumHoles]") {
                int n = std::stoi(val);
                for (int i = 0; i < n; ++i) std::getline(is, line);
            }
            else if (key == "[NumBlockLabels]") num_labels = (size_t)std::stoi(val);

            // After a geometry count, read that many rows.
            if (key == "[NumPoints]") {
                const bool is_mag = d.physics == FEMM_PHYSICS_MAGNETICS;
                d.nodes.reserve(num_points);
                for (size_t i = 0; i < num_points && std::getline(is, line); ++i) {
                    std::istringstream ss(line);
                    Node n{};
                    ss >> n.x >> n.y >> n.bdry_idx >> n.group;
                    if (!is_mag) ss >> n.in_conductor;  /* magnetics has no InConductor */
                    d.nodes.push_back(n);
                }
            } else if (key == "[NumSegments]") {
                const bool is_mag = d.physics == FEMM_PHYSICS_MAGNETICS;
                d.segments.reserve(num_segs);
                for (size_t i = 0; i < num_segs && std::getline(is, line); ++i) {
                    std::istringstream ss(line);
                    Segment s{};
                    ss >> s.n0 >> s.n1 >> s.max_side >> s.bdry_idx >> s.hidden >> s.group;
                    if (!is_mag) ss >> s.in_conductor;
                    d.segments.push_back(s);
                }
            } else if (key == "[NumArcSegments]") {
                const bool is_mag = d.physics == FEMM_PHYSICS_MAGNETICS;
                d.arcs.reserve(num_arcs);
                for (size_t i = 0; i < num_arcs && std::getline(is, line); ++i) {
                    std::istringstream ss(line);
                    Arc a{};
                    ss >> a.n0 >> a.n1 >> a.arc_deg >> a.max_side_deg
                       >> a.bdry_idx >> a.hidden >> a.group;
                    if (!is_mag) ss >> a.in_conductor;
                    /* Magnetics writes an extra mySideLength double (transient cache); ignore. */
                    d.arcs.push_back(a);
                }
            } else if (key == "[NumBlockLabels]") {
                d.labels.reserve(num_labels);
                for (size_t i = 0; i < num_labels && std::getline(is, line); ++i) {
                    std::istringstream ss(line);
                    BlockLabel lbl{};
                    if (d.physics == FEMM_PHYSICS_MAGNETICS) {
                        int flags = 0;
                        ss >> lbl.x >> lbl.y >> lbl.block_idx >> lbl.max_area
                           >> lbl.circuit_idx >> lbl.mag_dir >> lbl.group
                           >> lbl.turns >> flags;
                        lbl.is_external = flags & 1;
                        lbl.is_default  = (flags >> 1) & 1;
                    } else {
                        int flags = 0;
                        ss >> lbl.x >> lbl.y >> lbl.block_idx >> lbl.max_area
                           >> lbl.group >> flags;
                        lbl.is_external = flags & 1;
                        lbl.is_default  = (flags >> 1) & 1;
                    }
                    // Windows convention: column 4 is a characteristic length L;
                    // internal storage is π·L²/4 (see FemmeDoc.cpp:2376 and siblings).
                    // A negative value is the "no limit" sentinel.
                    if (lbl.max_area < 0) lbl.max_area = 0;
                    else lbl.max_area = M_PI * lbl.max_area * lbl.max_area / 4.0;
                    d.labels.push_back(lbl);
                }
            }
        }
    }

    return FEMM_OK;
}

} // namespace femmcore

/* ======================================================================
 * C ABI — open/save
 * ====================================================================== */

using femmcore::Document;

extern "C" {

femm_status_t femm_doc_open(const char* path, femm_doc_t** out) {
    if (!path || !out) return FEMM_ERR_INVALID_ARG;
    auto* d = new (std::nothrow) Document();
    if (!d) return FEMM_ERR_OUT_OF_MEM;
    auto st = femmcore::read_document(path, *d);
    if (st != FEMM_OK) { delete d; return st; }
    *out = reinterpret_cast<femm_doc_t*>(d);
    return FEMM_OK;
}

femm_status_t femm_doc_save(femm_doc_t* doc, const char* path) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !path) return FEMM_ERR_INVALID_ARG;
    return femmcore::write_document(*d, path);
}

} // extern "C"
