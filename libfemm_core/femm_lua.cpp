// femm_lua.cpp — Native Lua 4.0 compatibility layer for macFEMM.

#include "femm_doc.hpp"
#include "femm_c.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits.h>
#include <map>
#include <new>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

using femmcore::Document;

namespace {

struct LuaSession {
    lua_State* L = nullptr;
    femm_doc_t* doc = nullptr;          // non-owning active Swift document
    femm_result_t* result = nullptr;    // non-owning active Swift result
    std::string active_path;
    std::string cwd;

    femm_doc_t* replacement_doc = nullptr;       // owned until taken
    femm_result_t* replacement_result = nullptr; // owned until taken
    std::string replacement_doc_path;
    std::string replacement_result_path;

    std::string output;
    std::string error;

    std::set<int> sel_nodes;
    std::set<int> sel_segments;
    std::set<int> sel_arcs;
    std::set<int> sel_labels;
    std::vector<double> contour_xy;
    int edit_mode = 4;
    int compatibility_mode = 0;
    bool console_visible = false;
};

thread_local LuaSession* g_session = nullptr;
thread_local std::string g_error_storage;

struct Command {
    const char* name;
    lua_CFunction fn;
};

static Document* doc(LuaSession* s) {
    return s && s->doc ? reinterpret_cast<Document*>(s->doc) : nullptr;
}

static Document* require_doc(lua_State* L) {
    Document* d = doc(g_session);
    if (!d) lua_error(L, "no active FEMM document");
    return d;
}

static void fail(lua_State* L, const std::string& message) {
    g_error_storage = message;
    if (g_session) g_session->error = message;
    lua_error(L, g_error_storage.c_str());
}

static void check_status(lua_State* L, femm_status_t st) {
    if (st != FEMM_OK) fail(L, femm_last_error_message());
}

static double real_arg(lua_State* L, int idx, double def = 0.0, bool required = true) {
    if (!required && (idx > lua_gettop(L) || lua_type(L, idx) == LUA_TNIL)) return def;
    return Re(luaL_check_number(L, idx));
}

static int int_arg(lua_State* L, int idx, int def = 0, bool required = true) {
    return (int)std::lround(real_arg(L, idx, (double)def, required));
}

static CComplex complex_arg(lua_State* L, int idx, CComplex def = CComplex(0, 0), bool required = true) {
    if (!required && (idx > lua_gettop(L) || lua_type(L, idx) == LUA_TNIL)) return def;
    return luaL_check_number(L, idx);
}

static std::string string_arg(lua_State* L, int idx, const char* def = "", bool required = true) {
    if (!required && (idx > lua_gettop(L) || lua_type(L, idx) == LUA_TNIL)) return def ? def : "";
    return luaL_check_string(L, idx);
}

static femm_complex_t femm_c(CComplex z) {
    return femm_complex_t{Re(z), Im(z)};
}

static CComplex lua_c(femm_complex_t z) {
    return CComplex(z.re, z.im);
}

static void push_real(lua_State* L, double v) { lua_pushnumber(L, CComplex(v, 0)); }
static void push_complex(lua_State* L, femm_complex_t z) { lua_pushnumber(L, lua_c(z)); }

static std::string dirname_of(const std::string& path) {
    size_t slash = path.find_last_of('/');
    if (slash == std::string::npos) return "";
    if (slash == 0) return "/";
    return path.substr(0, slash);
}

static bool is_abs_path(const std::string& path) {
    return !path.empty() && path[0] == '/';
}

static std::string process_cwd() {
    char buf[PATH_MAX];
    if (getcwd(buf, sizeof(buf))) return buf;
    return "/tmp";
}

static std::string resolve_path(LuaSession* s, const std::string& path) {
    if (path.empty() || is_abs_path(path)) return path;
    if (path[0] == '~') {
        const char* home = getenv("HOME");
        if (home && path.size() == 1) return home;
        if (home && path.size() > 1 && path[1] == '/') return std::string(home) + path.substr(1);
    }
    std::string base = s && !s->cwd.empty() ? s->cwd : "";
    if (base.empty() && s && !s->active_path.empty()) base = dirname_of(s->active_path);
    if (base.empty()) base = process_cwd();
    return base + "/" + path;
}

static std::string strip_known_ext(const std::string& path) {
    const char* exts[] = {".fem", ".fee", ".feh", ".fec", ".ans", ".res", ".anh", ".anc"};
    for (const char* ext : exts) {
        size_t n = std::strlen(ext);
        if (path.size() >= n && path.compare(path.size() - n, n, ext) == 0)
            return path.substr(0, path.size() - n);
    }
    return path;
}

static std::string default_root(LuaSession* s, const Document* d) {
    if (s && !s->active_path.empty()) return strip_known_ext(s->active_path);
    std::ostringstream os;
    os << "/tmp/macfemm_lua_" << (unsigned long)getpid() << "_" << (uintptr_t)s;
    if (d) os << femmcore::file_ext_for(d->physics);
    return strip_known_ext(os.str());
}

static int find_node(Document* d, double x, double y) {
    const double tol2 = 1e-20;
    for (size_t i = 0; i < d->nodes.size(); ++i) {
        double dx = d->nodes[i].x - x;
        double dy = d->nodes[i].y - y;
        if (dx * dx + dy * dy <= tol2) return (int)i;
    }
    return -1;
}

static int find_or_add_node(lua_State* L, Document* d, double x, double y) {
    int idx = find_node(d, x, y);
    if (idx >= 0) return idx;
    int32_t out = -1;
    check_status(L, femm_add_node(reinterpret_cast<femm_doc_t*>(d), x, y, &out));
    return out;
}

static int nearest_node(Document* d, double x, double y) {
    int best = -1;
    double best2 = 1e100;
    for (size_t i = 0; i < d->nodes.size(); ++i) {
        double dx = d->nodes[i].x - x;
        double dy = d->nodes[i].y - y;
        double r2 = dx * dx + dy * dy;
        if (r2 < best2) { best2 = r2; best = (int)i; }
    }
    return best;
}

static int nearest_label(Document* d, double x, double y) {
    int best = -1;
    double best2 = 1e100;
    for (size_t i = 0; i < d->labels.size(); ++i) {
        double dx = d->labels[i].x - x;
        double dy = d->labels[i].y - y;
        double r2 = dx * dx + dy * dy;
        if (r2 < best2) { best2 = r2; best = (int)i; }
    }
    return best;
}

static double dist_point_seg2(double px, double py, double ax, double ay, double bx, double by) {
    double vx = bx - ax, vy = by - ay;
    double wx = px - ax, wy = py - ay;
    double c2 = vx * vx + vy * vy;
    double t = c2 > 0 ? (wx * vx + wy * vy) / c2 : 0;
    t = std::max(0.0, std::min(1.0, t));
    double dx = px - (ax + t * vx);
    double dy = py - (ay + t * vy);
    return dx * dx + dy * dy;
}

static int nearest_segment(Document* d, double x, double y) {
    int best = -1;
    double best2 = 1e100;
    for (size_t i = 0; i < d->segments.size(); ++i) {
        const auto& s = d->segments[i];
        if (s.n0 < 0 || s.n1 < 0 || (size_t)s.n0 >= d->nodes.size() || (size_t)s.n1 >= d->nodes.size()) continue;
        const auto& a = d->nodes[s.n0];
        const auto& b = d->nodes[s.n1];
        double r2 = dist_point_seg2(x, y, a.x, a.y, b.x, b.y);
        if (r2 < best2) { best2 = r2; best = (int)i; }
    }
    return best;
}

static int nearest_arc(Document* d, double x, double y) {
    int best = -1;
    double best2 = 1e100;
    for (size_t i = 0; i < d->arcs.size(); ++i) {
        const auto& a = d->arcs[i];
        if (a.n0 < 0 || a.n1 < 0 || (size_t)a.n0 >= d->nodes.size() || (size_t)a.n1 >= d->nodes.size()) continue;
        const auto& n0 = d->nodes[a.n0];
        const auto& n1 = d->nodes[a.n1];
        double r2 = dist_point_seg2(x, y, n0.x, n0.y, n1.x, n1.y);
        if (r2 < best2) { best2 = r2; best = (int)i; }
    }
    return best;
}

static femm_physics_t physics_from_prefix(const char* p) {
    switch (p[0]) {
        case 'm': return FEMM_PHYSICS_MAGNETICS;
        case 'e': return FEMM_PHYSICS_ELECTROSTATICS;
        case 'h': return FEMM_PHYSICS_HEAT;
        case 'c': return FEMM_PHYSICS_CURRENT;
    }
    return FEMM_PHYSICS_MAGNETICS;
}

static void require_physics(lua_State* L, Document* d, femm_physics_t p, const char* command) {
    if (d->physics != p) fail(L, std::string(command) + " requires the matching document type");
}

static void set_problem(lua_State* L, Document* d, femm_physics_t p, const char* command) {
    require_physics(L, d, p, command);
    int top = lua_gettop(L);
    if (p == FEMM_PHYSICS_MAGNETICS) {
        if (top >= 1) d->frequency = real_arg(L, 1, 0, false);
        if (top >= 2) d->length_units = (femm_length_units_t)int_arg(L, 2, FEMM_UNITS_MILLIMETERS, false);
        if (top >= 3) d->problem_type = (femm_problem_type_t)int_arg(L, 3, FEMM_PROBLEM_PLANAR, false);
        if (top >= 4) d->precision = real_arg(L, 4, d->precision, false);
        if (top >= 5) d->depth = real_arg(L, 5, d->depth, false);
        if (top >= 6) d->min_angle = real_arg(L, 6, d->min_angle, false);
        if (top >= 7) d->ac_solver = int_arg(L, 7, d->ac_solver, false);
    } else {
        if (top >= 1) d->length_units = (femm_length_units_t)int_arg(L, 1, FEMM_UNITS_MILLIMETERS, false);
        if (top >= 2) d->problem_type = (femm_problem_type_t)int_arg(L, 2, FEMM_PROBLEM_PLANAR, false);
        if (top >= 3 && p == FEMM_PHYSICS_CURRENT) d->frequency = real_arg(L, 3, 0, false);
        int off = p == FEMM_PHYSICS_CURRENT ? 1 : 0;
        if (top >= 3 + off) d->precision = real_arg(L, 3 + off, d->precision, false);
        if (top >= 4 + off) d->depth = real_arg(L, 4 + off, d->depth, false);
        if (top >= 5 + off) d->min_angle = real_arg(L, 5 + off, d->min_angle, false);
    }
}

static void clear_selection(LuaSession* s) {
    s->sel_nodes.clear();
    s->sel_segments.clear();
    s->sel_arcs.clear();
    s->sel_labels.clear();
}

static int add_material(lua_State* L, Document* d) {
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: {
            femm_mag_material_t m{};
            m.name = luaL_check_string(L, 1);
            m.mu_x = real_arg(L, 2, 1, false);
            m.mu_y = real_arg(L, 3, 1, false);
            m.H_c = real_arg(L, 4, 0, false);
            m.J_src = femm_c(complex_arg(L, 5, CComplex(0, 0), false));
            m.c_duct = real_arg(L, 6, 0, false);
            m.lam_d = real_arg(L, 7, 0, false);
            m.theta_hn = real_arg(L, 8, 0, false);
            m.lam_fill = real_arg(L, 9, 1, false);
            m.lam_type = int_arg(L, 10, 0, false);
            m.theta_hx = real_arg(L, 11, 0, false);
            m.theta_hy = real_arg(L, 12, 0, false);
            m.n_strands = int_arg(L, 13, 0, false);
            m.wire_d = real_arg(L, 14, 0, false);
            check_status(L, femm_mag_add_material(reinterpret_cast<femm_doc_t*>(d), &m));
            break;
        }
        case FEMM_PHYSICS_ELECTROSTATICS: {
            femm_es_material_t m{luaL_check_string(L, 1), real_arg(L, 2, 1, false), real_arg(L, 3, 1, false), real_arg(L, 4, 0, false)};
            check_status(L, femm_es_add_material(reinterpret_cast<femm_doc_t*>(d), &m));
            break;
        }
        case FEMM_PHYSICS_HEAT: {
            femm_heat_material_t m{luaL_check_string(L, 1), real_arg(L, 2, 1, false), real_arg(L, 3, 1, false), real_arg(L, 4, 0, false), real_arg(L, 5, 0, false)};
            check_status(L, femm_heat_add_material(reinterpret_cast<femm_doc_t*>(d), &m));
            break;
        }
        case FEMM_PHYSICS_CURRENT: {
            femm_curr_material_t m{luaL_check_string(L, 1), real_arg(L, 2, 1, false), real_arg(L, 3, 1, false), real_arg(L, 4, 1, false), real_arg(L, 5, 1, false), real_arg(L, 6, 0, false), real_arg(L, 7, 0, false)};
            check_status(L, femm_curr_add_material(reinterpret_cast<femm_doc_t*>(d), &m));
            break;
        }
    }
    return 0;
}

