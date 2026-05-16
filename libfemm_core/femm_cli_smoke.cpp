// femm_cli_smoke.cpp — Phase A end-to-end validation binary.
//
// Mirrors tests/smoke_e2e.py but drives the C ABI directly. Runs each of
// the four closed-form physics fixtures and checks the result against its
// analytical solution. Exits 0 on success, 1 on failure.
//
// Build via build_macos.sh after libfemm_core.a is produced. Requires the
// solver binaries to be locatable (walks upward for build/ or $FEMM_BIN).

#include "femm_c.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

void die(const char* ctx, femm_status_t s) {
    std::fprintf(stderr, "%s: status=%d msg=%s\n", ctx, (int)s, femm_last_error_message());
    std::exit(1);
}

void progress_cb(int32_t pct, const char* msg, void* /*u*/) {
    (void)pct;
    std::fprintf(stderr, "  solver: %s\n", msg);
}

int add_node(femm_doc_t* d, double x, double y) {
    int32_t idx = -1;
    auto s = femm_add_node(d, x, y, &idx);
    if (s != FEMM_OK) die("femm_add_node", s);
    return idx;
}
int add_seg(femm_doc_t* d, int a, int b, const char* bdry = nullptr) {
    int32_t idx = -1;
    auto s = femm_add_segment(d, a, b, &idx);
    if (s != FEMM_OK) die("femm_add_segment", s);
    if (bdry) femm_set_segment_boundary(d, idx, bdry);
    return idx;
}
int add_label(femm_doc_t* d, double x, double y, const char* mat, double max_area) {
    int32_t idx = -1;
    auto s = femm_add_block_label(d, x, y, &idx);
    if (s != FEMM_OK) die("femm_add_block_label", s);
    femm_set_block_label_material(d, idx, mat);
    femm_set_block_label_max_area(d, idx, max_area);
    return idx;
}

void add_rect(femm_doc_t* d, double x0, double y0, double x1, double y1,
              const char* bot, const char* right, const char* top, const char* left) {
    int n0 = add_node(d, x0, y0);
    int n1 = add_node(d, x1, y0);
    int n2 = add_node(d, x1, y1);
    int n3 = add_node(d, x0, y1);
    add_seg(d, n0, n1, bot);
    add_seg(d, n1, n2, right);
    add_seg(d, n2, n3, top);
    add_seg(d, n3, n0, left);
}

// Returns path without extension. Caller frees nothing; single process.
std::string out_path(const char* root) {
    const char* env = std::getenv("FEMM_SMOKE_OUT");
    std::string dir = env ? env : "build/smoke";
    // ensure dir exists — call mkdir -p via system for simplicity.
    std::string cmd = "mkdir -p '" + dir + "'";
    (void)std::system(cmd.c_str());
    return dir + "/" + root;
}

