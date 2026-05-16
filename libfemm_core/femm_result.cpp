// femm_result.cpp — Loader for .ans/.res/.anh/.anc solver output files.
//
// Mirrors pymacfemm/ans_reader.py. Each solver echoes the input .fem and
// appends a [Solution] block. We skip to [Solution], then parse per-physics:
//
//   belasolve (.res):   x y V Q         elements: p0 p1 p2 lbl
//   hsolve    (.anh):   same shape as belasolve (scalar field is T)
//   csolve    (.anc):   x y V.re V.im Q elements: same
//   fknsolve  (.ans):   static:   x y A     bc [Aprev?]
//                       harmonic: x y A.re A.im bc [Aprev?]

#include "femm_doc.hpp"
#include "femm_c.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace femmcore {

struct Result {
    femm_physics_t physics = FEMM_PHYSICS_MAGNETICS;
    double frequency = 0.0;

    std::vector<double> x, y;
    std::vector<Complex> V;          // scalar field: magnetics A, es V, heat T, curr V
    std::vector<int> bc;             // boundary marker / Q column
    std::vector<int> elements_ijk;   // 3*M
    std::vector<int> element_labels; // per element

    // Per-label circuit data echoed by fkn into .ans tail
    // (fkn/prob1big.cpp:815-831). case_type: 0=voltage drop, 1=current density.
    // For case 1, value is J in MA/m² (Windows' internal unit, see GetJA
    // *= 1e6). For case 0, value is dVolts in V/m (per-unit-length).
    std::vector<int>    label_circuit_case;
    std::vector<double> label_circuit_value;
};

} // namespace femmcore

struct femm_result {
    femmcore::Result r;
};