static int add_boundary(lua_State* L, Document* d) {
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: {
            femm_mag_boundary_t b{};
            b.name = luaL_check_string(L, 1);
            b.A0 = real_arg(L, 2, 0, false); b.A1 = real_arg(L, 3, 0, false);
            b.A2 = real_arg(L, 4, 0, false); b.phi = real_arg(L, 5, 0, false);
            b.bdry_format = int_arg(L, 6, 0, false);
            b.c0 = femm_c(complex_arg(L, 7, CComplex(0, 0), false));
            b.c1 = femm_c(complex_arg(L, 8, CComplex(0, 0), false));
            b.mu = real_arg(L, 9, 0, false); b.sig = real_arg(L, 10, 0, false);
            check_status(L, femm_mag_add_boundary(reinterpret_cast<femm_doc_t*>(d), &b));
            break;
        }
        case FEMM_PHYSICS_ELECTROSTATICS: {
            femm_es_boundary_t b{luaL_check_string(L, 1), int_arg(L, 4, 0, false), real_arg(L, 2, 0, false), real_arg(L, 3, 0, false), real_arg(L, 5, 0, false), real_arg(L, 6, 0, false)};
            check_status(L, femm_es_add_boundary(reinterpret_cast<femm_doc_t*>(d), &b));
            break;
        }
        case FEMM_PHYSICS_HEAT: {
            femm_heat_boundary_t b{};
            b.name = luaL_check_string(L, 1);
            b.bdry_format = int_arg(L, 2, 0, false);
            b.Tset = real_arg(L, 3, 0, false); b.qs = real_arg(L, 4, 0, false);
            b.beta = real_arg(L, 5, 0, false); b.h = real_arg(L, 6, 0, false);
            b.Tinf = real_arg(L, 7, 0, false); b.TinfRad = real_arg(L, 8, 0, false);
            check_status(L, femm_heat_add_boundary(reinterpret_cast<femm_doc_t*>(d), &b));
            break;
        }
        case FEMM_PHYSICS_CURRENT: {
            femm_curr_boundary_t b{};
            b.name = luaL_check_string(L, 1);
            b.Vs = femm_c(complex_arg(L, 2, CComplex(0, 0), false));
            b.qs = femm_c(complex_arg(L, 3, CComplex(0, 0), false));
            b.bdry_format = int_arg(L, 4, 0, false);
            b.c0 = femm_c(complex_arg(L, 5, CComplex(0, 0), false));
            b.c1 = femm_c(complex_arg(L, 6, CComplex(0, 0), false));
            check_status(L, femm_curr_add_boundary(reinterpret_cast<femm_doc_t*>(d), &b));
            break;
        }
    }
    return 0;
}

static int add_pointprop(lua_State* L, Document* d) {
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: {
            femm_mag_pointprop_t p{luaL_check_string(L, 1), femm_c(complex_arg(L, 2, CComplex(0, 0), false)), femm_c(complex_arg(L, 3, CComplex(0, 0), false))};
            check_status(L, femm_mag_add_pointprop(reinterpret_cast<femm_doc_t*>(d), &p));
            break;
        }
        case FEMM_PHYSICS_ELECTROSTATICS: {
            femm_es_pointprop_t p{luaL_check_string(L, 1), real_arg(L, 2, 0, false), real_arg(L, 3, 0, false)};
            check_status(L, femm_es_add_pointprop(reinterpret_cast<femm_doc_t*>(d), &p));
            break;
        }
        case FEMM_PHYSICS_HEAT: {
            femm_heat_pointprop_t p{luaL_check_string(L, 1), real_arg(L, 2, 0, false), real_arg(L, 3, 0, false)};
            check_status(L, femm_heat_add_pointprop(reinterpret_cast<femm_doc_t*>(d), &p));
            break;
        }
        case FEMM_PHYSICS_CURRENT: {
            femm_curr_pointprop_t p{luaL_check_string(L, 1), femm_c(complex_arg(L, 2, CComplex(0, 0), false)), femm_c(complex_arg(L, 3, CComplex(0, 0), false))};
            check_status(L, femm_curr_add_pointprop(reinterpret_cast<femm_doc_t*>(d), &p));
            break;
        }
    }
    return 0;
}

