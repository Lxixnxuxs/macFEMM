// femm_cli_integrals.cpp — Phase E verification for line/block integrals.
//
// Four closed-form fixtures, each exercised through femm_result_*_line_integral
// and _block_integral:
//   1. Electrostatics: parallel-plate capacitor 10 mm × 5 mm × 1 mm depth.
//      V drop contour → 100 V; block energy → ½·ε·A·(V/d)² · depth.
//   2. Heat: slab T(0)=300, T(4)=400. ΔT contour → 100 K; flux = k·ΔT·W·d / L.
//   3. Current: 20 mm × 5 mm copper bar, V=10..0 at ends. ΔV → 10 V;
//      total current = σ·A·V/L; resistive power = V²/R.
//   4. Magnetics: air-core solenoid-like rectangle with uniform Jsrc.
//      Block area equals geometric area. Block ∫A is finite and negative-ish.
//
// Exits 0 on pass, 1 on any failure. Uses the same FEMM_SMOKE_OUT env for
// its scratch directory so it rides alongside the smoke target.

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
void progress_cb(int32_t, const char* msg, void*) { std::fprintf(stderr, "  %s\n", msg); }

int add_node(femm_doc_t* d, double x, double y) {
    int32_t i = -1; auto s = femm_add_node(d, x, y, &i);
    if (s != FEMM_OK) die("add_node", s); return i;
}
int add_seg(femm_doc_t* d, int a, int b, const char* bdry = nullptr) {
    int32_t i = -1; auto s = femm_add_segment(d, a, b, &i);
    if (s != FEMM_OK) die("add_seg", s);
    if (bdry) femm_set_segment_boundary(d, i, bdry);
    return i;
}
int add_label(femm_doc_t* d, double x, double y, const char* mat, double max_area) {
    int32_t i = -1; auto s = femm_add_block_label(d, x, y, &i);
    if (s != FEMM_OK) die("add_label", s);
    femm_set_block_label_material(d, i, mat);
    femm_set_block_label_max_area(d, i, max_area);
    return i;
}
void add_rect(femm_doc_t* d, double x0, double y0, double x1, double y1,
              const char* bot, const char* right, const char* top, const char* left) {
    int n0 = add_node(d, x0, y0), n1 = add_node(d, x1, y0);
    int n2 = add_node(d, x1, y1), n3 = add_node(d, x0, y1);
    add_seg(d, n0, n1, bot); add_seg(d, n1, n2, right);
    add_seg(d, n2, n3, top); add_seg(d, n3, n0, left);
}
std::string out_path(const char* root) {
    const char* env = std::getenv("FEMM_SMOKE_OUT");
    std::string dir = env ? env : "build/smoke";
    std::string cmd = "mkdir -p '" + dir + "'";
    (void)std::system(cmd.c_str());
    return dir + "/" + root;
}

bool near(double a, double b, double rel, double tag_abs = 1e-12) {
    double den = std::fabs(b) + tag_abs;
    return std::fabs(a - b) / den < rel;
}