namespace femmcore {

namespace {

std::string lower(std::string s) {
    for (auto& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string trim(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace((unsigned char)s[a])) ++a;
    while (b > a && std::isspace((unsigned char)s[b - 1])) --b;
    return s.substr(a, b - a);
}

femm_physics_t physics_from_ext(const std::string& path) {
    auto dot = path.find_last_of('.');
    std::string e = (dot == std::string::npos) ? "" : lower(path.substr(dot));
    if (e == ".res") return FEMM_PHYSICS_ELECTROSTATICS; // also csolve output — override via explicit arg
    if (e == ".anh") return FEMM_PHYSICS_HEAT;
    if (e == ".anc") return FEMM_PHYSICS_CURRENT;
    if (e == ".ans") return FEMM_PHYSICS_MAGNETICS;
    return FEMM_PHYSICS_MAGNETICS;
}

bool skip_to_solution(std::ifstream& is, double& frequency) {
    std::string line;
    frequency = 0.0;
    while (std::getline(is, line)) {
        std::string l = trim(line);
        if (l.empty()) continue;
        std::string low = lower(l);
        if (low.rfind("[frequency]", 0) == 0) {
            auto eq = l.find('=');
            if (eq != std::string::npos) {
                try { frequency = std::stod(trim(l.substr(eq + 1))); } catch (...) {}
            }
        }
        if (low.rfind("[solution]", 0) == 0) return true;
    }
    return false;
}

int read_int_line(std::ifstream& is) {
    std::string line;
    if (!std::getline(is, line)) return 0;
    std::istringstream ss(line);
    int n = 0; ss >> n; return n;
}

} // namespace

} // namespace femmcore

extern "C" {

femm_status_t femm_result_load(const char* path, femm_physics_t physics,
                               femm_result_t** out) {
    using namespace femmcore;
    if (!path || !out) return FEMM_ERR_INVALID_ARG;

    std::ifstream is(path);
    if (!is) { femmcore::set_last_error(std::string("cannot open ") + path); return FEMM_ERR_IO; }

    // For callers that pass MAGNETICS as a placeholder, trust the extension
    // unless the explicit physics disambiguates (belasolve and csolve both use
    // .res in the docs — be defensive: caller should pass correct physics).
    double frequency = 0.0;
    if (!skip_to_solution(is, frequency)) {
        femmcore::set_last_error("no [Solution] section found");
        return FEMM_ERR_PARSE;
    }

    auto* r = new (std::nothrow) femm_result_t();
    if (!r) return FEMM_ERR_OUT_OF_MEM;
    r->r.physics = physics;
    r->r.frequency = frequency;

    int n = read_int_line(is);
    if (n < 0) { delete r; femmcore::set_last_error("negative node count"); return FEMM_ERR_PARSE; }
    r->r.x.resize(n); r->r.y.resize(n);
    r->r.V.assign(n, Complex{0, 0});
    r->r.bc.assign(n, 0);

    std::string line;
    for (int i = 0; i < n; ++i) {
        if (!std::getline(is, line)) { delete r; femmcore::set_last_error("truncated node block"); return FEMM_ERR_PARSE; }
        std::istringstream ss(line);
        double x, y;
        if (!(ss >> x >> y)) { delete r; femmcore::set_last_error("bad node row"); return FEMM_ERR_PARSE; }
        r->r.x[i] = x; r->r.y[i] = y;

        switch (physics) {
            case FEMM_PHYSICS_ELECTROSTATICS:
            case FEMM_PHYSICS_HEAT: {
                double V; int Q = 0;
                ss >> V >> Q;
                r->r.V[i] = Complex{V, 0};
                r->r.bc[i] = Q;
                break;
            }
            case FEMM_PHYSICS_CURRENT: {
                double re, im; int Q = 0;
                ss >> re >> im >> Q;
                r->r.V[i] = Complex{re, im};
                r->r.bc[i] = Q;
                break;
            }
            case FEMM_PHYSICS_MAGNETICS: {
                if (frequency == 0.0) {
                    double A; int marker = 0;
                    ss >> A >> marker;
                    r->r.V[i] = Complex{A, 0};
                    r->r.bc[i] = marker;
                } else {
                    double re, im; int marker = 0;
                    ss >> re >> im >> marker;
                    r->r.V[i] = Complex{re, im};
                    r->r.bc[i] = marker;
                }
                break;
            }
        }
    }

    int m = read_int_line(is);
    if (m < 0) { delete r; femmcore::set_last_error("negative element count"); return FEMM_ERR_PARSE; }
    r->r.elements_ijk.resize(3 * m);
    r->r.element_labels.resize(m);
    for (int i = 0; i < m; ++i) {
        if (!std::getline(is, line)) { delete r; femmcore::set_last_error("truncated element block"); return FEMM_ERR_PARSE; }
        std::istringstream ss(line);
        int a, b, c, lbl = 0;
        if (!(ss >> a >> b >> c)) { delete r; femmcore::set_last_error("bad element row"); return FEMM_ERR_PARSE; }
        ss >> lbl;
        r->r.elements_ijk[3*i + 0] = a;
        r->r.elements_ijk[3*i + 1] = b;
        r->r.elements_ijk[3*i + 2] = c;
        r->r.element_labels[i] = lbl;
    }

    // Magnetics only: the tail of the .ans carries per-label circuit data.
    // Layout (fkn/prob1big.cpp:815-831):
    //   NumBlockLabels\n
    //   <case>\t<value>\n        (NumBlockLabels lines)
    //   NumPBCs\n ... (ignored here)
    // For case=1 the value is J in MA/m²; for case=0, dVolts in V/m.
    if (physics == FEMM_PHYSICS_MAGNETICS) {
        int nb = read_int_line(is);
        if (nb > 0) {
            r->r.label_circuit_case.assign(nb, 1);
            r->r.label_circuit_value.assign(nb, 0.0);
            for (int i = 0; i < nb; ++i) {
                if (!std::getline(is, line)) break;
                std::istringstream ss(line);
                int cs = 1; double val = 0.0;
                ss >> cs >> val;
                r->r.label_circuit_case[i] = cs;
                r->r.label_circuit_value[i] = val;
            }
        }
    }

    *out = r;
    return FEMM_OK;
}

void femm_result_free(femm_result_t* r) { delete r; }

size_t femm_result_num_nodes(const femm_result_t* r) {
    return r ? r->r.x.size() : 0;
}
size_t femm_result_num_elements(const femm_result_t* r) {
    return r ? r->r.element_labels.size() : 0;
}
double femm_result_frequency(const femm_result_t* r) {
    return r ? r->r.frequency : 0.0;
}

femm_status_t femm_result_get_node_xy(const femm_result_t* r, double* xo, double* yo) {
    if (!r || !xo || !yo) return FEMM_ERR_INVALID_ARG;
    std::memcpy(xo, r->r.x.data(), r->r.x.size() * sizeof(double));
    std::memcpy(yo, r->r.y.data(), r->r.y.size() * sizeof(double));
    return FEMM_OK;
}

femm_status_t femm_result_get_nodal_scalar(const femm_result_t* r, double* out) {
    if (!r || !out) return FEMM_ERR_INVALID_ARG;
    for (size_t i = 0; i < r->r.V.size(); ++i) out[i] = r->r.V[i].real();
    return FEMM_OK;
}

femm_status_t femm_result_get_nodal_complex(const femm_result_t* r, femm_complex_t* out) {
    if (!r || !out) return FEMM_ERR_INVALID_ARG;
    for (size_t i = 0; i < r->r.V.size(); ++i) {
        out[i].re = r->r.V[i].real();
        out[i].im = r->r.V[i].imag();
    }
    return FEMM_OK;
}

femm_status_t femm_result_get_elements(const femm_result_t* r, int32_t* out) {
    if (!r || !out) return FEMM_ERR_INVALID_ARG;
    for (size_t i = 0; i < r->r.elements_ijk.size(); ++i)
        out[i] = (int32_t)r->r.elements_ijk[i];
    return FEMM_OK;
}

femm_status_t femm_result_get_element_labels(const femm_result_t* r, int32_t* out) {
    if (!r || !out) return FEMM_ERR_INVALID_ARG;
    for (size_t i = 0; i < r->r.element_labels.size(); ++i)
        out[i] = (int32_t)r->r.element_labels[i];
    return FEMM_OK;
}

femm_status_t femm_result_get_element_centroids(const femm_result_t* r,
                                                double* xo, double* yo) {
    if (!r || !xo || !yo) return FEMM_ERR_INVALID_ARG;
    const size_t m = r->r.element_labels.size();
    for (size_t e = 0; e < m; ++e) {
        int a = r->r.elements_ijk[3*e + 0];
        int b = r->r.elements_ijk[3*e + 1];
        int c = r->r.elements_ijk[3*e + 2];
        xo[e] = (r->r.x[a] + r->r.x[b] + r->r.x[c]) / 3.0;
        yo[e] = (r->r.y[a] + r->r.y[b] + r->r.y[c]) / 3.0;
    }
    return FEMM_OK;
}

/* Linear T3 gradient of a nodal scalar V over triangle (a,b,c).
 * ∂V/∂x = Σ V_i · b_i / (2·area), ∂V/∂y = Σ V_i · c_i / (2·area)
 * where b_i, c_i are the standard FE shape-function coefficients.
 */
static inline void tri_grad(double xa, double ya, double xb, double yb,
                            double xc, double yc,
                            double va, double vb, double vc,
                            double& gx, double& gy) {
    double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
    if (twoA == 0.0) { gx = gy = 0.0; return; }
    double ba = yb - yc, bb = yc - ya, bc = ya - yb;
    double ca = xc - xb, cb = xa - xc, cc = xb - xa;
    gx = (va * ba + vb * bb + vc * bc) / twoA;
    gy = (va * ca + vb * cb + vc * cc) / twoA;
}

/* Axisymmetric B from the stored flux-like quantity A.re (= 2π·r·c·A_raw per
 * fkn/prob3big.cpp lines 700-703). Mirrors femm/FemmviewDoc.cpp:2400 GetElementB.
 * Uses quadratic shape on 6 nodes (3 corners + 3 weighted midsides) so the
 * formula stays well-behaved when one or more corners sit on the axis r=0.
 *
 * Inputs: triangle in problem-length units; v[3] are stored A at corners;
 * r_m_per_unit is the SI conversion factor (e.g. 0.0254 for inches).
 * Outputs Br, Bz in Tesla. */
static inline void axi_element_B(double xa, double ya, double xb, double yb,
                                 double xc, double yc,
                                 double va, double vb, double vc,
                                 double r_m_per_unit,
                                 double& Br, double& Bz) {
    /* Shape-function coefficients b_i, c_i (same convention as Windows code). */
    double b0 = yb - yc, b1 = yc - ya, b2 = ya - yb;
    double c0 = xc - xb, c1 = xa - xc, c2 = xb - xa;
    double da = b0 * c1 - b1 * c0;
    if (da == 0.0) { Br = Bz = 0.0; return; }

    /* Nodal r's and element centroid r, both in problem-length units. */
    double R0 = xa, R1 = xb, R2 = xc;
    double r_centroid = (R0 + R1 + R2) / 3.0;

    /* 6 samples of the stored quantity: 3 corners, 3 r-weighted midsides. */
    double v[6];
    v[0] = va; v[2] = vb; v[4] = vc;
    v[1] = (R0 < 1e-6 && R1 < 1e-6) ? 0.5 * (v[0] + v[2])
         : (R1 * (3.0*v[0] + v[2]) + R0 * (v[0] + 3.0*v[2])) / (4.0 * (R0 + R1));
    v[3] = (R1 < 1e-6 && R2 < 1e-6) ? 0.5 * (v[2] + v[4])
         : (R2 * (3.0*v[2] + v[4]) + R1 * (v[2] + 3.0*v[4])) / (4.0 * (R1 + R2));
    v[5] = (R2 < 1e-6 && R0 < 1e-6) ? 0.5 * (v[4] + v[0])
         : (R0 * (3.0*v[4] + v[0]) + R2 * (v[4] + 3.0*v[0])) / (4.0 * (R2 + R0));

    double dp = (-v[0] + v[2] + 4.0*v[3] - 4.0*v[5]) / 3.0;
    double dq = (-v[0] - 4.0*v[1] + 4.0*v[3] + v[4]) / 3.0;

    /* Windows divides by da·2π·r·Lconv². Our caller passes r_m_per_unit = Lconv,
     * and we want SI Tesla. */
    double denom = da * 2.0 * 3.141592653589793 * r_centroid *
                   r_m_per_unit * r_m_per_unit;
    if (denom == 0.0) { Br = Bz = 0.0; return; }
    Br = -(c1 * dp + c2 * dq) / denom;
    Bz =  (b1 * dp + b2 * dq) / denom;
}

static inline double axi_interp_A(double xa, double ya, double xb, double yb,
                                  double xc, double yc,
                                  double va, double vb, double vc,
                                  double x, double y) {
    double a1 = xc * ya - xa * yc;
    double a2 = xa * yb - xb * ya;
    double b0 = yb - yc, b1 = yc - ya, b2 = ya - yb;
    double c0 = xc - xb, c1 = xa - xc, c2 = xb - xa;
    double da = b0 * c1 - b1 * c0;
    if (da == 0.0) return 0.0;

    double R0 = xa, R1 = xb, R2 = xc;
    double v[6];
    v[0] = va; v[2] = vb; v[4] = vc;
    v[1] = (R0 < 1e-6 && R1 < 1e-6) ? 0.5 * (v[0] + v[2])
         : (R1 * (3.0*v[0] + v[2]) + R0 * (v[0] + 3.0*v[2])) / (4.0 * (R0 + R1));
    v[3] = (R1 < 1e-6 && R2 < 1e-6) ? 0.5 * (v[2] + v[4])
         : (R2 * (3.0*v[2] + v[4]) + R1 * (v[2] + 3.0*v[4])) / (4.0 * (R1 + R2));
    v[5] = (R2 < 1e-6 && R0 < 1e-6) ? 0.5 * (v[4] + v[0])
         : (R0 * (3.0*v[4] + v[0]) + R2 * (v[4] + 3.0*v[0])) / (4.0 * (R2 + R0));

    double p = (b1 * x + c1 * y + a1) / da;
    double q = (b2 * x + c2 * y + a2) / da;
    return v[0]
        - p * (3.0 * v[0] - 4.0 * v[1] + v[2])
        + 2.0 * p * p * (v[0] - 2.0 * v[1] + v[2])
        - q * (3.0 * v[0] + v[4] - 4.0 * v[5])
        + 2.0 * q * q * (v[0] + v[4] - 2.0 * v[5])
        + 4.0 * p * q * (v[0] - v[1] + v[3] - v[5]);
}

/* SI length per problem-unit, matching femm/StdAfx.h LengthConv[]. */
static inline double length_conv(femm_length_units_t u) {
    switch (u) {
        case FEMM_UNITS_INCHES:      return 0.0254;
        case FEMM_UNITS_MILLIMETERS: return 0.001;
        case FEMM_UNITS_CENTIMETERS: return 0.01;
        case FEMM_UNITS_METERS:      return 1.0;
        case FEMM_UNITS_MILS:        return 2.54e-5;
        case FEMM_UNITS_MICROMETERS: return 1e-6;
    }
    return 0.001;
}

/* Material lookup for a block label (0-based) to pull μ / ε / k / σ scalars.
 * Solver writes element labels as 0-based (meshele[i].lbl is decremented on load). */
static inline void material_anisotropy(const femmcore::Document& d,
                                       int lbl_0based, double& kx, double& ky) {
    kx = ky = 1.0;
    if (lbl_0based < 0 || (size_t)lbl_0based >= d.labels.size()) return;
    int blk = d.labels[lbl_0based].block_idx;
    if (blk <= 0) return;
    switch (d.physics) {
        case FEMM_PHYSICS_MAGNETICS:
            if ((size_t)blk <= d.mag_materials.size()) {
                kx = d.mag_materials[blk - 1].mu_x;
                ky = d.mag_materials[blk - 1].mu_y;
            } break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            if ((size_t)blk <= d.es_materials.size()) {
                kx = d.es_materials[blk - 1].ex;
                ky = d.es_materials[blk - 1].ey;
            } break;
        case FEMM_PHYSICS_HEAT:
            if ((size_t)blk <= d.heat_materials.size()) {
                kx = d.heat_materials[blk - 1].Kx;
                ky = d.heat_materials[blk - 1].Ky;
            } break;
        case FEMM_PHYSICS_CURRENT:
            if ((size_t)blk <= d.curr_materials.size()) {
                kx = d.curr_materials[blk - 1].ox;
                ky = d.curr_materials[blk - 1].oy;
            } break;
    }
}

femm_status_t femm_result_get_element_vector(const femm_result_t* r,
                                             const femm_doc_t* doc_c,
                                             double* out) {
    if (!r || !out) return FEMM_ERR_INVALID_ARG;
    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const double lc = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const size_t m = r->r.element_labels.size();
    for (size_t e = 0; e < m; ++e) {
        int a = r->r.elements_ijk[3*e + 0];
        int b = r->r.elements_ijk[3*e + 1];
        int c = r->r.elements_ijk[3*e + 2];
        double va = r->r.V[a].real();
        double vb = r->r.V[b].real();
        double vc = r->r.V[c].real();
        double gx, gy;
        tri_grad(r->r.x[a], r->r.y[a], r->r.x[b], r->r.y[b], r->r.x[c], r->r.y[c],
                 va, vb, vc, gx, gy);
        gx /= lc; gy /= lc;  /* per-problem-unit → per-meter */
        switch (r->r.physics) {
            case FEMM_PHYSICS_MAGNETICS:
                // B = curl(A_z ẑ) = (∂A/∂y, -∂A/∂x)
                out[2*e + 0] =  gy;
                out[2*e + 1] = -gx;
                break;
            case FEMM_PHYSICS_ELECTROSTATICS:
            case FEMM_PHYSICS_CURRENT:
                // E = -grad(V)
                out[2*e + 0] = -gx;
                out[2*e + 1] = -gy;
                break;
            case FEMM_PHYSICS_HEAT: {
                // F = -k * grad(T), anisotropic
                double kx = 1, ky = 1;
                if (d) material_anisotropy(*d, r->r.element_labels[e], kx, ky);
                out[2*e + 0] = -kx * gx;
                out[2*e + 1] = -ky * gy;
                break;
            }
        }
    }
    return FEMM_OK;
}

int32_t femm_result_locate(const femm_result_t* r, double x, double y) {
    if (!r) return -1;
    const size_t m = r->r.element_labels.size();
    for (size_t e = 0; e < m; ++e) {
        int a = r->r.elements_ijk[3*e + 0];
        int b = r->r.elements_ijk[3*e + 1];
        int c = r->r.elements_ijk[3*e + 2];
        double xa = r->r.x[a], ya = r->r.y[a];
        double xb = r->r.x[b], yb = r->r.y[b];
        double xc = r->r.x[c], yc = r->r.y[c];
        double s1 = (xb - xa) * (y - ya) - (yb - ya) * (x - xa);
        double s2 = (xc - xb) * (y - yb) - (yc - yb) * (x - xb);
        double s3 = (xa - xc) * (y - yc) - (ya - yc) * (x - xc);
        bool hasNeg = (s1 < 0) || (s2 < 0) || (s3 < 0);
        bool hasPos = (s1 > 0) || (s2 > 0) || (s3 > 0);
        if (!(hasNeg && hasPos)) return (int32_t)e;
    }
    return -1;
}

/* Sample A, B, H at (x,y) in problem units for a magnetics result. Returns
 * true if the point is inside the mesh. H uses the containing element's
 * material μx, μy (relative); B is constant per element (linear T3). */
static bool mag_sample_ABH(const femm_result_t* r,
                           const femmcore::Document* d,
                           double x, double y,
                           double& A,
                           double& Bx, double& By,
                           double& Hx, double& Hy) {
    constexpr double MU0 = 4.0 * 3.141592653589793 * 1e-7;
    int32_t e = femm_result_locate(r, x, y);
    if (e < 0) return false;
    int ia = r->r.elements_ijk[3*e + 0];
    int ib = r->r.elements_ijk[3*e + 1];
    int ic = r->r.elements_ijk[3*e + 2];
    double xa = r->r.x[ia], ya = r->r.y[ia];
    double xb = r->r.x[ib], yb = r->r.y[ib];
    double xc = r->r.x[ic], yc = r->r.y[ic];
    double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
    if (twoA == 0.0) return false;
    double la = ((xb - x) * (yc - y) - (xc - x) * (yb - y)) / twoA;
    double lb = ((xc - x) * (ya - y) - (xa - x) * (yc - y)) / twoA;
    double lc = 1.0 - la - lb;
    double va = r->r.V[ia].real();
    double vb = r->r.V[ib].real();
    double vc = r->r.V[ic].real();
    const double lc_m = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const bool axi = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    if (axi) {
        /* Axi uses FEMM's quadratic interpolation for A and B. */
        A = axi_interp_A(xa, ya, xb, yb, xc, yc, va, vb, vc, x, y);
        axi_element_B(xa, ya, xb, yb, xc, yc, va, vb, vc, lc_m, Bx, By);
    } else {
        A = la * va + lb * vb + lc * vc;
        double gx, gy;
        tri_grad(xa, ya, xb, yb, xc, yc, va, vb, vc, gx, gy);
        gx /= lc_m; gy /= lc_m;
        Bx =  gy;
        By = -gx;
    }
    /* Default vacuum; override from label's material when available.
     * element_labels are 0-based (solver decrements on load). */
    double mux = 1.0, muy = 1.0;
    if (d) {
        int lbl = r->r.element_labels[e];
        if (lbl >= 0 && (size_t)lbl < d->labels.size()) {
            int blk = d->labels[lbl].block_idx;
            if (blk > 0 && (size_t)blk <= d->mag_materials.size()) {
                mux = d->mag_materials[blk - 1].mu_x;
                muy = d->mag_materials[blk - 1].mu_y;
                if (mux == 0) mux = 1;
                if (muy == 0) muy = 1;
            }
        }
    }
    Hx = Bx / (MU0 * mux);
    Hy = By / (MU0 * muy);
    return true;
}

femm_status_t femm_result_mag_line_integral(const femm_result_t* r,
                                            const femm_doc_t* doc_c,
                                            int32_t type,
                                            const double* contour_xy,
                                            size_t npts,
                                            int32_t samples_per_seg,
                                            femm_complex_t* out_z,
                                            int32_t* out_count) {
    if (!r || !contour_xy || !out_z) return FEMM_ERR_INVALID_ARG;
    if (r->r.physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_UNSUPPORTED;
    if (npts < 2) { femmcore::set_last_error("contour needs >= 2 points"); return FEMM_ERR_INVALID_ARG; }
    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const double lc   = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const double depth = d ? d->depth : 1.0;
    const double depth_m = depth * lc;
    const bool axi    = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    const double freq = r->r.frequency;
    const int NumPlotPoints = samples_per_seg > 0 ? samples_per_seg : 400;
    constexpr double MU0 = 4.0 * 3.141592653589793 * 1e-7;
    constexpr double PI_ = 3.141592653589793;

    /* Contour length pre-compute (problem units → m). */
    double contour_len = 0.0;
    double axi_sweep   = 0.0;
    for (size_t k = 0; k + 1 < npts; ++k) {
        double dx = contour_xy[2*(k+1)] - contour_xy[2*k];
        double dy = contour_xy[2*(k+1)+1] - contour_xy[2*k+1];
        double len = std::sqrt(dx*dx + dy*dy);
        contour_len += len;
        /* Pappus: axisymmetric "area" under the segment — ∮ 2π r dl scaled. */
        double rsum = contour_xy[2*k] + contour_xy[2*(k+1)];
        axi_sweep += PI_ * rsum * len;
    }
    contour_len *= lc;
    axi_sweep   *= lc * lc;

    /* Zero outputs we might touch (up to 4). */
    for (int i = 0; i < 4; ++i) { out_z[i].re = 0; out_z[i].im = 0; }

    auto writeZ = [&](int i, double re, double im) {
        out_z[i].re += re; out_z[i].im += im;
    };

    int count = 0;

    if (type == FEMM_MAG_LINE_B_DOT_N) {
        double A0 = 0, Bx, By, Hx, Hy, A1 = 0;
        bool ok0 = mag_sample_ABH(r, d, contour_xy[0], contour_xy[1],
                                  A0, Bx, By, Hx, Hy);
        bool ok1 = mag_sample_ABH(r, d,
                                  contour_xy[2*(npts-1)], contour_xy[2*(npts-1)+1],
                                  A1, Bx, By, Hx, Hy);
        if (!ok0 || !ok1) { femmcore::set_last_error("contour endpoint outside mesh"); return FEMM_ERR_INVALID_ARG; }
        if (!axi) {
            writeZ(0, (A0 - A1) * depth_m, 0);
            if (contour_len != 0) writeZ(1, (A0 - A1) / contour_len, 0);
        } else {
            writeZ(0, A1 - A0, 0);
            if (axi_sweep != 0) writeZ(1, (A1 - A0) / axi_sweep, 0);
        }
        count = 2;
    }
    else if (type == FEMM_MAG_LINE_H_DOT_T) {
        /* ∮ H · t dl — accumulate interpolated H dotted with segment tangent. */
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double tx = dxr / slen, ty = dyr / slen;
            double nx = -ty, ny = tx;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr + nx * 1e-6;
                double py = y0 + u * dyr + ny * 1e-6;
                double A, Bx, By, Hx, Hy;
                if (!mag_sample_ABH(r, d, px, py, A, Bx, By, Hx, Hy)) continue;
                double Ht = tx * Hx + ty * Hy;
                writeZ(0, Ht * dz * lc, 0);
            }
        }
        if (contour_len != 0) writeZ(1, out_z[0].re / contour_len, 0);
        count = 2;
    }
    else if (type == FEMM_MAG_LINE_LENGTH) {
        writeZ(0, contour_len, axi ? axi_sweep : contour_len * depth_m);
        count = 1;
    }
    else if (type == FEMM_MAG_LINE_STRESS_FORCE) {
        /* Maxwell stress tensor, DC only for v1. Harmonic returns [0..3]. */
        if (freq != 0.0) { femmcore::set_last_error("harmonic stress integral not yet wired"); return FEMM_ERR_UNSUPPORTED; }
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double tx = dxr / slen, ty = dyr / slen;
            double nx = -ty, ny = tx;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr + nx * 1e-6;
                double py = y0 + u * dyr + ny * 1e-6;
                double A, Bx, By, Hx, Hy;
                if (!mag_sample_ABH(r, d, px, py, A, Bx, By, Hx, Hy)) continue;
                double Hn = nx * Hx + ny * Hy;
                double Bn = nx * Bx + ny * By;
                double BH = Bx * Hx + By * Hy;
                double dF1 = Hx * Bn + Bx * Hn - nx * BH;
                double dF2 = Hy * Bn + By * Hn - ny * BH;
                double dza = dz * lc;
                if (axi) { dza *= 2.0 * PI_ * px * lc; dF1 = 0; }
                else     { dza *= depth_m; }
                writeZ(0, dF1 * dza * 0.5, 0);
                writeZ(1, dF2 * dza * 0.5, 0);
            }
        }
        count = 2;
    }
    else if (type == FEMM_MAG_LINE_STRESS_TORQ) {
        if (freq != 0.0) { femmcore::set_last_error("harmonic stress torque not yet wired"); return FEMM_ERR_UNSUPPORTED; }
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double tx = dxr / slen, ty = dyr / slen;
            double nx = -ty, ny = tx;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr + nx * 1e-6;
                double py = y0 + u * dyr + ny * 1e-6;
                double A, Bx, By, Hx, Hy;
                if (!mag_sample_ABH(r, d, px, py, A, Bx, By, Hx, Hy)) continue;
                double Hn = nx * Hx + ny * Hy;
                double Bn = nx * Bx + ny * By;
                double BH = Bx * Hx + By * Hy;
                double dF1 = Hx * Bn + Bx * Hn - nx * BH;
                double dF2 = Hy * Bn + By * Hn - ny * BH;
                double dT  = px * dF2 - dF1 * py;
                double dza = dz * lc * lc;
                writeZ(0, dT * dza * depth_m * 0.5, 0);
            }
        }
        count = 1;
    }
    else if (type == FEMM_MAG_LINE_B_DOT_N_SQ) {
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double tx = dxr / slen, ty = dyr / slen;
            double nx = -ty, ny = tx;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr + nx * 1e-6;
                double py = y0 + u * dyr + ny * 1e-6;
                double A, Bx, By, Hx, Hy;
                if (!mag_sample_ABH(r, d, px, py, A, Bx, By, Hx, Hy)) continue;
                double Bn = nx * Bx + ny * By;
                writeZ(0, Bn * Bn * dz * lc, 0);
            }
        }
        if (contour_len != 0) writeZ(1, out_z[0].re / contour_len, 0);
        count = 2;
    }
    else {
        femmcore::set_last_error("unknown line integral type");
        return FEMM_ERR_INVALID_ARG;
    }

    /* Avoid unused-warning on MU0 in case the compiler folds branches. */
    (void)MU0;
    if (out_count) *out_count = count;
    return FEMM_OK;
}