static int add_conductor(lua_State* L, Document* d) {
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: {
            femm_mag_circuit_t c{luaL_check_string(L, 1), femm_c(complex_arg(L, 2, CComplex(0, 0), false)), int_arg(L, 3, 0, false)};
            check_status(L, femm_mag_add_circuit(reinterpret_cast<femm_doc_t*>(d), &c));
            break;
        }
        case FEMM_PHYSICS_ELECTROSTATICS: {
            femm_es_conductor_t c{luaL_check_string(L, 1), real_arg(L, 2, 0, false), real_arg(L, 3, 0, false), int_arg(L, 4, 0, false)};
            check_status(L, femm_es_add_conductor(reinterpret_cast<femm_doc_t*>(d), &c));
            break;
        }
        case FEMM_PHYSICS_HEAT: {
            femm_heat_conductor_t c{luaL_check_string(L, 1), real_arg(L, 2, 0, false), real_arg(L, 3, 0, false), int_arg(L, 4, 0, false)};
            check_status(L, femm_heat_add_conductor(reinterpret_cast<femm_doc_t*>(d), &c));
            break;
        }
        case FEMM_PHYSICS_CURRENT: {
            femm_curr_conductor_t c{luaL_check_string(L, 1), femm_c(complex_arg(L, 2, CComplex(0, 0), false)), femm_c(complex_arg(L, 3, CComplex(0, 0), false)), int_arg(L, 4, 0, false)};
            check_status(L, femm_curr_add_conductor(reinterpret_cast<femm_doc_t*>(d), &c));
            break;
        }
    }
    return 0;
}

static int delete_named_prop(lua_State* L, Document* d, const char* kind) {
    std::string name = string_arg(L, 1);
    auto del_by_name = [&](auto& vec, auto deleter) {
        for (size_t i = 0; i < vec.size(); ++i) {
            if (vec[i].name == name) {
                check_status(L, deleter(reinterpret_cast<femm_doc_t*>(d), (int32_t)i));
                return true;
            }
        }
        return false;
    };
    bool ok = false;
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS:
            if (!strcmp(kind, "material")) ok = del_by_name(d->mag_materials, femm_mag_delete_material);
            else if (!strcmp(kind, "boundary")) ok = del_by_name(d->mag_boundaries, femm_mag_delete_boundary);
            else if (!strcmp(kind, "pointprop")) ok = del_by_name(d->mag_pointprops, femm_mag_delete_pointprop);
            else ok = del_by_name(d->mag_circuits, femm_mag_delete_circuit);
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            if (!strcmp(kind, "material")) ok = del_by_name(d->es_materials, femm_es_delete_material);
            else if (!strcmp(kind, "boundary")) ok = del_by_name(d->es_boundaries, femm_es_delete_boundary);
            else if (!strcmp(kind, "pointprop")) ok = del_by_name(d->es_pointprops, femm_es_delete_pointprop);
            else ok = del_by_name(d->es_conductors, femm_es_delete_conductor);
            break;
        case FEMM_PHYSICS_HEAT:
            if (!strcmp(kind, "material")) ok = del_by_name(d->heat_materials, femm_heat_delete_material);
            else if (!strcmp(kind, "boundary")) ok = del_by_name(d->heat_boundaries, femm_heat_delete_boundary);
            else if (!strcmp(kind, "pointprop")) ok = del_by_name(d->heat_pointprops, femm_heat_delete_pointprop);
            else ok = del_by_name(d->heat_conductors, femm_heat_delete_conductor);
            break;
        case FEMM_PHYSICS_CURRENT:
            if (!strcmp(kind, "material")) ok = del_by_name(d->curr_materials, femm_curr_delete_material);
            else if (!strcmp(kind, "boundary")) ok = del_by_name(d->curr_boundaries, femm_curr_delete_boundary);
            else if (!strcmp(kind, "pointprop")) ok = del_by_name(d->curr_pointprops, femm_curr_delete_pointprop);
            else ok = del_by_name(d->curr_conductors, femm_curr_delete_conductor);
            break;
    }
    if (!ok) fail(L, "property not found: " + name);
    return 0;
}

static void selected_nodes_for_geometry(LuaSession* s, Document* d, std::set<int>& nodes) {
    nodes.insert(s->sel_nodes.begin(), s->sel_nodes.end());
    for (int i : s->sel_segments) {
        if (i >= 0 && (size_t)i < d->segments.size()) {
            nodes.insert(d->segments[i].n0);
            nodes.insert(d->segments[i].n1);
        }
    }
    for (int i : s->sel_arcs) {
        if (i >= 0 && (size_t)i < d->arcs.size()) {
            nodes.insert(d->arcs[i].n0);
            nodes.insert(d->arcs[i].n1);
        }
    }
}

static void transform_selected(Document* d, LuaSession* s, const std::function<void(double&, double&)>& xf) {
    std::set<int> nodes;
    selected_nodes_for_geometry(s, d, nodes);
    for (int i : nodes) {
        if (i >= 0 && (size_t)i < d->nodes.size()) xf(d->nodes[i].x, d->nodes[i].y);
    }
    for (int i : s->sel_labels) {
        if (i >= 0 && (size_t)i < d->labels.size()) xf(d->labels[i].x, d->labels[i].y);
    }
}

static int duplicate_selected(Document* d, LuaSession* s, lua_State* L) {
    std::set<int> nodes;
    selected_nodes_for_geometry(s, d, nodes);
    std::map<int, int> map;
    for (int old : nodes) {
        if (old < 0 || (size_t)old >= d->nodes.size()) continue;
        int32_t ni = -1;
        check_status(L, femm_add_node(reinterpret_cast<femm_doc_t*>(d), d->nodes[old].x, d->nodes[old].y, &ni));
        d->nodes[ni].group = d->nodes[old].group;
        d->nodes[ni].bdry_idx = d->nodes[old].bdry_idx;
        d->nodes[ni].in_conductor = d->nodes[old].in_conductor;
        map[old] = ni;
    }
    std::set<int> new_segments, new_arcs, new_labels;
    for (int i : s->sel_segments) {
        if (i < 0 || (size_t)i >= d->segments.size()) continue;
        const auto old = d->segments[i];
        if (!map.count(old.n0) || !map.count(old.n1)) continue;
        int32_t si = -1;
        check_status(L, femm_add_segment(reinterpret_cast<femm_doc_t*>(d), map[old.n0], map[old.n1], &si));
        d->segments[si] = old;
        d->segments[si].n0 = map[old.n0];
        d->segments[si].n1 = map[old.n1];
        new_segments.insert(si);
    }
    for (int i : s->sel_arcs) {
        if (i < 0 || (size_t)i >= d->arcs.size()) continue;
        const auto old = d->arcs[i];
        if (!map.count(old.n0) || !map.count(old.n1)) continue;
        int32_t ai = -1;
        check_status(L, femm_add_arc(reinterpret_cast<femm_doc_t*>(d), map[old.n0], map[old.n1], old.arc_deg, old.max_side_deg, &ai));
        d->arcs[ai] = old;
        d->arcs[ai].n0 = map[old.n0];
        d->arcs[ai].n1 = map[old.n1];
        new_arcs.insert(ai);
    }
    for (int i : s->sel_labels) {
        if (i < 0 || (size_t)i >= d->labels.size()) continue;
        d->labels.push_back(d->labels[i]);
        new_labels.insert((int)d->labels.size() - 1);
    }
    s->sel_nodes.clear();
    for (auto& kv : map) s->sel_nodes.insert(kv.second);
    s->sel_segments = new_segments;
    s->sel_arcs = new_arcs;
    s->sel_labels = new_labels;
    return 0;
}

static int l_print(lua_State* L) {
    if (!g_session) return 0;
    int n = lua_gettop(L);
    g_session->output += "--> ";
    for (int i = 1; i <= n; ++i) {
        if (i > 1) g_session->output += "\t";
        const char* s = lua_tostring(L, i);
        g_session->output += s ? s : lua_typename(L, lua_type(L, i));
    }
    g_session->output += "\n";
    return 0;
}

static int l_error_message(lua_State* L) {
    if (g_session && lua_gettop(L) > 0) {
        const char* s = lua_tostring(L, 1);
        g_session->error = s ? s : "Lua error";
    }
    return 0;
}

static int l_showconsole(lua_State*) { if (g_session) g_session->console_visible = true; return 0; }
static int l_hideconsole(lua_State*) { if (g_session) g_session->console_visible = false; return 0; }
static int l_clearconsole(lua_State*) { if (g_session) g_session->output.clear(); return 0; }

static int l_complex(lua_State* L) {
    lua_pushnumber(L, CComplex(real_arg(L, 1, 0, false), real_arg(L, 2, 0, false)));
    return 1;
}

