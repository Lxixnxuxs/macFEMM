// femm_cli_regression.cpp — Windows-vs-macOS regression harness.
//
// Loads an existing .fem from disk (no programmatic construction), meshes +
// solves via our headless pipeline, loads the .ans, and emits a fixed battery
// of probes to a plain-text report. Windows FEMM computes the same probes via
// the matching Lua script (regression_probe.lua); the two reports are then
// diffed by tools/compare_reports.py.
//
// Report format: one probe per line —
//     <key> <value>
// `key` is a stable, human-readable tag (e.g. "point/A/0.5,0"). `value` is a
// %.10g-formatted real (complex ignored for the DC magnetostatic tutorial).
//
// Usage:
//   femm_cli_regression <input.fem> <output_dir> <report.txt>
//
// Deliberately narrow (magnetics only) for the first regression. Extend
// probe set as more physics land.

#include "femm_c.h"

#include <algorithm>
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

struct Report {
    FILE* fp;
    void kv(const char* key, double v) { std::fprintf(fp, "%s %.10g\n", key, v); }
};

/* Fixed probe points on the axis and in the window of the tutorial solenoid.
 * Coordinates in inches (file's [LengthUnits]). Chosen to sample:
 *   - the axis inside the coil bore (x=0)
 *   - off-axis inside the bore (x=0.25)
 *   - just outside the coil along axis (x=0, y=±1.2)
 *   - well outside in the open-boundary region (x=2, y=0)
 * The axi symmetry line is x=0; y is along the coil's axis. */
const double probe_xy[][2] = {
    { 0.00,  0.0  },
    { 0.25,  0.0  },
    { 0.40,  0.0  },
    { 0.00,  0.5  },
    { 0.25,  0.5  },
    { 0.00,  1.2  },
    { 1.00,  0.0  },
    { 2.00,  0.0  },
    { 0.00, -0.5  },
    { 0.25, -0.5  },
};
constexpr int N_PROBES = sizeof(probe_xy)/sizeof(probe_xy[0]);

struct StressContour {
    const char* name;
    const double* xy;
    size_t npts;
};

/* Maxwell-stress contours in inches. Closed contours are clockwise so FEMM's
 * 1e-6 left-normal sampling offset stays on the exterior air side. */
const double force_coil_tight[] = {
    0.35, -1.15,
    0.35,  1.15,
    1.65,  1.15,
    1.65, -1.15,
    0.35, -1.15,
};
const double force_coil_medium[] = {
    0.15, -1.80,
    0.15,  1.80,
    2.20,  1.80,
    2.20, -1.80,
    0.15, -1.80,
};
const double force_coil_large[] = {
    0.08, -2.60,
    0.08,  2.60,
    2.85,  2.60,
    2.85, -2.60,
    0.08, -2.60,
};
const double force_air_right[] = {
    1.65, -0.75,
    2.55, -0.75,
    2.55,  0.75,
    1.65,  0.75,
    1.65, -0.75,
};
const double force_h_y0[] = {
    0.00, 0.00,
    1.00, 0.00,
};
const double force_outer_y0[] = {
    1.65, 0.00,
    2.65, 0.00,
};

const StressContour stress_contours[] = {
    { "coil_tight_cw",  force_coil_tight,  sizeof(force_coil_tight)  / (2 * sizeof(double)) },
    { "coil_medium_cw", force_coil_medium, sizeof(force_coil_medium) / (2 * sizeof(double)) },
    { "coil_large_cw",  force_coil_large,  sizeof(force_coil_large)  / (2 * sizeof(double)) },
    { "air_right_cw",   force_air_right,   sizeof(force_air_right)   / (2 * sizeof(double)) },
    { "h_y0_open",      force_h_y0,        sizeof(force_h_y0)        / (2 * sizeof(double)) },
    { "outer_y0_open",  force_outer_y0,    sizeof(force_outer_y0)    / (2 * sizeof(double)) },
};
constexpr int N_STRESS_CONTOURS = sizeof(stress_contours)/sizeof(stress_contours[0]);

} // namespace