/* Planar quadrature: ∫ u·v dA over a triangle of area a, u,v per-node. */
static inline double plnint(double a, const double u[3], const double v[3]) {
    double z[3];
    z[0] = 2.0 * u[0] + u[1] + u[2];
    z[1] = u[0] + 2.0 * u[1] + u[2];
    z[2] = u[0] + u[1] + 2.0 * u[2];
    double x = v[0] * z[0] + v[1] * z[1] + v[2] * z[2];
    return a * x / 12.0;
}

/* Axisymmetric quadrature: ∫ u·v · 2π r dA with nodal r[]. */
static inline double axiint(double a, const double u[3], const double v[3],
                            const double r[3]) {
    double M00 = 6*r[0] + 2*r[1] + 2*r[2];
    double M01 = 2*r[0] + 2*r[1] + 1*r[2];
    double M02 = 2*r[0] + 1*r[1] + 2*r[2];
    double M11 = 2*r[0] + 6*r[1] + 2*r[2];
    double M12 = 1*r[0] + 2*r[1] + 2*r[2];
    double M22 = 2*r[0] + 2*r[1] + 6*r[2];
    double z0 = M00 * u[0] + M01 * u[1] + M02 * u[2];
    double z1 = M01 * u[0] + M11 * u[1] + M12 * u[2];
    double z2 = M02 * u[0] + M12 * u[1] + M22 * u[2];
    double x = v[0] * z0 + v[1] * z1 + v[2] * z2;
    return 3.141592653589793 * a * x / 30.0;
}