static int l_messagebox(lua_State* L) {
    if (g_session) {
        g_session->output += "--> ";
        g_session->output += lua_gettop(L) > 0 ? luaL_check_string(L, 1) : "";
        g_session->output += "\n";
    }
    return 0;
}

static int l_pause(lua_State*) { return 0; }
static int l_prompt(lua_State* L) { fail(L, "prompt is not supported in macFEMM yet"); return 0; }
static int l_quit(lua_State* L) { fail(L, "quit is not supported in macFEMM yet"); return 0; }
static int l_setcompatibilitymode(lua_State* L) { if (g_session) g_session->compatibility_mode = int_arg(L, 1, 0, false); return 0; }

static int l_chdir(lua_State* L) {
    if (!g_session) return 0;
    g_session->cwd = resolve_path(g_session, string_arg(L, 1));
    return 0;
}

static int l_open(lua_State* L) {
    if (!g_session) fail(L, "no active Lua session");
    std::string path = resolve_path(g_session, string_arg(L, 1));
    femm_doc_t* out = nullptr;
    check_status(L, femm_doc_open(path.c_str(), &out));
    if (g_session->replacement_doc) femm_doc_free(g_session->replacement_doc);
    if (g_session->replacement_result) femm_result_free(g_session->replacement_result);
    g_session->replacement_doc = out;
    g_session->replacement_doc_path = path;
    g_session->replacement_result = nullptr;
    g_session->replacement_result_path.clear();
    g_session->doc = out;
    g_session->result = nullptr;
    g_session->active_path = path;
    clear_selection(g_session);
    return 0;
}

static int l_newdocument(lua_State* L) {
    if (!g_session) fail(L, "no active Lua session");
    int n = int_arg(L, 1, 0, false);
    if (n < 0 || n > 3) fail(L, "newdocument expects 0=magnetics, 1=electrostatics, 2=heat, or 3=current");
    femm_doc_t* out = nullptr;
    check_status(L, femm_doc_new((femm_physics_t)n, &out));
    if (g_session->replacement_doc) femm_doc_free(g_session->replacement_doc);
    if (g_session->replacement_result) femm_result_free(g_session->replacement_result);
    g_session->replacement_doc = out;
    g_session->replacement_doc_path.clear();
    g_session->replacement_result = nullptr;
    g_session->replacement_result_path.clear();
    g_session->doc = out;
    g_session->result = nullptr;
    g_session->active_path.clear();
    clear_selection(g_session);
    return 0;
}

static int l_probdef(lua_State* L) { set_problem(L, require_doc(L), physics_from_prefix("m"), "mi_probdef"); return 0; }
static int l_e_probdef(lua_State* L) { set_problem(L, require_doc(L), physics_from_prefix("e"), "ei_probdef"); return 0; }
static int l_h_probdef(lua_State* L) { set_problem(L, require_doc(L), physics_from_prefix("h"), "hi_probdef"); return 0; }
static int l_c_probdef(lua_State* L) { set_problem(L, require_doc(L), physics_from_prefix("c"), "ci_probdef"); return 0; }

static int l_addnode(lua_State* L) {
    Document* d = require_doc(L);
    int32_t idx = -1;
    check_status(L, femm_add_node(reinterpret_cast<femm_doc_t*>(d), real_arg(L, 1), real_arg(L, 2), &idx));
    return 0;
}

static int l_addsegment(lua_State* L) {
    Document* d = require_doc(L);
    int n0 = find_or_add_node(L, d, real_arg(L, 1), real_arg(L, 2));
    int n1 = find_or_add_node(L, d, real_arg(L, 3), real_arg(L, 4));
    int32_t idx = -1;
    check_status(L, femm_add_segment(reinterpret_cast<femm_doc_t*>(d), n0, n1, &idx));
    return 0;
}

static int l_addarc(lua_State* L) {
    Document* d = require_doc(L);
    int n0 = find_or_add_node(L, d, real_arg(L, 1), real_arg(L, 2));
    int n1 = find_or_add_node(L, d, real_arg(L, 3), real_arg(L, 4));
    int32_t idx = -1;
    check_status(L, femm_add_arc(reinterpret_cast<femm_doc_t*>(d), n0, n1, real_arg(L, 5), real_arg(L, 6, 1, false), &idx));
    return 0;
}

static int l_addblocklabel(lua_State* L) {
    Document* d = require_doc(L);
    int32_t idx = -1;
    check_status(L, femm_add_block_label(reinterpret_cast<femm_doc_t*>(d), real_arg(L, 1), real_arg(L, 2), &idx));
    return 0;
}

static int l_clearselected(lua_State*) { if (g_session) clear_selection(g_session); return 0; }

static int l_selectnode(lua_State* L) {
    Document* d = require_doc(L);
    int idx = nearest_node(d, real_arg(L, 1), real_arg(L, 2));
    if (idx >= 0) g_session->sel_nodes.insert(idx);
    return 0;
}

static int l_selectlabel(lua_State* L) {
    Document* d = require_doc(L);
    int idx = nearest_label(d, real_arg(L, 1), real_arg(L, 2));
    if (idx >= 0) g_session->sel_labels.insert(idx);
    return 0;
}

static int l_selectsegment(lua_State* L) {
    Document* d = require_doc(L);
    int idx = nearest_segment(d, real_arg(L, 1), real_arg(L, 2));
    if (idx >= 0) g_session->sel_segments.insert(idx);
    return 0;
}

static int l_selectarc(lua_State* L) {
    Document* d = require_doc(L);
    int idx = nearest_arc(d, real_arg(L, 1), real_arg(L, 2));
    if (idx >= 0) g_session->sel_arcs.insert(idx);
    return 0;
}

static int l_selectgroup(lua_State* L) {
    Document* d = require_doc(L);
    int group = int_arg(L, 1);
    clear_selection(g_session);
    for (size_t i = 0; i < d->nodes.size(); ++i) if (d->nodes[i].group == group) g_session->sel_nodes.insert((int)i);
    for (size_t i = 0; i < d->segments.size(); ++i) if (d->segments[i].group == group) g_session->sel_segments.insert((int)i);
    for (size_t i = 0; i < d->arcs.size(); ++i) if (d->arcs[i].group == group) g_session->sel_arcs.insert((int)i);
    for (size_t i = 0; i < d->labels.size(); ++i) if (d->labels[i].group == group) g_session->sel_labels.insert((int)i);
    return 0;
}

static int l_setgroup(lua_State* L) {
    Document* d = require_doc(L);
    int group = int_arg(L, 1);
    for (int i : g_session->sel_nodes) if (i >= 0 && (size_t)i < d->nodes.size()) d->nodes[i].group = group;
    for (int i : g_session->sel_segments) if (i >= 0 && (size_t)i < d->segments.size()) d->segments[i].group = group;
    for (int i : g_session->sel_arcs) if (i >= 0 && (size_t)i < d->arcs.size()) d->arcs[i].group = group;
    for (int i : g_session->sel_labels) if (i >= 0 && (size_t)i < d->labels.size()) d->labels[i].group = group;
    return 0;
}

static int l_deleteselected(lua_State* L) {
    Document* d = require_doc(L);
    for (int i : std::vector<int>(g_session->sel_labels.rbegin(), g_session->sel_labels.rend())) femm_delete_label(reinterpret_cast<femm_doc_t*>(d), i);
    for (int i : std::vector<int>(g_session->sel_arcs.rbegin(), g_session->sel_arcs.rend())) femm_delete_arc(reinterpret_cast<femm_doc_t*>(d), i);
    for (int i : std::vector<int>(g_session->sel_segments.rbegin(), g_session->sel_segments.rend())) femm_delete_segment(reinterpret_cast<femm_doc_t*>(d), i);
    for (int i : std::vector<int>(g_session->sel_nodes.rbegin(), g_session->sel_nodes.rend())) femm_delete_node(reinterpret_cast<femm_doc_t*>(d), i);
    clear_selection(g_session);
    return 0;
}

static int l_setnodeprop(lua_State* L) {
    Document* d = require_doc(L);
    std::string name = string_arg(L, 1, "", false);
    int group = int_arg(L, 2, 0, false);
    for (int i : g_session->sel_nodes) if (i >= 0 && (size_t)i < d->nodes.size()) {
        d->nodes[i].bdry_idx = d->lookup_point_idx(name);
        d->nodes[i].group = group;
    }
    return 0;
}

