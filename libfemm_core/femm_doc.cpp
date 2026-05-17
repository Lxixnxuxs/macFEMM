// femm_doc.cpp — Document lifecycle + lookup helpers (shared across physics).

#include "femm_doc.hpp"
#include "femm_c.h"

#include <algorithm>
#include <cstring>
#include <string>

namespace femmcore {

const char* file_ext_for(femm_physics_t p) {
    switch (p) {
        case FEMM_PHYSICS_MAGNETICS:      return ".fem";
        case FEMM_PHYSICS_ELECTROSTATICS: return ".fee";
        case FEMM_PHYSICS_HEAT:           return ".feh";
        case FEMM_PHYSICS_CURRENT:        return ".fec";
    }
    return ".fem";
}

const char* solver_name_for(femm_physics_t p) {
    switch (p) {
        case FEMM_PHYSICS_MAGNETICS:      return "fknsolve";
        case FEMM_PHYSICS_ELECTROSTATICS: return "belasolve";
        case FEMM_PHYSICS_HEAT:           return "hsolve";
        case FEMM_PHYSICS_CURRENT:        return "csolve";
    }
    return "fknsolve";
}

const char* result_ext_for(femm_physics_t p) {
    switch (p) {
        case FEMM_PHYSICS_MAGNETICS:      return ".ans";
        case FEMM_PHYSICS_ELECTROSTATICS: return ".res";
        case FEMM_PHYSICS_HEAT:           return ".anh";
        case FEMM_PHYSICS_CURRENT:        return ".anc";
    }
    return ".ans";
}

int Document::lookup_point_idx(const std::string& n) const {
    if (n.empty()) return 0;
    switch (physics) {
        case FEMM_PHYSICS_MAGNETICS:
            for (size_t i = 0; i < mag_pointprops.size(); ++i)
                if (mag_pointprops[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            for (size_t i = 0; i < es_pointprops.size(); ++i)
                if (es_pointprops[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_HEAT:
            for (size_t i = 0; i < heat_pointprops.size(); ++i)
                if (heat_pointprops[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_CURRENT:
            for (size_t i = 0; i < curr_pointprops.size(); ++i)
                if (curr_pointprops[i].name == n) return (int)(i + 1);
            break;
    }
    return 0;
}

int Document::lookup_bdry_idx(const std::string& n) const {
    if (n.empty()) return 0;
    switch (physics) {
        case FEMM_PHYSICS_MAGNETICS:
            for (size_t i = 0; i < mag_boundaries.size(); ++i)
                if (mag_boundaries[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            for (size_t i = 0; i < es_boundaries.size(); ++i)
                if (es_boundaries[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_HEAT:
            for (size_t i = 0; i < heat_boundaries.size(); ++i)
                if (heat_boundaries[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_CURRENT:
            for (size_t i = 0; i < curr_boundaries.size(); ++i)
                if (curr_boundaries[i].name == n) return (int)(i + 1);
            break;
    }
    return 0;
}

int Document::lookup_block_idx(const std::string& n) const {
    if (n.empty()) return 0;
    switch (physics) {
        case FEMM_PHYSICS_MAGNETICS:
            for (size_t i = 0; i < mag_materials.size(); ++i)
                if (mag_materials[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            for (size_t i = 0; i < es_materials.size(); ++i)
                if (es_materials[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_HEAT:
            for (size_t i = 0; i < heat_materials.size(); ++i)
                if (heat_materials[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_CURRENT:
            for (size_t i = 0; i < curr_materials.size(); ++i)
                if (curr_materials[i].name == n) return (int)(i + 1);
            break;
    }
    return 0;
}

int Document::lookup_conductor_idx(const std::string& n) const {
    if (n.empty()) return 0;
    switch (physics) {
        case FEMM_PHYSICS_MAGNETICS:
            for (size_t i = 0; i < mag_circuits.size(); ++i)
                if (mag_circuits[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_ELECTROSTATICS:
            for (size_t i = 0; i < es_conductors.size(); ++i)
                if (es_conductors[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_HEAT:
            for (size_t i = 0; i < heat_conductors.size(); ++i)
                if (heat_conductors[i].name == n) return (int)(i + 1);
            break;
        case FEMM_PHYSICS_CURRENT:
            for (size_t i = 0; i < curr_conductors.size(); ++i)
                if (curr_conductors[i].name == n) return (int)(i + 1);
            break;
    }
    return 0;
}

} // namespace femmcore

/* ======================================================================
 * C ABI — lifecycle + problem-def setters + geometry adders + getters
 * ====================================================================== */

using femmcore::Document;
using femmcore::set_last_error;

extern "C" {

femm_status_t femm_doc_new(femm_physics_t physics, femm_doc_t** out) {
    if (!out) return FEMM_ERR_INVALID_ARG;
    auto* d = new (std::nothrow) Document();
    if (!d) return FEMM_ERR_OUT_OF_MEM;
    d->physics = physics;
    *out = reinterpret_cast<femm_doc_t*>(d);
    return FEMM_OK;
}

void femm_doc_free(femm_doc_t* doc) {
    delete reinterpret_cast<Document*>(doc);
}

femm_physics_t femm_doc_physics(const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->physics;
}

#define DOC() auto* d = reinterpret_cast<Document*>(doc); \
              if (!d) { set_last_error("null doc"); return FEMM_ERR_INVALID_ARG; }

femm_status_t femm_doc_set_length_units(femm_doc_t* doc, femm_length_units_t u) {
    DOC(); d->length_units = u; return FEMM_OK;
}
femm_status_t femm_doc_set_problem_type(femm_doc_t* doc, femm_problem_type_t t) {
    DOC(); d->problem_type = t; return FEMM_OK;
}
femm_status_t femm_doc_set_depth(femm_doc_t* doc, double depth) {
    DOC(); d->depth = depth; return FEMM_OK;
}
femm_status_t femm_doc_set_precision(femm_doc_t* doc, double p) {
    DOC(); d->precision = p; return FEMM_OK;
}
femm_status_t femm_doc_set_min_angle(femm_doc_t* doc, double a) {
    DOC(); d->min_angle = a; return FEMM_OK;
}
femm_status_t femm_doc_set_smart_mesh(femm_doc_t* doc, int32_t on) {
    DOC(); d->smart_mesh = on ? 1 : 0; return FEMM_OK;
}
femm_status_t femm_doc_set_frequency(femm_doc_t* doc, double hz) {
    DOC(); d->frequency = hz; return FEMM_OK;
}
femm_status_t femm_doc_set_ac_solver(femm_doc_t* doc, int32_t m) {
    DOC(); d->ac_solver = m; return FEMM_OK;
}
femm_status_t femm_doc_set_comment(femm_doc_t* doc, const char* utf8) {
    DOC(); d->comment = utf8 ? utf8 : ""; return FEMM_OK;
}

/* --- Geometry adders ---------------------------------------------------- */
femm_status_t femm_add_node(femm_doc_t* doc, double x, double y, int32_t* idx_out) {
    DOC(); d->nodes.push_back(femmcore::Node{x, y, 0, 0, 0});
    if (idx_out) *idx_out = (int32_t)(d->nodes.size() - 1);
    return FEMM_OK;
}
femm_status_t femm_add_segment(femm_doc_t* doc, int32_t n0, int32_t n1, int32_t* idx_out) {
    DOC();
    if (n0 < 0 || (size_t)n0 >= d->nodes.size() || n1 < 0 || (size_t)n1 >= d->nodes.size()) {
        set_last_error("segment endpoint out of range");
        return FEMM_ERR_INVALID_ARG;
    }
    femmcore::Segment s; s.n0 = n0; s.n1 = n1;
    d->segments.push_back(s);
    if (idx_out) *idx_out = (int32_t)(d->segments.size() - 1);
    return FEMM_OK;
}
femm_status_t femm_add_arc(femm_doc_t* doc, int32_t n0, int32_t n1,
                           double arc_deg, double max_side_deg, int32_t* idx_out) {
    DOC();
    if (n0 < 0 || (size_t)n0 >= d->nodes.size() || n1 < 0 || (size_t)n1 >= d->nodes.size()) {
        set_last_error("arc endpoint out of range");
        return FEMM_ERR_INVALID_ARG;
    }
    femmcore::Arc a; a.n0 = n0; a.n1 = n1; a.arc_deg = arc_deg; a.max_side_deg = max_side_deg;
    d->arcs.push_back(a);
    if (idx_out) *idx_out = (int32_t)(d->arcs.size() - 1);
    return FEMM_OK;
}
femm_status_t femm_add_block_label(femm_doc_t* doc, double x, double y, int32_t* idx_out) {
    DOC();
    femmcore::BlockLabel l; l.x = x; l.y = y;
    d->labels.push_back(l);
    if (idx_out) *idx_out = (int32_t)(d->labels.size() - 1);
    return FEMM_OK;
}

femm_status_t femm_set_node_boundary(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;
    d->nodes[idx].bdry_idx = d->lookup_point_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_node_group(femm_doc_t* doc, int32_t idx, int32_t group) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;
    d->nodes[idx].group = group;
    return FEMM_OK;
}
femm_status_t femm_set_node_conductor(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;
    d->nodes[idx].in_conductor = d->lookup_conductor_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_segment_boundary(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments[idx].bdry_idx = d->lookup_bdry_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_segment_max_side(femm_doc_t* doc, int32_t idx, double ms) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments[idx].max_side = ms;
    return FEMM_OK;
}
femm_status_t femm_set_segment_hidden(femm_doc_t* doc, int32_t idx, int32_t hidden) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments[idx].hidden = hidden ? 1 : 0;
    return FEMM_OK;
}
femm_status_t femm_set_segment_group(femm_doc_t* doc, int32_t idx, int32_t group) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments[idx].group = group;
    return FEMM_OK;
}
femm_status_t femm_set_segment_conductor(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments[idx].in_conductor = d->lookup_conductor_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_arc_boundary(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs[idx].bdry_idx = d->lookup_bdry_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_arc_max_side(femm_doc_t* doc, int32_t idx, double ms) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs[idx].max_side_deg = ms;
    return FEMM_OK;
}
femm_status_t femm_set_arc_hidden(femm_doc_t* doc, int32_t idx, int32_t hidden) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs[idx].hidden = hidden ? 1 : 0;
    return FEMM_OK;
}
femm_status_t femm_set_arc_group(femm_doc_t* doc, int32_t idx, int32_t group) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs[idx].group = group;
    return FEMM_OK;
}
femm_status_t femm_set_arc_conductor(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs[idx].in_conductor = d->lookup_conductor_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_block_label_material(femm_doc_t* doc, int32_t idx, const char* name) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].block_idx = d->lookup_block_idx(name ? name : "");
    return FEMM_OK;
}
femm_status_t femm_set_block_label_max_area(femm_doc_t* doc, int32_t idx, double a) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].max_area = a;
    return FEMM_OK;
}
femm_status_t femm_set_block_label_circuit(femm_doc_t* doc, int32_t idx,
                                           const char* name, int32_t turns) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].circuit_idx = d->lookup_conductor_idx(name ? name : "");
    d->labels[idx].turns = turns;
    return FEMM_OK;
}
femm_status_t femm_set_block_label_magdir(femm_doc_t* doc, int32_t idx, double deg) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].mag_dir = deg;
    return FEMM_OK;
}
femm_status_t femm_set_block_label_group(femm_doc_t* doc, int32_t idx, int32_t group) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].group = group;
    return FEMM_OK;
}
femm_status_t femm_set_block_label_external(femm_doc_t* doc, int32_t idx, int32_t is_external) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].is_external = is_external ? 1 : 0;
    return FEMM_OK;
}
femm_status_t femm_set_block_label_default(femm_doc_t* doc, int32_t idx, int32_t is_default) {
    DOC();
    if (idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    if (is_default) {
        for (auto& label : d->labels) label.is_default = 0;
        d->labels[idx].is_default = 1;
    } else {
        d->labels[idx].is_default = 0;
    }
    return FEMM_OK;
}

/* --- Getters ---------------------------------------------------------- */
size_t femm_num_nodes   (const femm_doc_t* d) { return reinterpret_cast<const Document*>(d)->nodes.size(); }
size_t femm_num_segments(const femm_doc_t* d) { return reinterpret_cast<const Document*>(d)->segments.size(); }
size_t femm_num_arcs    (const femm_doc_t* d) { return reinterpret_cast<const Document*>(d)->arcs.size(); }
size_t femm_num_labels  (const femm_doc_t* d) { return reinterpret_cast<const Document*>(d)->labels.size(); }

femm_status_t femm_get_node(const femm_doc_t* doc, int32_t idx, femm_node_view_t* out) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || !out || idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;
    const auto& n = d->nodes[idx];
    out->x = n.x; out->y = n.y; out->in_group = n.group;
    out->bdry_idx = n.bdry_idx; out->conductor_idx = n.in_conductor;
    return FEMM_OK;
}
femm_status_t femm_get_segment(const femm_doc_t* doc, int32_t idx, femm_seg_view_t* out) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || !out || idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    const auto& s = d->segments[idx];
    out->n0 = s.n0; out->n1 = s.n1; out->max_side = s.max_side;
    out->bdry_idx = s.bdry_idx; out->hidden = s.hidden;
    out->in_group = s.group; out->conductor_idx = s.in_conductor;
    return FEMM_OK;
}
femm_status_t femm_get_arc(const femm_doc_t* doc, int32_t idx, femm_arc_view_t* out) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || !out || idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    const auto& a = d->arcs[idx];
    out->n0 = a.n0; out->n1 = a.n1; out->arc_deg = a.arc_deg;
    out->max_side_deg = a.max_side_deg; out->bdry_idx = a.bdry_idx;
    out->hidden = a.hidden; out->in_group = a.group;
    out->conductor_idx = a.in_conductor;
    return FEMM_OK;
}
femm_status_t femm_get_label(const femm_doc_t* doc, int32_t idx, femm_lbl_view_t* out) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || !out || idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    const auto& l = d->labels[idx];
    out->x = l.x; out->y = l.y; out->block_idx = l.block_idx;
    out->max_area = l.max_area; out->circuit_idx = l.circuit_idx;
    out->mag_dir = l.mag_dir; out->turns = l.turns;
    out->is_external = l.is_external; out->is_default = l.is_default;
    out->in_group = l.group;
    return FEMM_OK;
}

/* --- Problem-def getters ------------------------------------------------ */
double   femm_doc_get_precision (const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->precision;
}
double   femm_doc_get_min_angle (const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->min_angle;
}
int32_t  femm_doc_get_smart_mesh(const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->smart_mesh;
}
double   femm_doc_get_depth     (const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->depth;
}
double   femm_doc_get_frequency (const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->frequency;
}
int32_t  femm_doc_get_ac_solver (const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->ac_solver;
}
femm_length_units_t femm_doc_get_length_units(const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->length_units;
}
femm_problem_type_t femm_doc_get_problem_type(const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->problem_type;
}
const char* femm_doc_get_comment(const femm_doc_t* doc) {
    return reinterpret_cast<const Document*>(doc)->comment.c_str();
}

/* --- Geometry mutators -------------------------------------------------- */
namespace {
// Rewrite node-index fields in segments/arcs after node `removed` is deleted.
// Returns false if the topology dependency requires caller to also drop the
// referencing primitive (endpoint was the deleted node).
inline void shift_node_ref(int& slot, int removed) {
    if (slot > removed) slot--;
    // slot == removed is caller's problem (primitive must be erased).
}
} // namespace

femm_status_t femm_delete_node(femm_doc_t* doc, int32_t idx) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;

    // Drop segments/arcs that had this node as an endpoint; shift the rest.
    d->segments.erase(std::remove_if(d->segments.begin(), d->segments.end(),
        [idx](const femmcore::Segment& s){ return s.n0 == idx || s.n1 == idx; }),
        d->segments.end());
    for (auto& s : d->segments) { shift_node_ref(s.n0, idx); shift_node_ref(s.n1, idx); }

    d->arcs.erase(std::remove_if(d->arcs.begin(), d->arcs.end(),
        [idx](const femmcore::Arc& a){ return a.n0 == idx || a.n1 == idx; }),
        d->arcs.end());
    for (auto& a : d->arcs) { shift_node_ref(a.n0, idx); shift_node_ref(a.n1, idx); }

    d->nodes.erase(d->nodes.begin() + idx);
    return FEMM_OK;
}
femm_status_t femm_delete_segment(femm_doc_t* doc, int32_t idx) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->segments.size()) return FEMM_ERR_INVALID_ARG;
    d->segments.erase(d->segments.begin() + idx);
    return FEMM_OK;
}
femm_status_t femm_delete_arc(femm_doc_t* doc, int32_t idx) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->arcs.size()) return FEMM_ERR_INVALID_ARG;
    d->arcs.erase(d->arcs.begin() + idx);
    return FEMM_OK;
}
femm_status_t femm_delete_label(femm_doc_t* doc, int32_t idx) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels.erase(d->labels.begin() + idx);
    return FEMM_OK;
}
femm_status_t femm_move_node(femm_doc_t* doc, int32_t idx, double x, double y) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->nodes.size()) return FEMM_ERR_INVALID_ARG;
    d->nodes[idx].x = x; d->nodes[idx].y = y;
    return FEMM_OK;
}
femm_status_t femm_move_label(femm_doc_t* doc, int32_t idx, double x, double y) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || idx < 0 || (size_t)idx >= d->labels.size()) return FEMM_ERR_INVALID_ARG;
    d->labels[idx].x = x; d->labels[idx].y = y;
    return FEMM_OK;
}

} // extern "C"