femm_status_t femm_result_mag_block_integral(const femm_result_t* r,
                                             const femm_doc_t* doc_c,
                                             int32_t type,
                                             const int32_t* label_mask,
                                             size_t num_labels,
                                             femm_complex_t* out_z) {
    if (!r || !out_z) return FEMM_ERR_INVALID_ARG;
    if (r->r.physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_UNSUPPORTED;
    if (r->r.frequency != 0.0) {
        femmcore::set_last_error("AC block integrals not yet supported");
        return FEMM_ERR_UNSUPPORTED;
    }
    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const double lc   = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const double lc2  = lc * lc;
    const double depth = d ? d->depth : 1.0;
    const bool axi    = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    constexpr double MU0 = 4.0 * 3.141592653589793 * 1e-7;
    constexpr double PI_ = 3.141592653589793;

    out_z[0].re = 0; out_z[0].im = 0;

    const size_t M = r->r.element_labels.size();
    for (size_t e = 0; e < M; ++e) {
        int lbl = r->r.element_labels[e]; /* 0-based */
        if (label_mask) {
            if (lbl < 0 || (size_t)lbl >= num_labels) continue;
            if (!label_mask[lbl]) continue;
        }
        int ia = r->r.elements_ijk[3*e + 0];
        int ib = r->r.elements_ijk[3*e + 1];
        int ic = r->r.elements_ijk[3*e + 2];
        double xa = r->r.x[ia], ya = r->r.y[ia];
        double xb = r->r.x[ib], yb = r->r.y[ib];
        double xc = r->r.x[ic], yc = r->r.y[ic];
        double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
        double elArea = 0.5 * std::fabs(twoA);
        double a = elArea * lc2;
        double rN[3] = { xa * lc, xb * lc, xc * lc };
        double R = (rN[0] + rN[1] + rN[2]) / 3.0;
        double vA[3] = { r->r.V[ia].real(), r->r.V[ib].real(), r->r.V[ic].real() };
        double Bx, By;
        if (axi) {
            /* Axi stored quantity is A·r·2π·c (flux-like); use quadratic shape. */
            axi_element_B(xa, ya, xb, yb, xc, yc, vA[0], vA[1], vA[2], lc, Bx, By);
        } else {
            double gx, gy;
            tri_grad(xa, ya, xb, yb, xc, yc, vA[0], vA[1], vA[2], gx, gy);
            gx /= lc; gy /= lc;
            Bx =  gy;
            By = -gx;
        }

        /* Material-derived quantities. */
        double mux = 1, muy = 1, Jsrc = 0, Hc = 0, theta_m = 0, sig_MS = 0;
        if (d && lbl >= 0 && (size_t)lbl < d->labels.size()) {
            int blk = d->labels[lbl].block_idx;
            if (blk > 0 && (size_t)blk <= d->mag_materials.size()) {
                const auto& mat = d->mag_materials[blk - 1];
                mux = mat.mu_x == 0 ? 1 : mat.mu_x;
                muy = mat.mu_y == 0 ? 1 : mat.mu_y;
                Jsrc = mat.J_src.real() * 1e6;  /* MA/m² → A/m² */
                Hc   = mat.H_c;
                sig_MS = mat.c_duct * 1e6;      /* MS/m → S/m */
            }
            theta_m = d->labels[lbl].mag_dir;
        }

        /* Circuit contribution to J per node, mirroring Windows GetJA
         * (FemmviewDoc.cpp:2944-2965). For case==1 (specified current) the
         * contribution is the uniform circuit J (MA/m² stored in .ans tail),
         * added to every node. For case==0 (specified voltage) the axi path
         * would divide by r; not implemented yet. */
        double Jcirc[3] = { 0, 0, 0 };
        if (lbl >= 0 && (size_t)lbl < r->r.label_circuit_case.size()) {
            int cs = r->r.label_circuit_case[lbl];
            double val = r->r.label_circuit_value[lbl];  /* MA/m² for case 1 */
            if (cs == 1) {
                double j = val * 1e6;  /* MA/m² → A/m² */
                Jcirc[0] = Jcirc[1] = Jcirc[2] = j;
            }
        }
        double Jtot[3] = { Jsrc + Jcirc[0], Jsrc + Jcirc[1], Jsrc + Jcirc[2] };
        double Javg = (Jtot[0] + Jtot[1] + Jtot[2]) / 3.0;

        /* Volume factor for integrals that need it. */
        double vol = axi ? (a * 2.0 * PI_ * R) : (a * depth);

        /* In axi mode, vA[] holds the flux-like stored quantity
         * (A_raw · r · 2π · c from fkn/prob3big.cpp:701-702). Convert
         * to raw A per node for integrals that expect A: same rule as
         * Windows FemmviewDoc::GetJA (FemmviewDoc.cpp:2914-2920). */
        double A_raw[3];
        if (axi) {
            for (int k = 0; k < 3; ++k) {
                A_raw[k] = (rN[k] > 1e-8) ? vA[k] / (2.0 * PI_ * rN[k]) : 0.0;
            }
        } else {
            A_raw[0] = vA[0]; A_raw[1] = vA[1]; A_raw[2] = vA[2];
        }

        switch (type) {
        case FEMM_MAG_BLOCK_AJ: {
            if (axi) out_z[0].re += axiint(a, A_raw, Jtot, rN);
            else     out_z[0].re += plnint(a, A_raw, Jtot) * depth;
            break;
        }
        case FEMM_MAG_BLOCK_A: {
            double U[3] = {1, 1, 1};
            if (axi) out_z[0].re += axiint(a, U, A_raw, rN);
            else     out_z[0].re += depth * a * (A_raw[0] + A_raw[1] + A_raw[2]) / 3.0;
            break;
        }
        case FEMM_MAG_BLOCK_ENERGY: {
            /* ½ μ0 (μx·Hx² + μy·Hy²) with PM correction (second-quadrant). */
            double Hx = Bx / (MU0 * mux);
            double Hy = By / (MU0 * muy);
            if (Hc != 0) {
                double cosT = std::cos(PI_ * theta_m / 180.0);
                double sinT = std::sin(PI_ * theta_m / 180.0);
                Hx -= Hc * cosT;
                Hy -= Hc * sinT;
            }
            double eDens = 0.5 * MU0 * (mux * Hx * Hx + muy * Hy * Hy);
            out_z[0].re += vol * eDens;
            break;
        }
        case FEMM_MAG_BLOCK_RESISTIVE: {
            /* DC: J_src²/σ · volume — only meaningful where σ>0 and Jsrc≠0. */
            if (sig_MS > 0 && Jsrc != 0) {
                out_z[0].re += vol * (Jsrc * Jsrc) / sig_MS;
            }
            break;
        }
        case FEMM_MAG_BLOCK_AREA: {
            out_z[0].re += a;
            break;
        }
        case FEMM_MAG_BLOCK_CURRENT: {
            /* Windows: z += a * J (FemmviewDoc.cpp:3278-3280), where J is
             * the area-average including circuit contribution. */
            out_z[0].re += a * Javg;
            break;
        }
        case FEMM_MAG_BLOCK_BX: {
            out_z[0].re += vol * Bx;
            break;
        }
        case FEMM_MAG_BLOCK_BY: {
            out_z[0].re += vol * By;
            break;
        }
        case FEMM_MAG_BLOCK_VOLUME: {
            out_z[0].re += vol;
            break;
        }
        default:
            femmcore::set_last_error("unknown block integral type");
            return FEMM_ERR_INVALID_ARG;
        }
    }
    (void)depth;
    return FEMM_OK;
}

femm_status_t femm_result_point_values(const femm_result_t* r,
                                       const femm_doc_t* doc_c,
                                       double x, double y,
                                       double* scalar_out, double* vec_out) {
    if (!r) return FEMM_ERR_INVALID_ARG;
    int32_t e = femm_result_locate(r, x, y);
    if (e < 0) return FEMM_ERR_INVALID_ARG;

    int a = r->r.elements_ijk[3*e + 0];
    int b = r->r.elements_ijk[3*e + 1];
    int c = r->r.elements_ijk[3*e + 2];
    double xa = r->r.x[a], ya = r->r.y[a];
    double xb = r->r.x[b], yb = r->r.y[b];
    double xc = r->r.x[c], yc = r->r.y[c];
    double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
    if (twoA == 0.0) return FEMM_ERR_INVALID_ARG;
    double la = ((xb - x) * (yc - y) - (xc - x) * (yb - y)) / twoA;
    double lb = ((xc - x) * (ya - y) - (xa - x) * (yc - y)) / twoA;
    double lc = 1.0 - la - lb;
    double va = r->r.V[a].real();
    double vb = r->r.V[b].real();
    double vc = r->r.V[c].real();
    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const bool axi = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    if (scalar_out) {
        if (r->r.physics == FEMM_PHYSICS_MAGNETICS && axi)
            *scalar_out = axi_interp_A(xa, ya, xb, yb, xc, yc, va, vb, vc, x, y);
        else
            *scalar_out = la * va + lb * vb + lc * vc;
    }
    if (vec_out) {
        const double lc_m = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
        if (r->r.physics == FEMM_PHYSICS_MAGNETICS && axi) {
            double Br, Bz;
            axi_element_B(xa, ya, xb, yb, xc, yc, va, vb, vc, lc_m, Br, Bz);
            vec_out[0] = Br; vec_out[1] = Bz;
        } else {
            double gx, gy;
            tri_grad(xa, ya, xb, yb, xc, yc, va, vb, vc, gx, gy);
            gx /= lc_m; gy /= lc_m;
            switch (r->r.physics) {
                case FEMM_PHYSICS_MAGNETICS:
                    vec_out[0] =  gy; vec_out[1] = -gx; break;
                case FEMM_PHYSICS_ELECTROSTATICS:
                case FEMM_PHYSICS_CURRENT:
                    vec_out[0] = -gx; vec_out[1] = -gy; break;
                case FEMM_PHYSICS_HEAT: {
                    double kx = 1, ky = 1;
                    if (d) material_anisotropy(*d, r->r.element_labels[e], kx, ky);
                    vec_out[0] = -kx * gx; vec_out[1] = -ky * gy;
                    break;
                }
            }
        }
    }
    return FEMM_OK;
}

/* Sample scalar V and its gradient at (x,y). Returns element index or -1.
 * Gradient is in per-problem-unit space; callers must divide by LengthConv
 * to convert to per-meter. */
static int32_t sample_scalar(const femm_result_t* r,
                             double x, double y,
                             double& V,
                             double& gx, double& gy) {
    int32_t e = femm_result_locate(r, x, y);
    if (e < 0) return -1;
    int ia = r->r.elements_ijk[3*e + 0];
    int ib = r->r.elements_ijk[3*e + 1];
    int ic = r->r.elements_ijk[3*e + 2];
    double xa = r->r.x[ia], ya = r->r.y[ia];
    double xb = r->r.x[ib], yb = r->r.y[ib];
    double xc = r->r.x[ic], yc = r->r.y[ic];
    double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
    if (twoA == 0.0) return -1;
    double la = ((xb - x) * (yc - y) - (xc - x) * (yb - y)) / twoA;
    double lb = ((xc - x) * (ya - y) - (xa - x) * (yc - y)) / twoA;
    double lam_c = 1.0 - la - lb;
    double va = r->r.V[ia].real();
    double vb = r->r.V[ib].real();
    double vc = r->r.V[ic].real();
    V = la * va + lb * vb + lam_c * vc;
    tri_grad(xa, ya, xb, yb, xc, yc, va, vb, vc, gx, gy);
    return e;
}

/* Generic scalar line integral: supports ΔΦ (endpoints), flux ∫F·n dl, length,
 * and average-along-contour. The flux_coeff is (σ, ε₀·εr, k) anisotropic per
 * element and computed from the doc's material for the current physics. */
static femm_status_t scalar_line_integral(const femm_result_t* r,
                                          const femm_doc_t* doc_c,
                                          int32_t type,
                                          const double* contour_xy,
                                          size_t npts,
                                          int32_t samples_per_seg,
                                          femm_complex_t* out_z,
                                          int32_t* out_count,
                                          femm_physics_t wanted_physics) {
    if (!r || !contour_xy || !out_z) return FEMM_ERR_INVALID_ARG;
    if (r->r.physics != wanted_physics) return FEMM_ERR_UNSUPPORTED;
    if (npts < 2) { femmcore::set_last_error("contour needs >= 2 points"); return FEMM_ERR_INVALID_ARG; }

    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const double lc   = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const double depth = d ? d->depth : 1.0;
    const bool   axi   = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    const int NumPlotPoints = samples_per_seg > 0 ? samples_per_seg : 400;
    constexpr double EPS0 = 8.854187817e-12;
    constexpr double PI_  = 3.141592653589793;

    double contour_len = 0, axi_sweep = 0;
    for (size_t k = 0; k + 1 < npts; ++k) {
        double dx = contour_xy[2*(k+1)] - contour_xy[2*k];
        double dy = contour_xy[2*(k+1)+1] - contour_xy[2*k+1];
        double len = std::sqrt(dx*dx + dy*dy);
        contour_len += len;
        double rsum = contour_xy[2*k] + contour_xy[2*(k+1)];
        axi_sweep += PI_ * rsum * len;
    }
    contour_len *= lc;
    axi_sweep   *= lc * lc;

    /* Max slots filled per physics: ES returns up to 2, heat up to 1, current
     * up to 2. Callers must pass a buffer large enough for the requested type.
     * See per-physics branches below for the slot count. */
    out_z[0].re = 0; out_z[0].im = 0;

    /* Voltage/Temperature drop between endpoints (type 0 or the heat avg-T). */
    auto value_drop = [&](int slot) -> femm_status_t {
        double V0 = 0, gx, gy;
        double V1 = 0;
        if (sample_scalar(r, contour_xy[0], contour_xy[1], V0, gx, gy) < 0 ||
            sample_scalar(r, contour_xy[2*(npts-1)], contour_xy[2*(npts-1)+1],
                          V1, gx, gy) < 0) {
            femmcore::set_last_error("contour endpoint outside mesh");
            return FEMM_ERR_INVALID_ARG;
        }
        out_z[slot].re = V0 - V1;
        return FEMM_OK;
    };

    /* Accumulate ∫ (kx·gx, ky·gy) · n dl — where grad comes from element,
     * and (kx,ky) depends on physics & material (anisotropic). */
    auto flux_through = [&](int slot) -> femm_status_t {
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double tx = dxr / slen, ty = dyr / slen;
            double nx = -ty, ny = tx;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr + nx * 1e-6;
                double py = y0 + u * dyr + ny * 1e-6;
                double V, gx, gy;
                int32_t e = sample_scalar(r, px, py, V, gx, gy);
                if (e < 0) continue;
                /* Convert per-problem-unit gradient to per-meter. */
                gx /= lc; gy /= lc;
                /* Flux vector = -(kx·gx, ky·gy); coefficients per physics. */
                double kx = 1, ky = 1;
                if (d) material_anisotropy(*d, r->r.element_labels[e], kx, ky);
                double Fx = 0, Fy = 0;
                switch (wanted_physics) {
                    case FEMM_PHYSICS_ELECTROSTATICS:
                        Fx = -EPS0 * kx * gx;
                        Fy = -EPS0 * ky * gy;
                        break;
                    case FEMM_PHYSICS_HEAT:
                        Fx = -kx * gx;
                        Fy = -ky * gy;
                        break;
                    case FEMM_PHYSICS_CURRENT:
                        /* σ stored as MS/m in the material. */
                        Fx = -(kx * 1e6) * gx;
                        Fy = -(ky * 1e6) * gy;
                        break;
                    default: break;
                }
                double Fn = nx * Fx + ny * Fy;
                double dza = dz * lc;
                if (axi) dza *= 2.0 * PI_ * px * lc;
                else     dza *= depth;
                out_z[slot].re += Fn * dza;
            }
        }
        return FEMM_OK;
    };

    /* Average of the scalar field along the contour. */
    auto avg_scalar = [&](int slot) -> femm_status_t {
        double acc = 0, used = 0;
        for (size_t k = 1; k < npts; ++k) {
            double x0 = contour_xy[2*(k-1)], y0 = contour_xy[2*(k-1)+1];
            double x1 = contour_xy[2*k],     y1 = contour_xy[2*k+1];
            double dxr = x1 - x0, dyr = y1 - y0;
            double slen = std::sqrt(dxr*dxr + dyr*dyr);
            if (slen == 0) continue;
            double dz = slen / (double)NumPlotPoints;
            for (int i = 0; i < NumPlotPoints; ++i) {
                double u = ((double)i + 0.5) / (double)NumPlotPoints;
                double px = x0 + u * dxr;
                double py = y0 + u * dyr;
                double V, gx, gy;
                if (sample_scalar(r, px, py, V, gx, gy) < 0) continue;
                acc  += V * dz * lc;
                used += dz * lc;
            }
        }
        if (used > 0) out_z[slot].re = acc / used;
        return FEMM_OK;
    };

    int count = 0;
    femm_status_t st = FEMM_OK;

    if (wanted_physics == FEMM_PHYSICS_ELECTROSTATICS) {
        if (type == FEMM_ES_LINE_E_DOT_T) {
            out_z[1].re = 0; out_z[1].im = 0;
            if ((st = value_drop(0)) != FEMM_OK) return st;
            if (contour_len != 0) out_z[1].re = out_z[0].re / contour_len;
            count = 2;
        } else if (type == FEMM_ES_LINE_D_DOT_N) {
            out_z[1].re = 0; out_z[1].im = 0;
            if ((st = flux_through(0)) != FEMM_OK) return st;
            if (contour_len != 0) out_z[1].re = out_z[0].re / (axi ? axi_sweep : (contour_len * depth));
            count = 2;
        } else if (type == FEMM_ES_LINE_LENGTH) {
            out_z[0].re = contour_len;
            out_z[0].im = axi ? axi_sweep : contour_len * depth;
            count = 1;
        } else { femmcore::set_last_error("unknown ES line integral"); return FEMM_ERR_INVALID_ARG; }
    }
    else if (wanted_physics == FEMM_PHYSICS_HEAT) {
        if (type == FEMM_HEAT_LINE_TEMP_DROP) {
            if ((st = value_drop(0)) != FEMM_OK) return st;
            count = 1;
        } else if (type == FEMM_HEAT_LINE_FLUX) {
            if ((st = flux_through(0)) != FEMM_OK) return st;
            count = 1;
        } else if (type == FEMM_HEAT_LINE_LENGTH) {
            out_z[0].re = contour_len;
            out_z[0].im = axi ? axi_sweep : contour_len * depth;
            count = 1;
        } else if (type == FEMM_HEAT_LINE_AVG_T) {
            if ((st = avg_scalar(0)) != FEMM_OK) return st;
            count = 1;
        } else { femmcore::set_last_error("unknown heat line integral"); return FEMM_ERR_INVALID_ARG; }
    }
    else if (wanted_physics == FEMM_PHYSICS_CURRENT) {
        if (type == FEMM_CURR_LINE_VOLT_DROP) {
            out_z[1].re = 0; out_z[1].im = 0;
            if ((st = value_drop(0)) != FEMM_OK) return st;
            if (contour_len != 0) out_z[1].re = out_z[0].re / contour_len;
            count = 2;
        } else if (type == FEMM_CURR_LINE_CURRENT) {
            if ((st = flux_through(0)) != FEMM_OK) return st;
            count = 1;
        } else if (type == FEMM_CURR_LINE_LENGTH) {
            out_z[0].re = contour_len;
            out_z[0].im = axi ? axi_sweep : contour_len * depth;
            count = 1;
        } else { femmcore::set_last_error("unknown current line integral"); return FEMM_ERR_INVALID_ARG; }
    }
    else return FEMM_ERR_UNSUPPORTED;

    if (out_count) *out_count = count;
    return FEMM_OK;
}