static int l_setsegmentprop(lua_State* L) {
    Document* d = require_doc(L);
    std::string name = string_arg(L, 1, "", false);
    double max_side = real_arg(L, 2, -1, false);
    int hidden = int_arg(L, 3, 0, false);
    int group = int_arg(L, 4, 0, false);
    int conductor = d->lookup_conductor_idx(string_arg(L, 5, "", false));
    for (int i : g_session->sel_segments) if (i >= 0 && (size_t)i < d->segments.size()) {
        d->segments[i].bdry_idx = d->lookup_bdry_idx(name);
        d->segments[i].max_side = max_side;
        d->segments[i].hidden = hidden;
        d->segments[i].group = group;
        d->segments[i].in_conductor = conductor;
    }
    return 0;
}

static int l_setarcsegmentprop(lua_State* L) {
    Document* d = require_doc(L);
    double max_side = real_arg(L, 1, 1, false);
    std::string name = string_arg(L, 2, "", false);
    int hidden = int_arg(L, 3, 0, false);
    int group = int_arg(L, 4, 0, false);
    int conductor = d->lookup_conductor_idx(string_arg(L, 5, "", false));
    for (int i : g_session->sel_arcs) if (i >= 0 && (size_t)i < d->arcs.size()) {
        d->arcs[i].max_side_deg = max_side;
        d->arcs[i].bdry_idx = d->lookup_bdry_idx(name);
        d->arcs[i].hidden = hidden;
        d->arcs[i].group = group;
        d->arcs[i].in_conductor = conductor;
    }
    return 0;
}

static int l_setblockprop(lua_State* L) {
    Document* d = require_doc(L);
    std::string mat = string_arg(L, 1, "", false);
    int automesh = int_arg(L, 2, 1, false);
    double max_area = real_arg(L, 3, -1, false);
    std::string circuit = string_arg(L, 4, "", false);
    double magdir = real_arg(L, 5, 0, false);
    int group = int_arg(L, 6, 0, false);
    int turns = int_arg(L, 7, 1, false);
    for (int i : g_session->sel_labels) if (i >= 0 && (size_t)i < d->labels.size()) {
        d->labels[i].block_idx = d->lookup_block_idx(mat);
        d->labels[i].max_area = automesh ? -1 : max_area;
        d->labels[i].circuit_idx = d->lookup_conductor_idx(circuit);
        d->labels[i].mag_dir = magdir;
        d->labels[i].group = group;
        d->labels[i].turns = turns;
    }
    return 0;
}

static int l_movetranslate(lua_State* L) {
    Document* d = require_doc(L);
    double dx = real_arg(L, 1), dy = real_arg(L, 2);
    transform_selected(d, g_session, [=](double& x, double& y){ x += dx; y += dy; });
    return 0;
}

static int l_copytranslate(lua_State* L) {
    Document* d = require_doc(L);
    int copies = std::max(1, int_arg(L, 3, 1, false));
    double dx = real_arg(L, 1), dy = real_arg(L, 2);
    for (int k = 0; k < copies; ++k) {
        duplicate_selected(d, g_session, L);
        transform_selected(d, g_session, [=](double& x, double& y){ x += dx; y += dy; });
    }
    return 0;
}

static int l_moverotate(lua_State* L) {
    Document* d = require_doc(L);
    double cx = real_arg(L, 1), cy = real_arg(L, 2), a = real_arg(L, 3) * M_PI / 180.0;
    double cs = cos(a), sn = sin(a);
    transform_selected(d, g_session, [=](double& x, double& y) {
        double vx = x - cx, vy = y - cy;
        x = cx + vx * cs - vy * sn;
        y = cy + vx * sn + vy * cs;
    });
    return 0;
}

static int l_copyrotate(lua_State* L) {
    Document* d = require_doc(L);
    int copies = std::max(1, int_arg(L, 4, 1, false));
    for (int k = 0; k < copies; ++k) {
        duplicate_selected(d, g_session, L);
        l_moverotate(L);
    }
    return 0;
}

static int l_mirror(lua_State* L) {
    Document* d = require_doc(L);
    double x1 = real_arg(L, 1), y1 = real_arg(L, 2), x2 = real_arg(L, 3), y2 = real_arg(L, 4);
    double dx = x2 - x1, dy = y2 - y1, len2 = dx * dx + dy * dy;
    if (len2 <= 0) return 0;
    transform_selected(d, g_session, [=](double& x, double& y) {
        double px = x - x1, py = y - y1;
        double t = (px * dx + py * dy) / len2;
        double qx = x1 + t * dx, qy = y1 + t * dy;
        x = 2 * qx - x;
        y = 2 * qy - y;
    });
    return 0;
}

static int l_scale(lua_State* L) {
    Document* d = require_doc(L);
    double bx = real_arg(L, 1), by = real_arg(L, 2), sc = real_arg(L, 3, 1, false);
    transform_selected(d, g_session, [=](double& x, double& y){ x = bx + (x - bx) * sc; y = by + (y - by) * sc; });
    return 0;
}

static int l_addmaterial(lua_State* L) { return add_material(L, require_doc(L)); }
static int l_addboundprop(lua_State* L) { return add_boundary(L, require_doc(L)); }
static int l_addpointprop(lua_State* L) { return add_pointprop(L, require_doc(L)); }
static int l_addcircprop(lua_State* L) { return add_conductor(L, require_doc(L)); }
static int l_delmaterial(lua_State* L) { return delete_named_prop(L, require_doc(L), "material"); }
static int l_delboundprop(lua_State* L) { return delete_named_prop(L, require_doc(L), "boundary"); }
static int l_delpointprop(lua_State* L) { return delete_named_prop(L, require_doc(L), "pointprop"); }
static int l_delcircprop(lua_State* L) { return delete_named_prop(L, require_doc(L), "conductor"); }

static int l_addbhpoint(lua_State* L) {
    Document* d = require_doc(L);
    require_physics(L, d, FEMM_PHYSICS_MAGNETICS, "mi_addbhpoint");
    check_status(L, femm_mag_add_bh_point(reinterpret_cast<femm_doc_t*>(d), luaL_check_string(L, 1), real_arg(L, 2), real_arg(L, 3)));
    return 0;
}

static int l_clearbhpoints(lua_State* L) {
    Document* d = require_doc(L);
    std::string name = string_arg(L, 1);
    for (size_t i = 0; i < d->mag_materials.size(); ++i) {
        if (d->mag_materials[i].name == name) {
            check_status(L, femm_mag_clear_bh(reinterpret_cast<femm_doc_t*>(d), (int32_t)i));
            return 0;
        }
    }
    fail(L, "material not found: " + name);
    return 0;
}

static int l_saveas(lua_State* L) {
    Document* d = require_doc(L);
    std::string path = resolve_path(g_session, string_arg(L, 1));
    check_status(L, femm_doc_save(reinterpret_cast<femm_doc_t*>(d), path.c_str()));
    g_session->active_path = path;
    g_session->replacement_doc_path = path;
    return 0;
}

static int l_save(lua_State* L) {
    Document* d = require_doc(L);
    std::string path = g_session->active_path.empty() ? default_root(g_session, d) : g_session->active_path;
    check_status(L, femm_doc_save(reinterpret_cast<femm_doc_t*>(d), path.c_str()));
    g_session->active_path = path;
    g_session->replacement_doc_path = path;
    return 0;
}

static int l_createmesh(lua_State* L) {
    Document* d = require_doc(L);
    std::string root = default_root(g_session, d);
    check_status(L, femm_doc_create_mesh(reinterpret_cast<femm_doc_t*>(d), root.c_str()));
    return 0;
}

static int l_analyze(lua_State* L) {
    Document* d = require_doc(L);
    std::string root = default_root(g_session, d);
    check_status(L, femm_doc_create_mesh(reinterpret_cast<femm_doc_t*>(d), root.c_str()));
    check_status(L, femm_doc_analyze(reinterpret_cast<femm_doc_t*>(d), root.c_str(), nullptr, nullptr));
    return 0;
}

static int l_loadsolution(lua_State* L) {
    Document* d = require_doc(L);
    std::string root = default_root(g_session, d);
    std::string res = root + femmcore::result_ext_for(d->physics);
    femm_result_t* out = nullptr;
    check_status(L, femm_result_load(res.c_str(), d->physics, &out));
    if (g_session->replacement_result) femm_result_free(g_session->replacement_result);
    g_session->replacement_result = out;
    g_session->replacement_result_path = res;
    g_session->result = out;
    return 0;
}

static int l_getpointvalues(lua_State* L) {
    Document* d = require_doc(L);
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    double scalar = 0, v[2] = {0, 0};
    check_status(L, femm_result_point_values(g_session->result, reinterpret_cast<femm_doc_t*>(d), real_arg(L, 1), real_arg(L, 2), &scalar, v));
    push_real(L, scalar);
    push_real(L, v[0]);
    push_real(L, v[1]);
    push_real(L, std::sqrt(v[0] * v[0] + v[1] * v[1]));
    return 4;
}

