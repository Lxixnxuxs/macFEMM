// femm_mesh.cpp — .poly writer + triangle/solver subprocess wiring.
//
// Ports pymacfemm/geometry.py::write_poly and pymacfemm/solver.py into C++.
// Binary lookup mirrors pymacfemm: $FEMM_BIN (flat dir) or walk upward for a
// build/ directory matching build_macos.sh's layout.

#include "femm_doc.hpp"
#include "femm_c.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

extern char** environ;

namespace femmcore {

namespace {

struct DNode { double x, y; int bdry_idx; int in_conductor; };
struct DSeg  { int n0, n1; int bdry_idx; int in_conductor; };

double linelen(const DNode& a, const DNode& b) {
    return std::hypot(b.x - a.x, b.y - a.y);
}

void arc_circle(double x0, double y0, double x1, double y1, double arc_deg,
                double& cx, double& cy, double& r) {
    double dx = x1 - x0, dy = y1 - y0;
    double chord = std::hypot(dx, dy);
    double half = arc_deg * M_PI / 360.0;
    r = chord / (2.0 * std::sin(half));
    double mx = (x0 + x1) / 2.0, my = (y0 + y1) / 2.0;
    double nx = -dy / chord, ny = dx / chord;
    double offset = r * std::cos(half);
    cx = mx + nx * offset;
    cy = my + ny * offset;
}

std::string with_suffix(const std::string& path, const char* ext) {
    auto slash = path.find_last_of("/\\");
    auto dot = path.find_last_of('.');
    std::string root = (dot != std::string::npos && (slash == std::string::npos || dot > slash))
                         ? path.substr(0, dot) : path;
    return root + ext;
}

std::string strip_ext(const std::string& path) {
    auto slash = path.find_last_of("/\\");
    auto dot = path.find_last_of('.');
    if (dot != std::string::npos && (slash == std::string::npos || dot > slash))
        return path.substr(0, dot);
    return path;
}

bool is_executable(const std::string& p) {
    struct stat st;
    if (stat(p.c_str(), &st) != 0) return false;
    if (!S_ISREG(st.st_mode)) return false;
    return access(p.c_str(), X_OK) == 0;
}

std::string parent_dir(const std::string& p) {
    auto slash = p.find_last_of("/\\");
    if (slash == std::string::npos) return ".";
    if (slash == 0) return "/";
    return p.substr(0, slash);
}

std::string absolute(const std::string& p) {
    char buf[PATH_MAX];
    if (realpath(p.c_str(), buf)) return buf;
    return p;
}

// Layout produced by build_macos.sh relative to a build/ directory.
const char* nested_layout(const std::string& name) {
    if (name == "triangle")  return "triangle/triangle";
    if (name == "belasolve") return "belasolv/belasolve";
    if (name == "csolve")    return "csolv/csolve";
    if (name == "hsolve")    return "hsolv/hsolve";
    if (name == "fknsolve")  return "fkn/fknsolve";
    return nullptr;
}

std::string find_binary(const std::string& name) {
    const char* layout = nested_layout(name);
    if (!layout) return "";

    std::vector<std::string> roots;
    if (const char* env = std::getenv("FEMM_BIN"); env && *env) roots.emplace_back(env);

    // Walk upward from the current executable, CWD, and __FILE__'s dir looking
    // for a build/ directory. We try CWD and the real path of argv[0] via
    // /proc-less fallback (getcwd + typical repo layout).
    char cwd[PATH_MAX];
    if (getcwd(cwd, sizeof cwd)) {
        std::string p = cwd;
        for (int i = 0; i < 8; ++i) {
            roots.push_back(p + "/build");
            if (p == "/") break;
            p = parent_dir(p);
        }
    }

    for (auto const& root : roots) {
        std::string flat = root + "/" + name;
        if (is_executable(flat)) return flat;
        std::string nested = root + "/" + layout;
        if (is_executable(nested)) return nested;
    }
    return "";
}

// posix_spawn-style fork+exec with optional stderr line callback.
int run_cmd(const std::vector<std::string>& argv, femm_progress_cb cb, void* user) {
    std::vector<char*> cargv;
    cargv.reserve(argv.size() + 1);
    for (auto const& s : argv) cargv.push_back(const_cast<char*>(s.c_str()));
    cargv.push_back(nullptr);

    int err_pipe[2] = {-1, -1};
    if (cb && pipe(err_pipe) != 0) { err_pipe[0] = err_pipe[1] = -1; }

    pid_t pid = fork();
    if (pid < 0) {
        set_last_error(std::string("fork failed: ") + std::strerror(errno));
        if (err_pipe[0] != -1) { close(err_pipe[0]); close(err_pipe[1]); }
        return -1;
    }
    if (pid == 0) {
        // child
        if (err_pipe[1] != -1) {
            dup2(err_pipe[1], STDERR_FILENO);
            close(err_pipe[0]);
            close(err_pipe[1]);
        }
        execve(cargv[0], cargv.data(), environ);
        std::fprintf(stderr, "execve %s failed: %s\n", cargv[0], std::strerror(errno));
        _exit(127);
    }
    // parent
    if (err_pipe[1] != -1) close(err_pipe[1]);

    if (cb && err_pipe[0] != -1) {
        std::string buf;
        char chunk[256];
        while (true) {
            ssize_t n = read(err_pipe[0], chunk, sizeof chunk);
            if (n <= 0) break;
            buf.append(chunk, chunk + n);
            size_t nl;
            while ((nl = buf.find('\n')) != std::string::npos) {
                std::string line = buf.substr(0, nl);
                buf.erase(0, nl + 1);
                if (!line.empty()) cb(-1, line.c_str(), user);
            }
        }
        if (!buf.empty()) cb(-1, buf.c_str(), user);
        close(err_pipe[0]);
    } else if (err_pipe[0] != -1) {
        close(err_pipe[0]);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        set_last_error(std::string("waitpid failed: ") + std::strerror(errno));
        return -1;
    }
    if (!WIFEXITED(status)) {
        set_last_error("child did not exit normally");
        return -1;
    }
    return WEXITSTATUS(status);
}

} // namespace

/* --- .poly writer ------------------------------------------------------- */
femm_status_t write_poly(const Document& d, const std::string& fem_path) {
    const std::string root = strip_ext(fem_path);
    const std::string poly = root + ".poly";
    const std::string pbc  = root + ".pbc";

    // Start with a copy of the document nodes.
    std::vector<DNode> nodelst;
    nodelst.reserve(d.nodes.size());
    for (auto const& n : d.nodes) nodelst.push_back({n.x, n.y, n.bdry_idx, n.in_conductor});
    std::vector<DSeg> linelst;

    // SmartMesh corner-refinement distance: dL = avg_linelen / LineFraction.
    // Matches femm/StdAfx.h:LineFraction=500.0 and femm/writepoly.cpp:117-122.
    // The average is taken over original input segments (raw chord length),
    // before any discretization — matches the Windows writer exactly.
    constexpr double LINE_FRACTION = 500.0;
    double dL = 0.0;
    if (!d.segments.empty()) {
        double sum_chord = 0.0;
        for (auto const& seg : d.segments) {
            sum_chord += linelen(nodelst[seg.n0], nodelst[seg.n1]);
        }
        dL = (sum_chord / (double)d.segments.size()) / LINE_FRACTION;
    }

    // Discretize straight segments. Matches femm/writepoly.cpp:129-204.
    for (auto const& seg : d.segments) {
        DNode a0 = nodelst[seg.n0];
        DNode a1 = nodelst[seg.n1];
        double chord = linelen(a0, a1);
        int k;
        if (seg.max_side <= 0 || chord == 0) k = 1;
        else k = std::max(1, (int)std::ceil(chord / seg.max_side));

        if (k == 1) {
            // SmartMesh corner-refinement (writepoly.cpp:141-177): inject two
            // Steiner nodes at dL from each endpoint so Triangle refines near
            // corners. Eligibility mirrors the negated Windows gate:
            //   NOT eligible iff  chord < 3*dL  OR  !bSmartMesh.
            if (d.smart_mesh && dL > 0 && chord >= 3.0 * dL) {
                double ux = (a1.x - a0.x) / chord, uy = (a1.y - a0.y) / chord;
                // Windows uses default-constructed CNode for Steiner points:
                // BoundaryMarker defaults to "<None>", so the written marker
                // is 0 and in_conductor is 0.
                nodelst.push_back({a0.x + dL * ux, a0.y + dL * uy, 0, 0});
                int mid0 = (int)nodelst.size() - 1;
                nodelst.push_back({a1.x - dL * ux, a1.y - dL * uy, 0, 0});
                int mid1 = (int)nodelst.size() - 1;
                // Windows copies the parent segm in full, so all three
                // sub-segments inherit the parent's bdry_idx AND in_conductor.
                linelst.push_back({seg.n0, mid0, seg.bdry_idx, seg.in_conductor});
                linelst.push_back({mid0,   mid1, seg.bdry_idx, seg.in_conductor});
                linelst.push_back({mid1,   seg.n1, seg.bdry_idx, seg.in_conductor});
            } else {
                linelst.push_back({seg.n0, seg.n1, seg.bdry_idx, seg.in_conductor});
            }
        } else {
            int prev = seg.n0;
            double x0 = a0.x, y0 = a0.y, x1 = a1.x, y1 = a1.y;
            for (int j = 1; j < k; ++j) {
                double f = (double)j / k;
                nodelst.push_back({x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, 0, 0});
                int idx = (int)nodelst.size() - 1;
                linelst.push_back({prev, idx, seg.bdry_idx, seg.in_conductor});
                prev = idx;
            }
            linelst.push_back({prev, seg.n1, seg.bdry_idx, seg.in_conductor});
        }
    }

    // Discretize arcs.
    for (auto const& arc : d.arcs) {
        DNode a0 = nodelst[arc.n0];
        DNode a1 = nodelst[arc.n1];
        int k = std::max(1, (int)std::ceil(arc.arc_deg / arc.max_side_deg));
        double cx, cy, r;
        arc_circle(a0.x, a0.y, a1.x, a1.y, arc.arc_deg, cx, cy, r);
        double step = arc.arc_deg * M_PI / 180.0 / k;

        if (k == 1) {
            linelst.push_back({arc.n0, arc.n1, arc.bdry_idx, arc.in_conductor});
        } else {
            int prev = arc.n0;
            double dx = a0.x - cx, dy = a0.y - cy;
            for (int j = 1; j < k; ++j) {
                double a = step * j;
                double ca = std::cos(a), sa = std::sin(a);
                double x = cx + dx * ca - dy * sa;
                double y = cy + dx * sa + dy * ca;
                nodelst.push_back({x, y, 0, 0});
                int idx = (int)nodelst.size() - 1;
                linelst.push_back({prev, idx, arc.bdry_idx, arc.in_conductor});
                prev = idx;
            }
            linelst.push_back({prev, arc.n1, arc.bdry_idx, arc.in_conductor});
        }
    }

    std::ofstream os(poly);
    if (!os) { set_last_error("cannot open " + poly); return FEMM_ERR_IO; }

    os << nodelst.size() << "\t2\t0\t1\n";
    for (size_t i = 0; i < nodelst.size(); ++i) {
        const auto& n = nodelst[i];
        int t = 0;
        if (n.bdry_idx > 0) t = n.bdry_idx + 1;           // j+2 encoding
        if (n.in_conductor > 0) t += n.in_conductor * 0x10000;
        char xb[64], yb[64];
        std::snprintf(xb, sizeof xb, "%.17g", n.x);
        std::snprintf(yb, sizeof yb, "%.17g", n.y);
        os << i << "\t" << xb << "\t" << yb << "\t" << t << "\n";
    }

    os << linelst.size() << "\t1\n";
    for (size_t i = 0; i < linelst.size(); ++i) {
        const auto& s = linelst[i];
        int t = 0;
        if (s.bdry_idx > 0) t = -(s.bdry_idx + 1);
        if (s.in_conductor > 0) t -= s.in_conductor * 0x10000;
        os << i << "\t" << s.n0 << "\t" << s.n1 << "\t" << t << "\n";
    }

    // Holes: Windows writes one (x,y) per "<No Mesh>" block. We don't carry the
    // block-prop name on the Document yet, so no <No Mesh> support; tutorial.fem
    // has none. TODO: filter labels whose block-prop is "<No Mesh>".
    os << "0\n";

    // Regional attributes — one per block label.
    // Matches femm/StdAfx.h:#define BoundingBoxFraction 100.0 and
    // femm/bd_writepoly.cpp:299-320.
    constexpr double BOUNDING_BOX_FRACTION = 100.0;
    double default_mesh;
    if (nodelst.size() > 1) {
        double minx = nodelst[0].x, maxx = minx, miny = nodelst[0].y, maxy = miny;
        for (auto const& n : nodelst) {
            minx = std::min(minx, n.x); maxx = std::max(maxx, n.x);
            miny = std::min(miny, n.y); maxy = std::max(maxy, n.y);
        }
        double bbox = std::hypot(maxx - minx, maxy - miny);
        default_mesh = (bbox / BOUNDING_BOX_FRACTION) * (bbox / BOUNDING_BOX_FRACTION);
        if (!d.smart_mesh) default_mesh = bbox / BOUNDING_BOX_FRACTION;
    } else {
        default_mesh = -1;
    }

    os << d.labels.size() << "\n";
    for (size_t i = 0; i < d.labels.size(); ++i) {
        const auto& lbl = d.labels[i];
        double area = (lbl.max_area > 0 && lbl.max_area < default_mesh) ? lbl.max_area : default_mesh;
        char xb[64], yb[64], ab[64];
        std::snprintf(xb, sizeof xb, "%.17g", lbl.x);
        std::snprintf(yb, sizeof yb, "%.17g", lbl.y);
        std::snprintf(ab, sizeof ab, "%.17g", area);
        os << i << "\t" << xb << "\t" << yb << "\t" << (i + 1) << "\t" << ab << "\n";
    }

    if (!os.good()) { set_last_error("write failed: " + poly); return FEMM_ERR_IO; }

    std::ofstream pbcs(pbc);
    if (!pbcs) { set_last_error("cannot open " + pbc); return FEMM_ERR_IO; }
    pbcs << "0\n0\n";
    return FEMM_OK;
}

femm_status_t run_triangle(const std::string& fem_path, double min_angle) {
    std::string bin = find_binary("triangle");
    if (bin.empty()) {
        set_last_error("triangle not found; run build_macos.sh or set FEMM_BIN");
        return FEMM_ERR_NOT_FOUND;
    }
    std::string root = absolute(strip_ext(fem_path));
    // Match femm/StdAfx.h MINANGLE_BUMP=3 / MINANGLE_MAX=33.8 and
    // bd_writepoly.cpp:349-350: triangle -q = min(MinAngle+3, 33.8).
    constexpr double MINANGLE_BUMP = 3.0;
    constexpr double MINANGLE_MAX  = 33.8;
    double q = std::min(min_angle + MINANGLE_BUMP, MINANGLE_MAX);
    char qbuf[64];
    std::snprintf(qbuf, sizeof qbuf, "-q%.6f", q);
    std::vector<std::string> argv = {
        bin, "-p", "-P", "-j", qbuf, "-e", "-A", "-a", "-z", "-Q", "-I", root
    };
    int rc = run_cmd(argv, nullptr, nullptr);
    if (rc != 0) {
        set_last_error("triangle exited with status " + std::to_string(rc));
        return FEMM_ERR_SOLVER;
    }
    return FEMM_OK;
}

femm_status_t run_solver(const Document& d, const std::string& fem_path,
                         femm_progress_cb cb, void* user) {
    std::string bin = find_binary(solver_name_for(d.physics));
    if (bin.empty()) {
        set_last_error(std::string("solver not found: ") + solver_name_for(d.physics));
        return FEMM_ERR_NOT_FOUND;
    }
    std::string root = absolute(strip_ext(fem_path));
    std::vector<std::string> argv = { bin, root };
    int rc = run_cmd(argv, cb, user);
    if (rc != 0) {
        set_last_error(std::string(solver_name_for(d.physics)) + " exited with status " +
                       std::to_string(rc));
        return FEMM_ERR_SOLVER;
    }
    return FEMM_OK;
}

} // namespace femmcore

/* ======================================================================
 * C ABI
 * ====================================================================== */
using femmcore::Document;

extern "C" {

femm_status_t femm_doc_create_mesh(femm_doc_t* doc, const char* path) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !path) return FEMM_ERR_INVALID_ARG;
    auto st = femmcore::write_document(*d, path);
    if (st != FEMM_OK) return st;
    st = femmcore::write_poly(*d, path);
    if (st != FEMM_OK) return st;
    return femmcore::run_triangle(path, d->min_angle);
}

femm_status_t femm_doc_analyze(femm_doc_t* doc, const char* path,
                               femm_progress_cb cb, void* user) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !path) return FEMM_ERR_INVALID_ARG;
    return femmcore::run_solver(*d, path, cb, user);
}

} // extern "C"