/* ------------------------------------------------------------------ */
bool test_es() {
    std::printf("=== ES: parallel-plate capacitor integrals ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_ELECTROSTATICS, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);

    femm_es_material_t air = {"air", 1.0, 1.0, 0.0};
    femm_es_add_material(d, &air);
    femm_es_boundary_t bh = {"Vh", 0, 100.0, 0, 0, 0};
    femm_es_boundary_t bl = {"Vl", 0,   0.0, 0, 0, 0};
    femm_es_add_boundary(d, &bh); femm_es_add_boundary(d, &bl);

    add_rect(d, 0, 0, 10, 5, "Vl", nullptr, "Vh", nullptr);
    add_label(d, 5, 2.5, "air", 0.1);

    std::string path = out_path("cap");
    if (femm_doc_create_mesh(d, path.c_str()) != FEMM_OK) die("mesh", FEMM_ERR_UNKNOWN);
    if (femm_doc_analyze(d, path.c_str(), progress_cb, nullptr) != FEMM_OK) die("analyze", FEMM_ERR_UNKNOWN);

    femm_result_t* r = nullptr;
    if (femm_result_load((path + ".res").c_str(), FEMM_PHYSICS_ELECTROSTATICS, &r) != FEMM_OK)
        die("load", FEMM_ERR_UNKNOWN);

    /* Contour from (5, 0) [Vl=0] to (5, 5) [Vh=100]: Windows convention
     * returns V_first - V_last = -100. */
    double xy[] = { 5, 0, 5, 5 };
    femm_complex_t z[4] = {{0,0},{0,0},{0,0},{0,0}};
    int32_t k = 0;
    femm_result_es_line_integral(r, d, FEMM_ES_LINE_E_DOT_T, xy, 2, 200, z, &k);
    bool ok1 = near(z[0].re, -100.0, 1e-3);
    std::printf("  ΔV = %.6g (expect -100)  %s\n", z[0].re, ok1 ? "ok" : "FAIL");

    /* Stored energy: ½ · ε0 · A · (V/d)² · depth. */
    femm_complex_t zw = {0,0};
    femm_result_es_block_integral(r, d, FEMM_ES_BLOCK_ENERGY, nullptr, 0, &zw);
    const double EPS0 = 8.854187817e-12;
    double W = 0.5 * EPS0 * (10e-3 * 5e-3) * std::pow(100.0 / 5e-3, 2) * 1.0;
    bool ok2 = near(zw.re, W, 1e-2);
    std::printf("  W = %.6g J (expect %.6g)  %s\n", zw.re, W, ok2 ? "ok" : "FAIL");

    /* Area = 10 mm · 5 mm = 5e-5 m². */
    femm_complex_t za = {0,0};
    femm_result_es_block_integral(r, d, FEMM_ES_BLOCK_AREA, nullptr, 0, &za);
    bool ok3 = near(za.re, 5e-5, 1e-3);
    std::printf("  A = %.6g m² (expect 5e-05)  %s\n", za.re, ok3 ? "ok" : "FAIL");

    femm_result_free(r); femm_doc_free(d);
    return ok1 && ok2 && ok3;
}

/* ------------------------------------------------------------------ */
bool test_heat() {
    std::printf("=== heat: slab line+block integrals ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_HEAT, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);

    femm_heat_material_t iron = {"iron", 50.0, 50.0, 0, 0};
    femm_heat_add_material(d, &iron);
    femm_heat_boundary_t tl = {"Tl", 0, 300.0, 0,0,0,0,0};
    femm_heat_boundary_t th = {"Th", 0, 400.0, 0,0,0,0,0};
    femm_heat_add_boundary(d, &tl); femm_heat_add_boundary(d, &th);
    add_rect(d, 0, 0, 10, 4, "Tl", nullptr, "Th", nullptr);
    add_label(d, 5, 2, "iron", 0.1);

    std::string path = out_path("slab");
    if (femm_doc_create_mesh(d, path.c_str()) != FEMM_OK) die("mesh", FEMM_ERR_UNKNOWN);
    if (femm_doc_analyze(d, path.c_str(), progress_cb, nullptr) != FEMM_OK) die("analyze", FEMM_ERR_UNKNOWN);

    femm_result_t* r = nullptr;
    if (femm_result_load((path + ".anh").c_str(), FEMM_PHYSICS_HEAT, &r) != FEMM_OK)
        die("load", FEMM_ERR_UNKNOWN);

    /* ΔT from (5,0) [T=300] to (5,4) [T=400]: Windows convention returns
     * T_first - T_last = -100. */
    double xy[] = { 5, 0, 5, 4 };
    femm_complex_t z = {0,0};
    int32_t k = 0;
    femm_result_heat_line_integral(r, d, FEMM_HEAT_LINE_TEMP_DROP, xy, 2, 200, &z, &k);
    bool ok1 = near(z.re, -100.0, 1e-3);
    std::printf("  ΔT = %.6g (expect -100)  %s\n", z.re, ok1 ? "ok" : "FAIL");

    /* Heat flux across a horizontal contour at y=2: Q = k·(ΔT/L)·W·depth. */
    double xyH[] = { 0, 2, 10, 2 };
    femm_complex_t zF = {0,0};
    femm_result_heat_line_integral(r, d, FEMM_HEAT_LINE_FLUX, xyH, 2, 400, &zF, &k);
    /* F = -k·∇T. ∇T_y = +100/4e-3 = +25000 K/m ⇒ Fy = -k·25000, contour
     * normal = (0,+1) (perp to +x tangent): Fn = -k·25000, flux = -k·25000·W·d
     * = -50·25000·10e-3·1 = -12500 W. */
    double flux_expected = -50.0 * 25000.0 * 10e-3 * 1.0;
    bool ok2 = near(zF.re, flux_expected, 2e-2);
    std::printf("  flux = %.6g W (expect %.6g)  %s\n", zF.re, flux_expected, ok2 ? "ok" : "FAIL");

    /* Area check. */
    femm_complex_t za = {0,0};
    femm_result_heat_block_integral(r, d, FEMM_HEAT_BLOCK_AREA, nullptr, 0, &za);
    bool ok3 = near(za.re, 4e-5, 1e-3);
    std::printf("  A = %.6g m² (expect 4e-05)  %s\n", za.re, ok3 ? "ok" : "FAIL");

    femm_result_free(r); femm_doc_free(d);
    return ok1 && ok2 && ok3;
}

/* ------------------------------------------------------------------ */
bool test_current() {
    std::printf("=== current: resistive bar integrals ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_CURRENT, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);
    femm_doc_set_frequency(d, 0.0);

    /* σ provided in MS/m per C ABI convention. */
    femm_curr_material_t cu = {"cu", 58.0, 58.0, 1, 1, 0, 0};
    femm_curr_add_material(d, &cu);
    femm_curr_boundary_t bh = {"Vh", 0, {10.0, 0}, {0,0}, {0,0}, {0,0}};
    femm_curr_boundary_t bl = {"Vl", 0, { 0.0, 0}, {0,0}, {0,0}, {0,0}};
    femm_curr_add_boundary(d, &bh); femm_curr_add_boundary(d, &bl);

    add_rect(d, 0, 0, 20, 5, nullptr, "Vh", nullptr, "Vl");
    add_label(d, 10, 2.5, "cu", 1.0);

    std::string path = out_path("bar");
    if (femm_doc_create_mesh(d, path.c_str()) != FEMM_OK) die("mesh", FEMM_ERR_UNKNOWN);
    if (femm_doc_analyze(d, path.c_str(), progress_cb, nullptr) != FEMM_OK) die("analyze", FEMM_ERR_UNKNOWN);

    femm_result_t* r = nullptr;
    if (femm_result_load((path + ".anc").c_str(), FEMM_PHYSICS_CURRENT, &r) != FEMM_OK)
        die("load", FEMM_ERR_UNKNOWN);

    /* Cross-section contour at x = 10. Expect J·n = σ·E·A = σ·(V/L)·A. */
    double xyJ[] = { 10, 0, 10, 5 };
    femm_complex_t z = {0,0}; int32_t k = 0;
    femm_result_curr_line_integral(r, d, FEMM_CURR_LINE_CURRENT, xyJ, 2, 400, &z, &k);
    double sigma = 58e6;        /* S/m */
    double I_expected = sigma * (10.0 / 20e-3) * (5e-3 * 1.0);
    bool ok1 = near(z.re, I_expected, 2e-2);
    std::printf("  I = %.6g A (expect %.6g)  %s\n", z.re, I_expected, ok1 ? "ok" : "FAIL");

    /* Power = V²/R = V²·σ·A/L. */
    femm_complex_t zp = {0,0};
    femm_result_curr_block_integral(r, d, FEMM_CURR_BLOCK_POWER_REAL, nullptr, 0, &zp);
    double P_expected = 10.0 * 10.0 * sigma * (5e-3 * 1.0) / 20e-3;
    bool ok2 = near(zp.re, P_expected, 2e-2);
    std::printf("  P = %.6g W (expect %.6g)  %s\n", zp.re, P_expected, ok2 ? "ok" : "FAIL");

    femm_result_free(r); femm_doc_free(d);
    return ok1 && ok2;
}

/* ------------------------------------------------------------------ */
bool test_mag() {
    std::printf("=== magnetics: block area + volume integrals ===\n");
    femm_doc_t* d = nullptr;
    femm_doc_new(FEMM_PHYSICS_MAGNETICS, &d);
    femm_doc_set_length_units(d, FEMM_UNITS_MILLIMETERS);
    femm_doc_set_problem_type(d, FEMM_PROBLEM_PLANAR);
    femm_doc_set_depth(d, 1.0);
    femm_doc_set_min_angle(d, 30.0);
    femm_doc_set_frequency(d, 0.0);

    femm_mag_material_t air  = {"air",  1.0, 1.0, 0, 0, {0,0},      0,0,0,0,0, 0, 1.0, 0, 0};
    femm_mag_material_t coil = {"coil", 1.0, 1.0, 0, 0, {1.0, 0},   0,0,0,0,0, 0, 1.0, 0, 0};
    femm_mag_add_material(d, &air); femm_mag_add_material(d, &coil);
    femm_mag_boundary_t a0 = {"A0", 0, 0,0,0,0, {0,0},{0,0}, 0,0, 0,0};
    femm_mag_add_boundary(d, &a0);

    add_rect(d, -20, -20, 20, 20, "A0", "A0", "A0", "A0");
    int c0 = add_node(d, -2, -10), c1 = add_node(d,  2, -10);
    int c2 = add_node(d,  2,  10), c3 = add_node(d, -2,  10);
    add_seg(d, c0, c1); add_seg(d, c1, c2);
    add_seg(d, c2, c3); add_seg(d, c3, c0);
    int lbl_coil = add_label(d,  0,  0, "coil", 0.1);
    add_label(d, 10, 10, "air", 5.0);
    (void)lbl_coil;

    std::string path = out_path("coil_mag");
    if (femm_doc_create_mesh(d, path.c_str()) != FEMM_OK) die("mesh", FEMM_ERR_UNKNOWN);
    if (femm_doc_analyze(d, path.c_str(), progress_cb, nullptr) != FEMM_OK) die("analyze", FEMM_ERR_UNKNOWN);

    femm_result_t* r = nullptr;
    if (femm_result_load((path + ".ans").c_str(), FEMM_PHYSICS_MAGNETICS, &r) != FEMM_OK)
        die("load", FEMM_ERR_UNKNOWN);

    /* Total area over all labels = 40*40 mm² = 1.6e-3 m². */
    femm_complex_t za = {0,0};
    femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_AREA, nullptr, 0, &za);
    bool ok1 = near(za.re, 1.6e-3, 1e-3);
    std::printf("  A_total = %.6g m² (expect 1.6e-03)  %s\n", za.re, ok1 ? "ok" : "FAIL");

    /* Total current over coil label only = Jsrc · A_coil = 1e6 · 4*20e-6 = 80 A.
     * Find coil label by block_idx — mag_materials are 1-based; "coil" is idx 2. */
    size_t nL = (size_t)femm_num_labels(d);
    std::vector<int32_t> mask(nL, 0);
    for (size_t i = 0; i < nL; ++i) {
        femm_lbl_view_t lv{};
        if (femm_get_label(d, (int32_t)i, &lv) == FEMM_OK && lv.block_idx == 2) {
            mask[i] = 1;
        }
    }
    femm_complex_t zi = {0,0};
    femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_CURRENT, mask.data(), nL, &zi);
    double I_expected = 1e6 * (4e-3 * 20e-3);
    bool ok2 = near(zi.re, I_expected, 2e-2);
    std::printf("  I_coil = %.6g A (expect %.6g)  %s\n", zi.re, I_expected, ok2 ? "ok" : "FAIL");

    femm_result_free(r); femm_doc_free(d);
    return ok1 && ok2;
}

} // namespace

int main() {
    std::printf("libfemm_core %s — Phase E integrals\n", femm_version_string());
    bool ok = true;
    ok &= test_es();
    ok &= test_heat();
    ok &= test_current();
    ok &= test_mag();
    std::printf("\n%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