static int l_numnodes(lua_State* L) {
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    push_real(L, (double)femm_result_num_nodes(g_session->result));
    return 1;
}

static int l_numelements(lua_State* L) {
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    push_real(L, (double)femm_result_num_elements(g_session->result));
    return 1;
}

static int l_getnode(lua_State* L) {
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    int idx = int_arg(L, 1) - 1;
    size_t n = femm_result_num_nodes(g_session->result);
    if (idx < 0 || (size_t)idx >= n) fail(L, "node index out of range");
    std::vector<double> x(n), y(n);
    check_status(L, femm_result_get_node_xy(g_session->result, x.data(), y.data()));
    push_real(L, x[idx]);
    push_real(L, y[idx]);
    return 2;
}

static int l_getelement(lua_State* L) {
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    int idx = int_arg(L, 1) - 1;
    size_t m = femm_result_num_elements(g_session->result);
    if (idx < 0 || (size_t)idx >= m) fail(L, "element index out of range");
    std::vector<int32_t> e(3 * m);
    std::vector<int32_t> labels(m);
    std::vector<double> cx(m), cy(m);
    check_status(L, femm_result_get_elements(g_session->result, e.data()));
    check_status(L, femm_result_get_element_labels(g_session->result, labels.data()));
    check_status(L, femm_result_get_element_centroids(g_session->result, cx.data(), cy.data()));
    push_real(L, e[3 * idx] + 1);
    push_real(L, e[3 * idx + 1] + 1);
    push_real(L, e[3 * idx + 2] + 1);
    push_real(L, cx[idx]);
    push_real(L, cy[idx]);
    push_real(L, labels[idx]);
    return 6;
}

static int l_addcontour(lua_State* L) {
    if (!g_session) return 0;
    g_session->contour_xy.push_back(real_arg(L, 1));
    g_session->contour_xy.push_back(real_arg(L, 2));
    return 0;
}

static int l_clearcontour(lua_State*) { if (g_session) g_session->contour_xy.clear(); return 0; }

static int l_lineintegral(lua_State* L) {
    Document* d = require_doc(L);
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    int32_t count = 0;
    femm_complex_t out[4] = {};
    size_t npts = g_session->contour_xy.size() / 2;
    if (npts < 2) fail(L, "line integral requires at least two contour points");
    int type = int_arg(L, 1);
    femm_status_t st = FEMM_ERR_UNSUPPORTED;
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: st = femm_result_mag_line_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, g_session->contour_xy.data(), npts, 0, out, &count); break;
        case FEMM_PHYSICS_ELECTROSTATICS: st = femm_result_es_line_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, g_session->contour_xy.data(), npts, 0, out, &count); break;
        case FEMM_PHYSICS_HEAT: st = femm_result_heat_line_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, g_session->contour_xy.data(), npts, 0, out, &count); break;
        case FEMM_PHYSICS_CURRENT: st = femm_result_curr_line_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, g_session->contour_xy.data(), npts, 0, out, &count); break;
    }
    check_status(L, st);
    for (int i = 0; i < count; ++i) push_complex(L, out[i]);
    return count;
}

static int l_blockintegral(lua_State* L) {
    Document* d = require_doc(L);
    if (!g_session || !g_session->result) fail(L, "no loaded solution");
    std::vector<int32_t> mask(d->labels.size(), 0);
    for (int i : g_session->sel_labels) if (i >= 0 && (size_t)i < mask.size()) mask[i] = 1;
    const int32_t* mp = g_session->sel_labels.empty() ? nullptr : mask.data();
    femm_complex_t out{};
    int type = int_arg(L, 1);
    femm_status_t st = FEMM_ERR_UNSUPPORTED;
    switch (d->physics) {
        case FEMM_PHYSICS_MAGNETICS: st = femm_result_mag_block_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, mp, mask.size(), &out); break;
        case FEMM_PHYSICS_ELECTROSTATICS: st = femm_result_es_block_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, mp, mask.size(), &out); break;
        case FEMM_PHYSICS_HEAT: st = femm_result_heat_block_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, mp, mask.size(), &out); break;
        case FEMM_PHYSICS_CURRENT: st = femm_result_curr_block_integral(g_session->result, reinterpret_cast<femm_doc_t*>(d), type, mp, mask.size(), &out); break;
    }
    check_status(L, st);
    push_complex(L, out);
    return 1;
}

static int l_smartmesh(lua_State* L) {
    Document* d = require_doc(L);
    d->smart_mesh = int_arg(L, 1, 1, false) ? 1 : 0;
    return 0;
}

static int l_seteditmode(lua_State* L) { if (g_session) g_session->edit_mode = int_arg(L, 1, 4, false); return 0; }
static int l_noop(lua_State*) { return 0; }

static int l_unsupported(lua_State* L) {
    std::string name = string_arg(L, 1, "command", false);
    fail(L, name + " is not supported in macFEMM yet");
    return 0;
}

static const Command kSupported[] = {
    {"print", l_print}, {"showconsole", l_showconsole}, {"hideconsole", l_hideconsole},
    {"show_console", l_showconsole}, {"hide_console", l_hideconsole},
    {"clearconsole", l_clearconsole}, {"clear_console", l_clearconsole},
    {"Complex", l_complex}, {"messagebox", l_messagebox}, {"_ALERT", l_messagebox},
    {"pause", l_pause}, {"prompt", l_prompt}, {"quit", l_quit}, {"exit", l_quit},
    {"open", l_open}, {"create", l_newdocument}, {"newdocument", l_newdocument},
    {"new_document", l_newdocument}, {"setcurrentdirectory", l_chdir}, {"chdir", l_chdir},
    {"setcompatibilitymode", l_setcompatibilitymode}, {"smartmesh", l_smartmesh},
    {"showpointprops", l_noop}, {"hidepointprops", l_noop},
    {"show_point_props", l_noop}, {"hide_point_props", l_noop},
    {"main_maximize", l_noop}, {"main_minimize", l_noop}, {"main_resize", l_noop},
    {"main_restore", l_noop},
};

static const char* kPreOps[] = {
    "addnode", "add_node", "addsegment", "add_segment", "addarc", "add_arc",
    "addblocklabel", "add_block_label", "clearselected", "clear_selected",
    "selectnode", "select_node", "selectsegment", "select_segment",
    "selectarcsegment", "select_arc_segment", "select_arcsegment", "selectlabel", "select_label",
    "selectgroup", "select_group", "setgroup", "set_group", "seteditmode", "set_edit_mode",
    "deleteselected", "delete_selected", "deleteselectednodes", "delete_selected_nodes",
    "deleteselectedsegments", "delete_selected_segments",
    "deleteselectedarcsegments", "delete_selected_arc_segments",
    "delete_selected_arcsegments",
    "deleteselectedlabels", "delete_selected_labels",
    "setnodeprop", "set_node_prop", "setsegmentprop", "set_segment_prop",
    "setarcsegmentprop", "set_arc_segment_prop", "set_arcsegment_prop", "setblockprop", "set_block_prop",
    "movetranslate", "move_translate", "copytranslate", "copy_translate",
    "moverotate", "move_rotate", "copyrotate", "copy_rotate", "mirror", "scale",
    "addmaterial", "add_material", "addboundprop", "add_bound_prop",
    "addpointprop", "add_point_prop", "delmaterial", "deletematerial", "delete_material",
    "delboundprop", "deleteboundprop", "delete_bound_prop", "delpointprop",
    "deletepointprop", "delete_point_prop",
    "addconductorprop", "add_conductor_prop", "deleteconductor", "delete_conductor",
    "addtkpoint", "add_tk_point", "cleartkpoints", "clear_tk_points",
    "modifyboundprop", "modify_bound_prop", "modifymaterial", "modify_material",
    "modifypointprop", "modify_point_prop", "modifyconductorprop", "modify_conductor_prop",
    "modifycircprop", "modify_circ_prop",
    "saveas", "save_as", "save", "savebitmap", "save_bitmap", "savedxf", "save_dxf",
    "savemetafile", "save_metafile", "readdxf", "read_dxf",
    "createmesh", "create_mesh", "analyze", "analyse", "loadsolution",
    "load_solution", "newdocument", "new_document", "probdef", "prob_def",
    "getmaterial", "get_material", "getprobleminfo", "getboundingbox", "gettitle",
    "get_title", "setcomment", "smartmesh", "showgrid", "show_grid", "hidegrid",
    "hide_grid", "showmesh", "show_mesh", "hidemesh", "hide_mesh", "refreshview",
    "refrescview", "refresh_view", "zoomnatural", "zoom_natural", "zoomout", "zoom_out",
    "zoomin", "zoom_in", "zoom", "grid_snap", "gridsnap", "setgrid", "set_grid",
    "show_names", "shownames", "set_focus", "setfocus", "maximize", "minimize",
    "resize", "restore", "selectcircle", "select_circle", "selectrectangle",
    "select_rectangle", "attachdefault", "attach_default", "detachdefault",
    "detach_default", "attachouterspace", "attach_outer_space", "detachouterspace",
    "detach_outer_space", "defineouterspace", "define_outer_space", "createradius",
    "create_radius", "purgemesh", "purge_mesh", "close"
};