/* Shared block-integral helper for scalar physics (ES / heat / current). */
static femm_status_t scalar_block_integral(const femm_result_t* r,
                                           const femm_doc_t* doc_c,
                                           int32_t type,
                                           const int32_t* label_mask,
                                           size_t num_labels,
                                           femm_complex_t* out_z,
                                           femm_physics_t wanted_physics) {
    if (!r || !out_z) return FEMM_ERR_INVALID_ARG;
    if (r->r.physics != wanted_physics) return FEMM_ERR_UNSUPPORTED;
    auto* d = reinterpret_cast<const femmcore::Document*>(doc_c);
    const double lc   = length_conv(d ? d->length_units : FEMM_UNITS_MILLIMETERS);
    const double lc2  = lc * lc;
    const double depth = d ? d->depth : 1.0;
    const bool   axi   = d && d->problem_type == FEMM_PROBLEM_AXISYMMETRIC;
    constexpr double EPS0 = 8.854187817e-12;
    constexpr double PI_  = 3.141592653589793;

    out_z[0].re = 0; out_z[0].im = 0;

    const size_t M = r->r.element_labels.size();
    for (size_t e = 0; e < M; ++e) {
        int lbl = r->r.element_labels[e]; /* 0-based */
        if (label_mask) {
            if (lbl < 0 || (size_t)lbl >= num_labels) continue;
            if (!label_mask[lbl]) continue;
        }
        int ia = r->r.elements_ijk[3*e + 0];
        int ib = r->r.elements_ijk[3*e + 1];
        int ic = r->r.elements_ijk[3*e + 2];
        double xa = r->r.x[ia], ya = r->r.y[ia];
        double xb = r->r.x[ib], yb = r->r.y[ib];
        double xc = r->r.x[ic], yc = r->r.y[ic];
        double twoA = (xb - xa) * (yc - ya) - (xc - xa) * (yb - ya);
        double elArea = 0.5 * std::fabs(twoA);
        double a = elArea * lc2;
        double rN[3] = { xa * lc, xb * lc, xc * lc };
        double R = (rN[0] + rN[1] + rN[2]) / 3.0;
        double vN[3] = { r->r.V[ia].real(), r->r.V[ib].real(), r->r.V[ic].real() };
        double gx, gy;
        tri_grad(xa, ya, xb, yb, xc, yc, vN[0], vN[1], vN[2], gx, gy);
        /* Convert per-problem-unit gradient to per-meter. */
        gx /= lc; gy /= lc;

        double kx = 1, ky = 1;
        if (d) material_anisotropy(*d, lbl, kx, ky);

        double vol = axi ? (a * 2.0 * PI_ * R) : (a * depth);

        if (wanted_physics == FEMM_PHYSICS_ELECTROSTATICS) {
            /* E = -grad(V). */
            double Ex = -gx, Ey = -gy;
            switch (type) {
                case FEMM_ES_BLOCK_ENERGY: {
                    double eDens = 0.5 * EPS0 * (kx * Ex * Ex + ky * Ey * Ey);
                    out_z[0].re += vol * eDens;
                    break;
                }
                case FEMM_ES_BLOCK_AREA:   out_z[0].re += a;   break;
                case FEMM_ES_BLOCK_VOLUME: out_z[0].re += vol; break;
                case FEMM_ES_BLOCK_INT_V: {
                    double U[3] = {1, 1, 1};
                    if (axi) out_z[0].re += axiint(a, U, vN, rN);
                    else     out_z[0].re += depth * a * (vN[0] + vN[1] + vN[2]) / 3.0;
                    break;
                }
                case FEMM_ES_BLOCK_INT_E2: {
                    out_z[0].re += vol * (Ex * Ex + Ey * Ey);
                    break;
                }
                default: femmcore::set_last_error("unknown ES block type"); return FEMM_ERR_INVALID_ARG;
            }
        }
        else if (wanted_physics == FEMM_PHYSICS_HEAT) {
            switch (type) {
                case FEMM_HEAT_BLOCK_INT_T: {
                    double U[3] = {1, 1, 1};
                    if (axi) out_z[0].re += axiint(a, U, vN, rN);
                    else     out_z[0].re += depth * a * (vN[0] + vN[1] + vN[2]) / 3.0;
                    break;
                }
                case FEMM_HEAT_BLOCK_AREA:   out_z[0].re += a;   break;
                case FEMM_HEAT_BLOCK_VOLUME: out_z[0].re += vol; break;
                default: femmcore::set_last_error("unknown heat block type"); return FEMM_ERR_INVALID_ARG;
            }
        }
        else if (wanted_physics == FEMM_PHYSICS_CURRENT) {
            /* E = -grad(V); σ stored as MS/m → multiply by 1e6. */
            double Ex = -gx, Ey = -gy;
            double sigx = kx * 1e6, sigy = ky * 1e6;
            switch (type) {
                case FEMM_CURR_BLOCK_POWER_REAL: {
                    double pDens = sigx * Ex * Ex + sigy * Ey * Ey;
                    out_z[0].re += vol * pDens;
                    break;
                }
                case FEMM_CURR_BLOCK_AREA:   out_z[0].re += a;   break;
                case FEMM_CURR_BLOCK_VOLUME: out_z[0].re += vol; break;
                case FEMM_CURR_BLOCK_INT_V: {
                    double U[3] = {1, 1, 1};
                    if (axi) out_z[0].re += axiint(a, U, vN, rN);
                    else     out_z[0].re += depth * a * (vN[0] + vN[1] + vN[2]) / 3.0;
                    break;
                }
                default: femmcore::set_last_error("unknown current block type"); return FEMM_ERR_INVALID_ARG;
            }
        }
        else return FEMM_ERR_UNSUPPORTED;
    }
    return FEMM_OK;
}