// ----- electrostatics: parallel-plate capacitor, V varies linearly in y -----
bool test_electrostatics() {
    std::printf("=== electrostatics ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_ELECTROSTATICS, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);

    femm_es_material_t air = { "air", 1.0, 1.0, 0.0 };
    femm_es_add_material(d, &air);
    femm_es_boundary_t bh = { "V_high", 0, 100.0, 0.0, 0.0, 0.0 };
    femm_es_boundary_t bl = { "V_low",  0,   0.0, 0.0, 0.0, 0.0 };
    femm_es_add_boundary(d, &bh);
    femm_es_add_boundary(d, &bl);

    add_rect(d, 0, 0, 10, 5, "V_low", nullptr, "V_high", nullptr);
    add_label(d, 5, 2.5, "air", 0.25);

    std::string path = out_path("cap");
    femm_status_t s = femm_doc_create_mesh(d, path.c_str());
    if (s != FEMM_OK) die("create_mesh", s);
    s = femm_doc_analyze(d, path.c_str(), progress_cb, nullptr);
    if (s != FEMM_OK) die("analyze", s);

    femm_result_t* r = nullptr;
    s = femm_result_load((path + ".res").c_str(), FEMM_PHYSICS_ELECTROSTATICS, &r);
    if (s != FEMM_OK) die("result_load", s);

    size_t n = femm_result_num_nodes(r);
    std::vector<double> x(n), y(n), V(n);
    femm_result_get_node_xy(r, x.data(), y.data());
    femm_result_get_nodal_scalar(r, V.data());

    double max_err = 0;
    for (size_t i = 0; i < n; ++i)
        max_err = std::fmax(max_err, std::fabs(V[i] - 100.0 * y[i] / 5.0));
    double rel = max_err / 100.0;
    std::printf("  nodes=%zu  max|ΔV|/V0 = %.2e\n", n, rel);

    femm_result_free(r);
    femm_doc_free(d);
    return rel < 1e-3;
}

// ----- heat: slab with fixed T on edges -----
bool test_heat() {
    std::printf("=== heat ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_HEAT, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);

    femm_heat_material_t iron = { "iron", 50.0, 50.0, 0.0, 0.0 };
    femm_heat_add_material(d, &iron);
    femm_heat_boundary_t tl = { "T_low",  0, 300.0, 0, 0, 0, 0, 0 };
    femm_heat_boundary_t th = { "T_high", 0, 400.0, 0, 0, 0, 0, 0 };
    femm_heat_add_boundary(d, &tl);
    femm_heat_add_boundary(d, &th);

    add_rect(d, 0, 0, 10, 4, "T_low", nullptr, "T_high", nullptr);
    add_label(d, 5, 2, "iron", 0.25);

    std::string path = out_path("slab");
    femm_status_t s = femm_doc_create_mesh(d, path.c_str());
    if (s != FEMM_OK) die("create_mesh", s);
    s = femm_doc_analyze(d, path.c_str(), progress_cb, nullptr);
    if (s != FEMM_OK) die("analyze", s);

    femm_result_t* r = nullptr;
    s = femm_result_load((path + ".anh").c_str(), FEMM_PHYSICS_HEAT, &r);
    if (s != FEMM_OK) die("result_load", s);

    size_t n = femm_result_num_nodes(r);
    std::vector<double> x(n), y(n), T(n);
    femm_result_get_node_xy(r, x.data(), y.data());
    femm_result_get_nodal_scalar(r, T.data());

    double max_err = 0;
    for (size_t i = 0; i < n; ++i)
        max_err = std::fmax(max_err, std::fabs(T[i] - (300.0 + 100.0 * y[i] / 4.0)));
    double rel = max_err / 100.0;
    std::printf("  nodes=%zu  max|ΔT|/ΔT = %.2e\n", n, rel);

    femm_result_free(r);
    femm_doc_free(d);
    return rel < 1e-3;
}

// ----- current: DC resistive bar, V varies linearly in x -----
bool test_current() {
    std::printf("=== current ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_CURRENT, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);
    femm_doc_set_frequency(d, 0.0);

    femm_curr_material_t cu = { "copper", 5.8e7, 5.8e7, 1.0, 1.0, 0.0, 0.0 };
    femm_curr_add_material(d, &cu);
    femm_curr_boundary_t bh = { "V_high", 0, {10.0, 0}, {0, 0}, {0, 0}, {0, 0} };
    femm_curr_boundary_t bl = { "V_low",  0, { 0.0, 0}, {0, 0}, {0, 0}, {0, 0} };
    femm_curr_add_boundary(d, &bh);
    femm_curr_add_boundary(d, &bl);

    add_rect(d, 0, 0, 20, 5, nullptr, "V_high", nullptr, "V_low");
    add_label(d, 10, 2.5, "copper", 1.0);

    std::string path = out_path("bar");
    femm_status_t s = femm_doc_create_mesh(d, path.c_str());
    if (s != FEMM_OK) die("create_mesh", s);
    s = femm_doc_analyze(d, path.c_str(), progress_cb, nullptr);
    if (s != FEMM_OK) die("analyze", s);

    femm_result_t* r = nullptr;
    s = femm_result_load((path + ".anc").c_str(), FEMM_PHYSICS_CURRENT, &r);
    if (s != FEMM_OK) die("result_load", s);

    size_t n = femm_result_num_nodes(r);
    std::vector<double> x(n), y(n);
    std::vector<femm_complex_t> V(n);
    femm_result_get_node_xy(r, x.data(), y.data());
    femm_result_get_nodal_complex(r, V.data());

    double max_err = 0;
    for (size_t i = 0; i < n; ++i)
        max_err = std::fmax(max_err, std::fabs(V[i].re - 10.0 * x[i] / 20.0));
    double rel = max_err / 10.0;
    std::printf("  nodes=%zu  max|ΔV|/V0 = %.2e\n", n, rel);

    femm_result_free(r);
    femm_doc_free(d);
    return rel < 1e-3;
}

// ----- magnetics: current strip inside A=0 box; sanity-check peak |B| loc -----
bool test_magnetics() {
    std::printf("=== magnetics ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_MAGNETICS, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);
    femm_doc_set_frequency(d, 0.0);

    femm_mag_material_t air  = {"air",  1.0, 1.0, 0, 0, {0,0}, 0,0,0,0,0, 0, 1.0, 0, 0};
    femm_mag_material_t coil = {"coil", 1.0, 1.0, 0, 0, {1.0, 0}, 0,0,0,0,0, 0, 1.0, 0, 0};
    femm_mag_add_material(d, &air);
    femm_mag_add_material(d, &coil);
    femm_mag_boundary_t a0 = {"A0", 0, 0,0,0,0, {0,0},{0,0}, 0,0, 0,0};
    femm_mag_add_boundary(d, &a0);

    // Outer box 40x40 held at A=0.
    add_rect(d, -20, -20, 20, 20, "A0", "A0", "A0", "A0");

    // Inner strip -2..2 x -10..10 (just segments; no bdry marker).
    int c0 = add_node(d, -2, -10);
    int c1 = add_node(d,  2, -10);
    int c2 = add_node(d,  2,  10);
    int c3 = add_node(d, -2,  10);
    add_seg(d, c0, c1); add_seg(d, c1, c2); add_seg(d, c2, c3); add_seg(d, c3, c0);

    add_label(d,  0,  0, "coil", 0.5);
    add_label(d, 10, 10, "air",  5.0);

    std::string path = out_path("coil");
    femm_status_t s = femm_doc_create_mesh(d, path.c_str());
    if (s != FEMM_OK) die("create_mesh", s);
    s = femm_doc_analyze(d, path.c_str(), progress_cb, nullptr);
    if (s != FEMM_OK) die("analyze", s);

    femm_result_t* r = nullptr;
    s = femm_result_load((path + ".ans").c_str(), FEMM_PHYSICS_MAGNETICS, &r);
    if (s != FEMM_OK) die("result_load", s);

    size_t n = femm_result_num_nodes(r);
    size_t m = femm_result_num_elements(r);
    std::vector<double> x(n), y(n), A(n);
    std::vector<int32_t> elts(3 * m);
    femm_result_get_node_xy(r, x.data(), y.data());
    femm_result_get_nodal_scalar(r, A.data());
    femm_result_get_elements(r, elts.data());

    // Compute |B| = sqrt((dA/dy)^2 + (dA/dx)^2) per element via linear tri
    // gradient; check peak is near |x|≈2.
    double peak = 0; double peak_x = 0, peak_y = 0;
    for (size_t i = 0; i < m; ++i) {
        int p0 = elts[3*i], p1 = elts[3*i+1], p2 = elts[3*i+2];
        double x0 = x[p0], y0 = y[p0];
        double x1 = x[p1], y1 = y[p1];
        double x2 = x[p2], y2 = y[p2];
        double A0 = A[p0], A1 = A[p1], A2 = A[p2];
        double det = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
        if (det == 0) continue;
        // Gradient of linear A over triangle:
        double dAdx = ((A1 - A0) * (y2 - y0) - (A2 - A0) * (y1 - y0)) / det;
        double dAdy = ((A2 - A0) * (x1 - x0) - (A1 - A0) * (x2 - x0)) / det;
        // B = curl(A_z hat{z}) in 2D planar: Bx = dA/dy, By = -dA/dx
        double Bx = dAdy, By = -dAdx;
        double Bmag = std::hypot(Bx, By);
        if (Bmag > peak) {
            peak = Bmag;
            peak_x = (x0 + x1 + x2) / 3.0;
            peak_y = (y0 + y1 + y2) / 3.0;
        }
    }

    bool ok_loc = std::fabs(std::fabs(peak_x) - 2.0) < 3.0 && std::fabs(peak_y) < 12.0;
    std::printf("  nodes=%zu  max|B|=%.3e  at (%.2f,%.2f)  ok_loc=%d\n",
                n, peak, peak_x, peak_y, (int)ok_loc);

    femm_result_free(r);
    femm_doc_free(d);
    return std::isfinite(peak) && peak > 0 && ok_loc;
}

} // namespace

int main() {
    std::printf("libfemm_core %s\n", femm_version_string());
    bool all_ok = true;
    all_ok &= test_electrostatics();
    all_ok &= test_heat();
    all_ok &= test_current();
    all_ok &= test_magnetics();
    std::printf("\n%s\n", all_ok ? "PASS" : "FAIL");
    return all_ok ? 0 : 1;
}
