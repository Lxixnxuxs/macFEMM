// femm_doc.hpp — Internal C++ document model used behind the C ABI.
//
// Keep this header-only-ish (inline data only; methods live in the .cpp
// files). Intentionally minimal: enough to round-trip .fem/.fee/.feh/.fec
// and drive triangle + the solvers. Rich behavior (geometry edits, integrals,
// Lua) arrives in later phases.

#pragma once

#include <array>
#include <complex>
#include <string>
#include <variant>
#include <vector>

#include "femm_c.h"

namespace femmcore {

using Complex = std::complex<double>;

/* --- Geometry primitives --------------------------------------------- */
struct Node {
    double x = 0, y = 0;
    int group = 0;
    int bdry_idx = 0;   // 0 = none, else 1-based index into point_props
    int in_conductor = 0; // 0 = none, else 1-based index into conductors
};

struct Segment {
    int n0 = 0, n1 = 0;
    double max_side = -1;
    int bdry_idx = 0;   // 1-based
    int hidden = 0;
    int group = 0;
    int in_conductor = 0;
};

struct Arc {
    int n0 = 0, n1 = 0;
    double arc_deg = 0;
    double max_side_deg = 1.0;
    int bdry_idx = 0;
    int hidden = 0;
    int group = 0;
    int in_conductor = 0;
};

struct BlockLabel {
    double x = 0, y = 0;
    int block_idx = 0;   // 1-based into block_props
    double max_area = -1;
    int circuit_idx = 0; // 1-based; magnetics only
    double mag_dir = 0;
    int group = 0;
    int turns = 1;
    int is_external = 0;
    int is_default = 0;
    std::string mag_dir_fctn;
};

/* --- Physics-specific property lists --------------------------------- */
namespace mag {
struct Material {
    std::string name;
    double mu_x = 1, mu_y = 1;
    double H_c = 0;
    double theta_m = 0;
    Complex J_src{0, 0};
    double c_duct = 0;
    double lam_d = 0;
    double theta_hn = 0, theta_hx = 0, theta_hy = 0;
    int lam_type = 0;
    double lam_fill = 1;
    int n_strands = 0;
    double wire_d = 0;
    std::vector<std::pair<double, double>> bh; // (B, H) pairs
};
struct Boundary {
    std::string name;
    int fmt = 0;
    double A0 = 0, A1 = 0, A2 = 0, phi = 0;
    Complex c0{0, 0}, c1{0, 0};
    double mu = 0, sig = 0;
    double inner_angle = 0, outer_angle = 0;
};
struct PointProp {
    std::string name;
    Complex Jp{0, 0};
    Complex Ap{0, 0};
};
struct Circuit {
    std::string name;
    Complex amps{0, 0};
    int circ_type = 0;
};
} // namespace mag

namespace es {
struct Material { std::string name; double ex = 1, ey = 1, qv = 0; };
struct Boundary { std::string name; int fmt = 0; double V = 0, qs = 0, c0 = 0, c1 = 0; };
struct PointProp { std::string name; double V = 0, qp = 0; };
struct Conductor { std::string name; double V = 0, q = 0; int circ_type = 0; };
} // namespace es

namespace heat {
struct Material { std::string name; double Kx = 1, Ky = 1, Kt = 0, qv = 0; };
struct Boundary { std::string name; int fmt = 0;
                  double Tset = 0, qs = 0, beta = 0, h = 0, Tinf = 0, TinfRad = 0; };
struct PointProp { std::string name; double T = 0, qp = 0; };
struct Conductor { std::string name; double T = 0, q = 0; int circ_type = 0; };
} // namespace heat

namespace curr {
struct Material { std::string name; double ox = 1, oy = 1, ex = 1, ey = 1, ltx = 0, lty = 0; };
struct Boundary { std::string name; int fmt = 0; Complex Vs{0,0}, qs{0,0}, c0{0,0}, c1{0,0}; };
struct PointProp { std::string name; Complex Vp{0,0}, qp{0,0}; };
struct Conductor { std::string name; Complex Vc{0,0}, qc{0,0}; int circ_type = 0; };
} // namespace curr

/* --- Document -------------------------------------------------------- */
struct Document {
    femm_physics_t physics = FEMM_PHYSICS_MAGNETICS;

    // Header
    double precision = 1e-8;
    double min_angle = 30.0;
    int    smart_mesh = 1;
    double depth = 1.0;
    femm_length_units_t length_units = FEMM_UNITS_MILLIMETERS;
    femm_problem_type_t problem_type = FEMM_PROBLEM_PLANAR;
    std::string coordinates = "cartesian";
    double ext_ro = 0, ext_ri = 0, ext_zo = 0;
    std::string comment;

    // Magnetics-only
    double frequency = 0.0;
    int    ac_solver = 0;
    int    prev_type = 0;
    std::string prev_soln;

    // Heat-only
    double dT = 0.0;
    // heat also has prev_soln; reuses the magnetics field above

    // Geometry
    std::vector<Node> nodes;
    std::vector<Segment> segments;
    std::vector<Arc> arcs;
    std::vector<BlockLabel> labels;

    // Properties — only one of the four physics' lists is populated
    std::vector<mag::Material> mag_materials;
    std::vector<mag::Boundary> mag_boundaries;
    std::vector<mag::PointProp> mag_pointprops;
    std::vector<mag::Circuit> mag_circuits;

    std::vector<es::Material> es_materials;
    std::vector<es::Boundary> es_boundaries;
    std::vector<es::PointProp> es_pointprops;
    std::vector<es::Conductor> es_conductors;

    std::vector<heat::Material> heat_materials;
    std::vector<heat::Boundary> heat_boundaries;
    std::vector<heat::PointProp> heat_pointprops;
    std::vector<heat::Conductor> heat_conductors;

    std::vector<curr::Material> curr_materials;
    std::vector<curr::Boundary> curr_boundaries;
    std::vector<curr::PointProp> curr_pointprops;
    std::vector<curr::Conductor> curr_conductors;

    // 1-based lookups used when writing rows (returns 0 if not found).
    int lookup_point_idx  (const std::string& n) const;
    int lookup_bdry_idx   (const std::string& n) const;
    int lookup_block_idx  (const std::string& n) const;
    int lookup_conductor_idx(const std::string& n) const;
};

/* --- File format extension per physics -------------------------------- */
const char* file_ext_for(femm_physics_t);
const char* solver_name_for(femm_physics_t); // "belasolve"/"csolve"/"hsolve"/"fknsolve"
const char* result_ext_for(femm_physics_t);  // ".res" / ".res" / ".anh" / ".ans"

/* --- I/O entry points (defined in femm_io.cpp) ------------------------ */
femm_status_t write_document(const Document& d, const std::string& path);
femm_status_t read_document (const std::string& path, Document& out);

/* --- Mesh + subprocess (defined in femm_mesh.cpp) --------------------- */
femm_status_t write_poly(const Document& d, const std::string& fem_path);
femm_status_t run_triangle(const std::string& fem_path, double min_angle);
femm_status_t run_solver(const Document& d, const std::string& fem_path,
                         femm_progress_cb cb, void* user);

/* --- Error helper ---------------------------------------------------- */
void set_last_error(const std::string& msg);

} // namespace femmcore