static const char* kMagOnly[] = {
    "addcircprop", "add_circ_prop", "deletecircuit", "delete_circuit",
    "delcircprop", "delete_circ_prop", "addbhpoint", "add_bh_point",
    "clearbhpoints", "clear_bh_points", "setprevious", "set_previous"
};

static const char* kPostOps[] = {
    "getpointvalues", "get_point_values", "numnodes", "num_nodes", "numelements",
    "num_elements", "getnode", "get_node", "getelement", "get_element",
    "getprobleminfo", "get_problem_info", "gettitle", "get_title",
    "getcircuitproperties", "get_circuit_properties", "getconductorproperties",
    "get_conductor_properties", "getgapa", "get_gap_a", "getgapb", "get_gap_b",
    "getgapharmonics", "get_gap_harmonics", "gradient",
    "addcontour", "add_contour", "clearcontour", "clear_contour", "bendcontour",
    "bend_contour", "lineintegral", "line_integral", "blockintegral", "block_integral",
    "gapintegral", "gap_integral",
    "clearblock", "clear_block", "selectblock", "select_block", "groupselectblock",
    "group_select_block", "selectpoint", "select_point", "selectconductor",
    "select_conductor", "smooth", "showdensityplot", "show_density_plot",
    "hidedensityplot", "hide_density_plot", "showcontourplot", "show_contour_plot",
    "hidecontourplot", "hide_contour_plot", "showvectorplot", "show_vector_plot",
    "hidevectorplot", "hide_vector_plot", "showpoints", "show_points", "hidepoints",
    "hide_points", "showmesh", "show_mesh", "hidemesh", "hide_mesh", "shownames",
    "show_names", "showgrid", "show_grid", "hidegrid",
    "hide_grid", "refreshview", "refrescview", "refresh_view", "reload",
    "zoomnatural", "zoom_natural",
    "zoomout", "zoom_out", "zoomin", "zoom_in", "zoom", "makeplot"
    , "make_plot", "savebitmap", "save_bitmap", "savemetafile", "save_metafile",
    "seteditmode", "set_edit_mode", "setgrid", "set_grid", "setfocus", "set_focus",
    "setweightingscheme", "set_weighting_scheme", "maximize", "minimize", "resize",
    "restore", "close", "gridsnap", "grid_snap"
};

static std::vector<std::string> build_command_names() {
    std::set<std::string> names;
    for (const auto& c : kSupported) names.insert(c.name);
    const char* pp[] = {"mi", "ei", "hi", "ci"};
    for (const char* p : pp) for (const char* op : kPreOps) names.insert(std::string(p) + "_" + op);
    for (const char* op : kMagOnly) names.insert(std::string("mi_") + op);
    const char* vp[] = {"mo", "eo", "ho", "co"};
    for (const char* p : vp) for (const char* op : kPostOps) names.insert(std::string(p) + "_" + op);
    names.insert("actxprint");
    names.insert("lua2matlab");
    names.insert("flput");
    names.insert("makeplot");
    names.insert("mlopen");
    names.insert("mlclose");
    names.insert("mlput");
    return std::vector<std::string>(names.begin(), names.end());
}

static const std::vector<std::string>& registry_names() {
    static const std::vector<std::string> names = build_command_names();
    return names;
}

static lua_CFunction pre_fn_for(const std::string& op, const std::string& prefix) {
    if (op == "probdef" || op == "prob_def") {
        if (prefix == "mi") return l_probdef;
        if (prefix == "ei") return l_e_probdef;
        if (prefix == "hi") return l_h_probdef;
        return l_c_probdef;
    }
    if (op == "newdocument" || op == "new_document") return l_newdocument;
    if (op == "addnode" || op == "add_node") return l_addnode;
    if (op == "addsegment" || op == "add_segment") return l_addsegment;
    if (op == "addarc" || op == "add_arc") return l_addarc;
    if (op == "addblocklabel" || op == "add_block_label") return l_addblocklabel;
    if (op == "clearselected" || op == "clear_selected") return l_clearselected;
    if (op == "selectnode" || op == "select_node") return l_selectnode;
    if (op == "selectsegment" || op == "select_segment") return l_selectsegment;
    if (op == "selectarcsegment" || op == "select_arc_segment" || op == "select_arcsegment") return l_selectarc;
    if (op == "selectlabel" || op == "select_label") return l_selectlabel;
    if (op == "selectgroup" || op == "select_group") return l_selectgroup;
    if (op == "setgroup" || op == "set_group") return l_setgroup;
    if (op == "seteditmode" || op == "set_edit_mode") return l_seteditmode;
    if (op == "deleteselected" || op == "delete_selected" ||
        op == "deleteselectednodes" || op == "delete_selected_nodes" ||
        op == "deleteselectedsegments" || op == "delete_selected_segments" ||
        op == "deleteselectedarcsegments" || op == "delete_selected_arc_segments" ||
        op == "delete_selected_arcsegments" ||
        op == "deleteselectedlabels" || op == "delete_selected_labels") return l_deleteselected;
    if (op == "setnodeprop" || op == "set_node_prop") return l_setnodeprop;
    if (op == "setsegmentprop" || op == "set_segment_prop") return l_setsegmentprop;
    if (op == "setarcsegmentprop" || op == "set_arc_segment_prop" || op == "set_arcsegment_prop") return l_setarcsegmentprop;
    if (op == "setblockprop" || op == "set_block_prop") return l_setblockprop;
    if (op == "movetranslate" || op == "move_translate") return l_movetranslate;
    if (op == "copytranslate" || op == "copy_translate") return l_copytranslate;
    if (op == "moverotate" || op == "move_rotate") return l_moverotate;
    if (op == "copyrotate" || op == "copy_rotate") return l_copyrotate;
    if (op == "mirror") return l_mirror;
    if (op == "scale") return l_scale;
    if (op == "addmaterial" || op == "add_material") return l_addmaterial;
    if (op == "addboundprop" || op == "add_bound_prop") return l_addboundprop;
    if (op == "addpointprop" || op == "add_point_prop") return l_addpointprop;
    if (op == "delmaterial" || op == "deletematerial" || op == "delete_material") return l_delmaterial;
    if (op == "delboundprop" || op == "deleteboundprop" || op == "delete_bound_prop") return l_delboundprop;
    if (op == "delpointprop" || op == "deletepointprop" || op == "delete_point_prop") return l_delpointprop;
    if (prefix == "mi" && (op == "addcircprop" || op == "add_circ_prop")) return l_addcircprop;
    if (op == "addconductorprop" || op == "add_conductor_prop") return l_addcircprop;
    if (op == "delcircprop" || op == "delete_circ_prop" || op == "deletecircuit" ||
        op == "delete_circuit" || op == "deleteconductor" || op == "delete_conductor") return l_delcircprop;
    if (prefix == "mi" && (op == "addbhpoint" || op == "add_bh_point")) return l_addbhpoint;
    if (prefix == "mi" && (op == "clearbhpoints" || op == "clear_bh_points")) return l_clearbhpoints;
    if (op == "saveas" || op == "save_as") return l_saveas;
    if (op == "save") return l_save;
    if (op == "createmesh" || op == "create_mesh") return l_createmesh;
    if (op == "analyze" || op == "analyse") return l_analyze;
    if (op == "loadsolution" || op == "load_solution") return l_loadsolution;
    if (op == "smartmesh") return l_smartmesh;
    if (op == "showgrid" || op == "show_grid" || op == "hidegrid" || op == "hide_grid" ||
        op == "showmesh" || op == "show_mesh" || op == "hidemesh" || op == "hide_mesh" ||
        op == "refreshview" || op == "refrescview" || op == "refresh_view" || op == "zoomnatural" ||
        op == "zoom_natural" || op == "zoomout" || op == "zoom_out" || op == "zoomin" ||
        op == "zoom_in" || op == "zoom" || op == "grid_snap" || op == "gridsnap" ||
        op == "setgrid" || op == "set_grid" || op == "close" || op == "show_names" ||
        op == "shownames" || op == "set_focus" || op == "setfocus" || op == "maximize" ||
        op == "minimize" || op == "resize" || op == "restore") return l_noop;
    return nullptr;
}