int main(int argc, char** argv) {
    if (argc != 4) {
        std::fprintf(stderr,
            "usage: %s <input.fem> <output_dir> <report.txt>\n", argv[0]);
        return 2;
    }
    const char* fem_path  = argv[1];
    const char* out_dir   = argv[2];
    const char* rpt_path  = argv[3];

    /* Prepare output dir and a working copy of the .fem there (the solver
     * writes siblings next to the .fem). */
    {
        std::string cmd = std::string("mkdir -p '") + out_dir + "'";
        (void)std::system(cmd.c_str());
    }
    std::string work_fem = std::string(out_dir) + "/tutorial.fem";
    {
        std::string cmd = std::string("cp '") + fem_path + "' '" + work_fem + "'";
        if (std::system(cmd.c_str()) != 0) {
            std::fprintf(stderr, "failed to copy %s → %s\n", fem_path, work_fem.c_str());
            return 1;
        }
    }
    std::string path_root = work_fem.substr(0, work_fem.size() - 4); /* strip .fem */

    femm_doc_t* d = nullptr;
    if (femm_doc_open(work_fem.c_str(), &d) != FEMM_OK) die("doc_open", FEMM_ERR_IO);

    if (femm_doc_create_mesh(d, path_root.c_str()) != FEMM_OK)
        die("create_mesh", FEMM_ERR_UNKNOWN);
    if (femm_doc_analyze(d, path_root.c_str(), progress_cb, nullptr) != FEMM_OK)
        die("analyze", FEMM_ERR_UNKNOWN);

    femm_result_t* r = nullptr;
    if (femm_result_load((path_root + ".ans").c_str(), FEMM_PHYSICS_MAGNETICS, &r) != FEMM_OK)
        die("result_load", FEMM_ERR_IO);

    FILE* fp = std::fopen(rpt_path, "w");
    if (!fp) { std::fprintf(stderr, "cannot write %s\n", rpt_path); return 1; }
    Report rpt{fp};

    std::fprintf(fp, "# femm regression report (magnetics, axi, tutorial solenoid)\n");
    std::fprintf(fp, "# generator libfemm_core %s\n", femm_version_string());
    std::fprintf(fp, "# units: length=inches, A=Wb/m, B=T, energy=J, inductance=H\n");
    std::fprintf(fp, "# probe_format: <key> <value>  (value is %%.10g)\n");

    /* --- Mesh size (ballpark stability check) ------------------------------ */
    rpt.kv("mesh/num_nodes",    (double)femm_result_num_nodes(r));
    rpt.kv("mesh/num_elements", (double)femm_result_num_elements(r));

    /* --- Point-wise A, |B| ------------------------------------------------- */
    for (int i = 0; i < N_PROBES; ++i) {
        double px = probe_xy[i][0], py = probe_xy[i][1];
        double A = 0; double BxBy[2] = {0,0};
        femm_status_t st = femm_result_point_values(r, d, px, py, &A, BxBy);
        char key[128];
        if (st == FEMM_OK) {
            std::snprintf(key, sizeof(key), "point/A/%g,%g", px, py);   rpt.kv(key, A);
            double Bmag = std::sqrt(BxBy[0]*BxBy[0] + BxBy[1]*BxBy[1]);
            std::snprintf(key, sizeof(key), "point/Bx/%g,%g", px, py);  rpt.kv(key, BxBy[0]);
            std::snprintf(key, sizeof(key), "point/By/%g,%g", px, py);  rpt.kv(key, BxBy[1]);
            std::snprintf(key, sizeof(key), "point/|B|/%g,%g", px, py); rpt.kv(key, Bmag);
        } else {
            std::snprintf(key, sizeof(key), "point/miss/%g,%g", px, py); rpt.kv(key, 1.0);
        }
    }

    /* --- Block integrals over the coil label only (block_idx=2, "18 AWG"). -
     * .fem block-label idx is 1-based in label.block_idx; "18 AWG" = 2.
     * We build a length-N mask over doc labels picking labels whose block_idx==2. */
    size_t nL = (size_t)femm_num_labels(d);
    std::vector<int32_t> coil_mask(nL, 0);
    int coil_label_idx = -1;
    for (size_t i = 0; i < nL; ++i) {
        femm_lbl_view_t lv{};
        if (femm_get_label(d, (int32_t)i, &lv) == FEMM_OK && lv.block_idx == 2) {
            coil_mask[i] = 1;
            if (coil_label_idx < 0) coil_label_idx = (int)i;
        }
    }
    rpt.kv("coil/label_count", (double)std::count(coil_mask.begin(), coil_mask.end(), 1));

    auto block_coil = [&](const char* key, int32_t type) {
        femm_complex_t z{0,0};
        femm_result_mag_block_integral(r, d, type, coil_mask.data(), nL, &z);
        rpt.kv(key, z.re);
    };
    block_coil("coil/area",      FEMM_MAG_BLOCK_AREA);
    block_coil("coil/volume",    FEMM_MAG_BLOCK_VOLUME);
    block_coil("coil/A_dot_J",   FEMM_MAG_BLOCK_AJ);
    block_coil("coil/int_A",     FEMM_MAG_BLOCK_A);
    block_coil("coil/energy",    FEMM_MAG_BLOCK_ENERGY);
    block_coil("coil/current",   FEMM_MAG_BLOCK_CURRENT);
    block_coil("coil/int_Bx",    FEMM_MAG_BLOCK_BX);
    block_coil("coil/int_By",    FEMM_MAG_BLOCK_BY);

    /* --- Block integrals over "Air" (block_idx=1) — outside the coil. ------ */
    std::vector<int32_t> air_mask(nL, 0);
    for (size_t i = 0; i < nL; ++i) {
        femm_lbl_view_t lv{};
        if (femm_get_label(d, (int32_t)i, &lv) == FEMM_OK && lv.block_idx == 1) {
            air_mask[i] = 1;
        }
    }
    rpt.kv("air/label_count", (double)std::count(air_mask.begin(), air_mask.end(), 1));
    {
        femm_complex_t z{0,0};
        femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_AREA, air_mask.data(), nL, &z);
        rpt.kv("air/area", z.re);
        femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_ENERGY, air_mask.data(), nL, &z);
        rpt.kv("air/energy", z.re);
    }

    /* --- Global block integrals (mask=NULL → all labels) ------------------ */
    {
        femm_complex_t z{0,0};
        femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_ENERGY, nullptr, 0, &z);
        rpt.kv("total/energy", z.re);
        femm_result_mag_block_integral(r, d, FEMM_MAG_BLOCK_VOLUME, nullptr, 0, &z);
        rpt.kv("total/volume", z.re);
    }

    /* --- Line integral: horizontal segment at y=0 through the bore.
     * Contour from (0,0) → (1,0) inches. Should have B·n ≈ 0 (symmetry). */
    {
        double xy[] = { 0.0, 0.0, 1.0, 0.0 };
        femm_complex_t z[4] = {{0,0},{0,0},{0,0},{0,0}};
        int32_t k = 0;
        femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_B_DOT_N, xy, 2, 400, z, &k);
        rpt.kv("line/h_y0/flux",    z[0].re);
        rpt.kv("line/h_y0/avg_Bn",  z[1].re);
        femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_H_DOT_T, xy, 2, 400, z, &k);
        rpt.kv("line/h_y0/mmf",     z[0].re);
    }
    /* Vertical contour on axis from (0,-0.9) → (0, 0.9) — spans bore. */
    {
        double xy[] = { 0.0, -0.9, 0.0, 0.9 };
        femm_complex_t z[4] = {{0,0},{0,0},{0,0},{0,0}};
        int32_t k = 0;
        femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_H_DOT_T, xy, 2, 400, z, &k);
        rpt.kv("line/axis/mmf", z[0].re);
        femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_LENGTH, xy, 2, 400, z, &k);
        rpt.kv("line/axis/length", z[0].re);
    }

    /* --- Maxwell stress force/torque line integrals ----------------------- */
    for (int i = 0; i < N_STRESS_CONTOURS; ++i) {
        const StressContour& c = stress_contours[i];
        femm_complex_t z[4] = {{0,0},{0,0},{0,0},{0,0}};
        int32_t k = 0;
        char key[160];

        if (femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_STRESS_FORCE,
                                          c.xy, c.npts, 400, z, &k) != FEMM_OK)
            die("line_stress_force", FEMM_ERR_UNKNOWN);
        std::snprintf(key, sizeof(key), "force/%s/Fr", c.name); rpt.kv(key, z[0].re);
        std::snprintf(key, sizeof(key), "force/%s/Fz", c.name); rpt.kv(key, z[1].re);

        z[0] = z[1] = z[2] = z[3] = femm_complex_t{0,0};
        if (femm_result_mag_line_integral(r, d, FEMM_MAG_LINE_STRESS_TORQ,
                                          c.xy, c.npts, 400, z, &k) != FEMM_OK)
            die("line_stress_torque", FEMM_ERR_UNKNOWN);
        std::snprintf(key, sizeof(key), "torque/%s/T", c.name); rpt.kv(key, z[0].re);
    }

    /* Coil inductance can only be computed via the circuit current which our
     * C ABI doesn't surface yet. Skipped for this first regression — the
     * Windows side will report it via mo_getcircuitproperties for reference,
     * and compare_reports.py treats missing keys as non-fatal. */

    std::fclose(fp);
    std::fprintf(stderr, "wrote %s (%d probe points, magnetics tutorial)\n",
                 rpt_path, N_PROBES);

    femm_result_free(r);
    femm_doc_free(d);
    return 0;
}