femm_status_t femm_result_es_line_integral(const femm_result_t* r,
                                           const femm_doc_t* doc_c,
                                           int32_t type,
                                           const double* contour_xy,
                                           size_t npts,
                                           int32_t samples_per_seg,
                                           femm_complex_t* out_z,
                                           int32_t* out_count) {
    return scalar_line_integral(r, doc_c, type, contour_xy, npts, samples_per_seg,
                                out_z, out_count, FEMM_PHYSICS_ELECTROSTATICS);
}
femm_status_t femm_result_es_block_integral(const femm_result_t* r,
                                            const femm_doc_t* doc_c,
                                            int32_t type,
                                            const int32_t* label_mask,
                                            size_t num_labels,
                                            femm_complex_t* out_z) {
    return scalar_block_integral(r, doc_c, type, label_mask, num_labels, out_z,
                                 FEMM_PHYSICS_ELECTROSTATICS);
}
femm_status_t femm_result_heat_line_integral(const femm_result_t* r,
                                             const femm_doc_t* doc_c,
                                             int32_t type,
                                             const double* contour_xy,
                                             size_t npts,
                                             int32_t samples_per_seg,
                                             femm_complex_t* out_z,
                                             int32_t* out_count) {
    return scalar_line_integral(r, doc_c, type, contour_xy, npts, samples_per_seg,
                                out_z, out_count, FEMM_PHYSICS_HEAT);
}
femm_status_t femm_result_heat_block_integral(const femm_result_t* r,
                                              const femm_doc_t* doc_c,
                                              int32_t type,
                                              const int32_t* label_mask,
                                              size_t num_labels,
                                              femm_complex_t* out_z) {
    return scalar_block_integral(r, doc_c, type, label_mask, num_labels, out_z,
                                 FEMM_PHYSICS_HEAT);
}
femm_status_t femm_result_curr_line_integral(const femm_result_t* r,
                                             const femm_doc_t* doc_c,
                                             int32_t type,
                                             const double* contour_xy,
                                             size_t npts,
                                             int32_t samples_per_seg,
                                             femm_complex_t* out_z,
                                             int32_t* out_count) {
    return scalar_line_integral(r, doc_c, type, contour_xy, npts, samples_per_seg,
                                out_z, out_count, FEMM_PHYSICS_CURRENT);
}
femm_status_t femm_result_curr_block_integral(const femm_result_t* r,
                                              const femm_doc_t* doc_c,
                                              int32_t type,
                                              const int32_t* label_mask,
                                              size_t num_labels,
                                              femm_complex_t* out_z) {
    return scalar_block_integral(r, doc_c, type, label_mask, num_labels, out_z,
                                 FEMM_PHYSICS_CURRENT);
}

} // extern "C"