static lua_CFunction post_fn_for(const std::string& op) {
    if (op == "getpointvalues" || op == "get_point_values") return l_getpointvalues;
    if (op == "numnodes" || op == "num_nodes") return l_numnodes;
    if (op == "numelements" || op == "num_elements") return l_numelements;
    if (op == "getnode" || op == "get_node") return l_getnode;
    if (op == "getelement" || op == "get_element") return l_getelement;
    if (op == "addcontour" || op == "add_contour") return l_addcontour;
    if (op == "clearcontour" || op == "clear_contour") return l_clearcontour;
    if (op == "lineintegral" || op == "line_integral") return l_lineintegral;
    if (op == "blockintegral" || op == "block_integral") return l_blockintegral;
    if (op == "clearblock" || op == "clear_block") return l_clearselected;
    if (op == "selectblock" || op == "select_block") return l_selectlabel;
    if (op == "groupselectblock" || op == "group_select_block") return l_selectgroup;
    if (op == "smooth" || op == "showdensityplot" || op == "show_density_plot" ||
        op == "hidedensityplot" || op == "hide_density_plot" || op == "showcontourplot" ||
        op == "show_contour_plot" || op == "hidecontourplot" || op == "hide_contour_plot" ||
        op == "showvectorplot" || op == "show_vector_plot" || op == "hidevectorplot" ||
        op == "hide_vector_plot" || op == "showpoints" || op == "show_points" ||
        op == "hidepoints" || op == "hide_points" || op == "showmesh" || op == "show_mesh" ||
        op == "hidemesh" || op == "hide_mesh" || op == "shownames" || op == "show_names" ||
        op == "showgrid" || op == "show_grid" ||
        op == "hidegrid" || op == "hide_grid" || op == "refreshview" ||
        op == "refrescview" || op == "refresh_view" || op == "reload" ||
        op == "zoomnatural" || op == "zoom_natural" ||
        op == "zoomout" || op == "zoom_out" || op == "zoomin" || op == "zoom_in" ||
        op == "zoom" || op == "seteditmode" || op == "set_edit_mode" ||
        op == "setgrid" || op == "set_grid" || op == "setfocus" || op == "set_focus" ||
        op == "maximize" || op == "minimize" || op == "resize" || op == "restore" ||
        op == "close" || op == "gridsnap" || op == "grid_snap") return l_noop;
    return nullptr;
}

static void register_unsupported(lua_State* L, const std::string& name) {
    std::string code = name + " = function(...) __macfemm_unsupported(\"" + name + "\") end";
    lua_dostring(L, code.c_str());
}

static void register_commands(lua_State* L) {
    lua_baselibopen(L);
    lua_iolibopen(L);
    lua_strlibopen(L);
    lua_mathlibopen(L);
    lua_dblibopen(L);
    lua_register(L, "__macfemm_unsupported", l_unsupported);
    lua_register(L, "_ERRORMESSAGE", l_error_message);

    for (const auto& c : kSupported) lua_register(L, c.name, c.fn);

    const char* pre[] = {"mi", "ei", "hi", "ci"};
    for (const char* p : pre) {
        std::string prefix(p);
        for (const char* op_c : kPreOps) {
            std::string op(op_c), name = prefix + "_" + op;
            lua_CFunction fn = pre_fn_for(op, prefix);
            if (fn) lua_register(L, name.c_str(), fn);
            else register_unsupported(L, name);
        }
    }
    for (const char* op_c : kMagOnly) {
        std::string op(op_c), name = std::string("mi_") + op;
        lua_CFunction fn = pre_fn_for(op, "mi");
        if (fn) lua_register(L, name.c_str(), fn);
        else register_unsupported(L, name);
    }

    const char* post[] = {"mo", "eo", "ho", "co"};
    for (const char* p : post) {
        for (const char* op_c : kPostOps) {
            std::string op(op_c), name = std::string(p) + "_" + op;
            lua_CFunction fn = post_fn_for(op);
            if (fn) lua_register(L, name.c_str(), fn);
            else register_unsupported(L, name);
        }
    }

    register_unsupported(L, "actxprint");
    register_unsupported(L, "lua2matlab");
    register_unsupported(L, "flput");
    register_unsupported(L, "makeplot");
    register_unsupported(L, "mlopen");
    register_unsupported(L, "mlclose");
    register_unsupported(L, "mlput");
}

} // namespace

extern "C" {

femm_status_t femm_lua_session_new(femm_lua_session_t** out) {
    if (!out) return FEMM_ERR_INVALID_ARG;
    auto* s = new (std::nothrow) LuaSession();
    if (!s) return FEMM_ERR_OUT_OF_MEM;
    s->L = lua_open(0);
    if (!s->L) { delete s; return FEMM_ERR_OUT_OF_MEM; }
    register_commands(s->L);
    s->cwd = process_cwd();
    *out = reinterpret_cast<femm_lua_session_t*>(s);
    return FEMM_OK;
}

void femm_lua_session_free(femm_lua_session_t* ss) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s) return;
    if (s->replacement_doc) femm_doc_free(s->replacement_doc);
    if (s->replacement_result) femm_result_free(s->replacement_result);
    if (s->L) lua_close(s->L);
    delete s;
}

void femm_lua_session_set_active(femm_lua_session_t* ss, femm_doc_t* d, femm_result_t* r, const char* path) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s) return;
    s->doc = d;
    s->result = r;
    s->active_path = path ? path : "";
}

femm_status_t femm_lua_eval(femm_lua_session_t* ss, const char* text) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s || !s->L || !text) return FEMM_ERR_INVALID_ARG;
    s->error.clear();
    g_session = s;
    int st = lua_dostring(s->L, text);
    g_session = nullptr;
    if (st != 0) {
        if (s->error.empty()) {
            const char* err = lua_tostring(s->L, -1);
            s->error = err ? err : "Lua error";
        }
        lua_pop(s->L, 1);
        femmcore::set_last_error(s->error);
        return FEMM_ERR_LUA;
    }
    return FEMM_OK;
}

femm_status_t femm_lua_eval_file(femm_lua_session_t* ss, const char* path) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s || !s->L || !path) return FEMM_ERR_INVALID_ARG;
    s->error.clear();
    g_session = s;
    int st = lua_dofile(s->L, path);
    g_session = nullptr;
    if (st != 0) {
        if (s->error.empty()) {
            const char* err = lua_tostring(s->L, -1);
            s->error = err ? err : "Lua error";
        }
        lua_pop(s->L, 1);
        femmcore::set_last_error(s->error);
        return FEMM_ERR_LUA;
    }
    return FEMM_OK;
}

const char* femm_lua_output(const femm_lua_session_t* ss) {
    auto* s = reinterpret_cast<const LuaSession*>(ss);
    return s ? s->output.c_str() : "";
}

const char* femm_lua_error(const femm_lua_session_t* ss) {
    auto* s = reinterpret_cast<const LuaSession*>(ss);
    return s ? s->error.c_str() : "";
}

void femm_lua_clear_output(femm_lua_session_t* ss) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (s) s->output.clear();
}

int32_t femm_lua_take_replacement_doc(femm_lua_session_t* ss, femm_doc_t** out_doc, femm_physics_t* out_physics, const char** out_path) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s || !out_doc) return 0;
    *out_doc = s->replacement_doc;
    if (out_physics && s->replacement_doc) *out_physics = femm_doc_physics(s->replacement_doc);
    if (out_path) *out_path = s->replacement_doc_path.empty() ? nullptr : s->replacement_doc_path.c_str();
    int32_t present = s->replacement_doc ? 1 : 0;
    s->replacement_doc = nullptr;
    return present;
}

int32_t femm_lua_take_replacement_result(femm_lua_session_t* ss, femm_result_t** out_result, const char** out_path) {
    auto* s = reinterpret_cast<LuaSession*>(ss);
    if (!s || !out_result) return 0;
    *out_result = s->replacement_result;
    if (out_path) *out_path = s->replacement_result_path.empty() ? nullptr : s->replacement_result_path.c_str();
    int32_t present = s->replacement_result ? 1 : 0;
    s->replacement_result = nullptr;
    return present;
}

size_t femm_lua_num_commands(void) {
    return registry_names().size();
}

const char* femm_lua_command_name(size_t idx) {
    const auto& names = registry_names();
    if (idx >= names.size()) return nullptr;
    return names[idx].c_str();
}

} // extern "C"
