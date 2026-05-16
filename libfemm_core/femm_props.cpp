// femm_props.cpp — C ABI for property-list mutation (materials/boundaries/
// point-props/circuits) across all four physics. Plain delegation from the
// C-shaped structs into the namespaced Document property vectors.

#include "femm_doc.hpp"
#include "femm_c.h"

#include <string>
#include <vector>

using femmcore::Document;
using femmcore::Complex;
using femmcore::set_last_error;

namespace {
Complex to_cpp(femm_complex_t c) { return {c.re, c.im}; }
femm_complex_t to_c(Complex c) { return femm_complex_t{c.real(), c.imag()}; }

// Apply a 1-based-index delete map to a geometry reference slot. After a
// property at (0-based) `removed` is deleted: slots where ref == removed+1
// become 0; slots where ref > removed+1 are decremented.
inline void shift_geom_ref(int& slot, int removed_zero) {
    const int removed_one = removed_zero + 1;
    if (slot == removed_one) slot = 0;
    else if (slot > removed_one) slot--;
}
} // namespace

extern "C" {

/* --- Magnetics --------------------------------------------------------- */
femm_status_t femm_mag_add_material(femm_doc_t* doc, const femm_mag_material_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name) return FEMM_ERR_INVALID_ARG;
    if (d->physics != FEMM_PHYSICS_MAGNETICS) {
        set_last_error("mag_add_material called on non-magnetics doc");
        return FEMM_ERR_INVALID_ARG;
    }
    femmcore::mag::Material m;
    m.name = in->name;
    m.mu_x = in->mu_x; m.mu_y = in->mu_y;
    m.H_c = in->H_c; m.theta_m = in->theta_m;
    m.J_src = to_cpp(in->J_src);
    m.c_duct = in->c_duct; m.lam_d = in->lam_d;
    m.theta_hn = in->theta_hn; m.theta_hx = in->theta_hx; m.theta_hy = in->theta_hy;
    m.lam_type = in->lam_type; m.lam_fill = in->lam_fill;
    m.n_strands = in->n_strands; m.wire_d = in->wire_d;
    d->mag_materials.push_back(std::move(m));
    return FEMM_OK;
}
femm_status_t femm_mag_add_bh_point(femm_doc_t* doc, const char* name, double B, double H) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !name || d->physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_INVALID_ARG;
    for (auto& m : d->mag_materials) {
        if (m.name == name) { m.bh.emplace_back(B, H); return FEMM_OK; }
    }
    set_last_error(std::string("unknown material: ") + name);
    return FEMM_ERR_NOT_FOUND;
}
femm_status_t femm_mag_add_boundary(femm_doc_t* doc, const femm_mag_boundary_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_INVALID_ARG;
    femmcore::mag::Boundary b;
    b.name = in->name; b.fmt = in->bdry_format;
    b.A0 = in->A0; b.A1 = in->A1; b.A2 = in->A2; b.phi = in->phi;
    b.c0 = to_cpp(in->c0); b.c1 = to_cpp(in->c1);
    b.mu = in->mu; b.sig = in->sig;
    b.inner_angle = in->inner_angle; b.outer_angle = in->outer_angle;
    d->mag_boundaries.push_back(std::move(b));
    return FEMM_OK;
}
femm_status_t femm_mag_add_pointprop(femm_doc_t* doc, const femm_mag_pointprop_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_INVALID_ARG;
    femmcore::mag::PointProp p;
    p.name = in->name; p.Jp = to_cpp(in->Jp); p.Ap = to_cpp(in->Ap);
    d->mag_pointprops.push_back(std::move(p));
    return FEMM_OK;
}
femm_status_t femm_mag_add_circuit(femm_doc_t* doc, const femm_mag_circuit_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_INVALID_ARG;
    femmcore::mag::Circuit c;
    c.name = in->name; c.amps = to_cpp(in->amps); c.circ_type = in->circ_type;
    d->mag_circuits.push_back(std::move(c));
    return FEMM_OK;
}

/* --- Electrostatics ---------------------------------------------------- */
femm_status_t femm_es_add_material(femm_doc_t* doc, const femm_es_material_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_ELECTROSTATICS) return FEMM_ERR_INVALID_ARG;
    d->es_materials.push_back({in->name, in->ex, in->ey, in->qv});
    return FEMM_OK;
}
femm_status_t femm_es_add_boundary(femm_doc_t* doc, const femm_es_boundary_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_ELECTROSTATICS) return FEMM_ERR_INVALID_ARG;
    d->es_boundaries.push_back({in->name, in->bdry_format, in->V, in->qs, in->c0, in->c1});
    return FEMM_OK;
}
femm_status_t femm_es_add_pointprop(femm_doc_t* doc, const femm_es_pointprop_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_ELECTROSTATICS) return FEMM_ERR_INVALID_ARG;
    d->es_pointprops.push_back({in->name, in->V, in->qp});
    return FEMM_OK;
}
femm_status_t femm_es_add_conductor(femm_doc_t* doc, const femm_es_conductor_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_ELECTROSTATICS) return FEMM_ERR_INVALID_ARG;
    d->es_conductors.push_back({in->name, in->V, in->q, in->circ_type});
    return FEMM_OK;
}

/* --- Heat -------------------------------------------------------------- */
femm_status_t femm_heat_add_material(femm_doc_t* doc, const femm_heat_material_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_HEAT) return FEMM_ERR_INVALID_ARG;
    d->heat_materials.push_back({in->name, in->Kx, in->Ky, in->Kt, in->qv});
    return FEMM_OK;
}
femm_status_t femm_heat_add_boundary(femm_doc_t* doc, const femm_heat_boundary_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_HEAT) return FEMM_ERR_INVALID_ARG;
    d->heat_boundaries.push_back({in->name, in->bdry_format, in->Tset, in->qs,
                                  in->beta, in->h, in->Tinf, in->TinfRad});
    return FEMM_OK;
}
femm_status_t femm_heat_add_pointprop(femm_doc_t* doc, const femm_heat_pointprop_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_HEAT) return FEMM_ERR_INVALID_ARG;
    d->heat_pointprops.push_back({in->name, in->T, in->qp});
    return FEMM_OK;
}
femm_status_t femm_heat_add_conductor(femm_doc_t* doc, const femm_heat_conductor_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_HEAT) return FEMM_ERR_INVALID_ARG;
    d->heat_conductors.push_back({in->name, in->T, in->q, in->circ_type});
    return FEMM_OK;
}

/* --- Current flow ------------------------------------------------------ */
femm_status_t femm_curr_add_material(femm_doc_t* doc, const femm_curr_material_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_CURRENT) return FEMM_ERR_INVALID_ARG;
    d->curr_materials.push_back({in->name, in->ox, in->oy, in->ex, in->ey, in->ltx, in->lty});
    return FEMM_OK;
}
femm_status_t femm_curr_add_boundary(femm_doc_t* doc, const femm_curr_boundary_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_CURRENT) return FEMM_ERR_INVALID_ARG;
    femmcore::curr::Boundary b;
    b.name = in->name; b.fmt = in->bdry_format;
    b.Vs = to_cpp(in->Vs); b.qs = to_cpp(in->qs);
    b.c0 = to_cpp(in->c0); b.c1 = to_cpp(in->c1);
    d->curr_boundaries.push_back(std::move(b));
    return FEMM_OK;
}
femm_status_t femm_curr_add_pointprop(femm_doc_t* doc, const femm_curr_pointprop_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_CURRENT) return FEMM_ERR_INVALID_ARG;
    femmcore::curr::PointProp p;
    p.name = in->name; p.Vp = to_cpp(in->Vp); p.qp = to_cpp(in->qp);
    d->curr_pointprops.push_back(std::move(p));
    return FEMM_OK;
}
femm_status_t femm_curr_add_conductor(femm_doc_t* doc, const femm_curr_conductor_t* in) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || !in || !in->name || d->physics != FEMM_PHYSICS_CURRENT) return FEMM_ERR_INVALID_ARG;
    femmcore::curr::Conductor c;
    c.name = in->name; c.Vc = to_cpp(in->Vc); c.qc = to_cpp(in->qc); c.circ_type = in->circ_type;
    d->curr_conductors.push_back(std::move(c));
    return FEMM_OK;
}

/* ======================================================================
 * Counts
 * ====================================================================== */
#define C_DOC() auto* d = reinterpret_cast<const Document*>(doc); if (!d) return 0;

size_t femm_mag_num_materials (const femm_doc_t* doc) { C_DOC(); return d->mag_materials.size(); }
size_t femm_mag_num_boundaries(const femm_doc_t* doc) { C_DOC(); return d->mag_boundaries.size(); }
size_t femm_mag_num_pointprops(const femm_doc_t* doc) { C_DOC(); return d->mag_pointprops.size(); }
size_t femm_mag_num_circuits  (const femm_doc_t* doc) { C_DOC(); return d->mag_circuits.size(); }
size_t femm_es_num_materials  (const femm_doc_t* doc) { C_DOC(); return d->es_materials.size(); }
size_t femm_es_num_boundaries (const femm_doc_t* doc) { C_DOC(); return d->es_boundaries.size(); }
size_t femm_es_num_pointprops (const femm_doc_t* doc) { C_DOC(); return d->es_pointprops.size(); }
size_t femm_es_num_conductors (const femm_doc_t* doc) { C_DOC(); return d->es_conductors.size(); }
size_t femm_heat_num_materials (const femm_doc_t* doc) { C_DOC(); return d->heat_materials.size(); }
size_t femm_heat_num_boundaries(const femm_doc_t* doc) { C_DOC(); return d->heat_boundaries.size(); }
size_t femm_heat_num_pointprops(const femm_doc_t* doc) { C_DOC(); return d->heat_pointprops.size(); }
size_t femm_heat_num_conductors(const femm_doc_t* doc) { C_DOC(); return d->heat_conductors.size(); }
size_t femm_curr_num_materials (const femm_doc_t* doc) { C_DOC(); return d->curr_materials.size(); }
size_t femm_curr_num_boundaries(const femm_doc_t* doc) { C_DOC(); return d->curr_boundaries.size(); }
size_t femm_curr_num_pointprops(const femm_doc_t* doc) { C_DOC(); return d->curr_pointprops.size(); }
size_t femm_curr_num_conductors(const femm_doc_t* doc) { C_DOC(); return d->curr_conductors.size(); }

#undef C_DOC

/* ======================================================================
 * Getters — fill the add_*-shaped struct. `name` points into storage.
 * ====================================================================== */
#define GETTER_GUARD(Doc, Vec, Physics)                                       \
    auto* d = reinterpret_cast<const Document*>(doc);                         \
    if (!d || !out) return FEMM_ERR_INVALID_ARG;                              \
    if (d->physics != Physics) return FEMM_ERR_INVALID_ARG;                   \
    if (idx < 0 || (size_t)idx >= d->Vec.size()) return FEMM_ERR_INVALID_ARG;

femm_status_t femm_mag_get_material(const femm_doc_t* doc, int32_t idx, femm_mag_material_t* out) {
    GETTER_GUARD(Document, mag_materials, FEMM_PHYSICS_MAGNETICS);
    const auto& m = d->mag_materials[idx];
    out->name = m.name.c_str();
    out->mu_x = m.mu_x; out->mu_y = m.mu_y;
    out->H_c = m.H_c; out->theta_m = m.theta_m;
    out->J_src = to_c(m.J_src);
    out->c_duct = m.c_duct; out->lam_d = m.lam_d;
    out->theta_hn = m.theta_hn; out->theta_hx = m.theta_hx; out->theta_hy = m.theta_hy;
    out->lam_type = m.lam_type; out->lam_fill = m.lam_fill;
    out->n_strands = m.n_strands; out->wire_d = m.wire_d;
    return FEMM_OK;
}
femm_status_t femm_mag_get_boundary(const femm_doc_t* doc, int32_t idx, femm_mag_boundary_t* out) {
    GETTER_GUARD(Document, mag_boundaries, FEMM_PHYSICS_MAGNETICS);
    const auto& b = d->mag_boundaries[idx];
    out->name = b.name.c_str();
    out->bdry_format = b.fmt;
    out->A0 = b.A0; out->A1 = b.A1; out->A2 = b.A2; out->phi = b.phi;
    out->c0 = to_c(b.c0); out->c1 = to_c(b.c1);
    out->mu = b.mu; out->sig = b.sig;
    out->inner_angle = b.inner_angle; out->outer_angle = b.outer_angle;
    return FEMM_OK;
}
femm_status_t femm_mag_get_pointprop(const femm_doc_t* doc, int32_t idx, femm_mag_pointprop_t* out) {
    GETTER_GUARD(Document, mag_pointprops, FEMM_PHYSICS_MAGNETICS);
    const auto& p = d->mag_pointprops[idx];
    out->name = p.name.c_str();
    out->Jp = to_c(p.Jp); out->Ap = to_c(p.Ap);
    return FEMM_OK;
}
femm_status_t femm_mag_get_circuit(const femm_doc_t* doc, int32_t idx, femm_mag_circuit_t* out) {
    GETTER_GUARD(Document, mag_circuits, FEMM_PHYSICS_MAGNETICS);
    const auto& c = d->mag_circuits[idx];
    out->name = c.name.c_str();
    out->amps = to_c(c.amps); out->circ_type = c.circ_type;
    return FEMM_OK;
}

femm_status_t femm_es_get_material(const femm_doc_t* doc, int32_t idx, femm_es_material_t* out) {
    GETTER_GUARD(Document, es_materials, FEMM_PHYSICS_ELECTROSTATICS);
    const auto& m = d->es_materials[idx];
    out->name = m.name.c_str(); out->ex = m.ex; out->ey = m.ey; out->qv = m.qv;
    return FEMM_OK;
}
femm_status_t femm_es_get_boundary(const femm_doc_t* doc, int32_t idx, femm_es_boundary_t* out) {
    GETTER_GUARD(Document, es_boundaries, FEMM_PHYSICS_ELECTROSTATICS);
    const auto& b = d->es_boundaries[idx];
    out->name = b.name.c_str(); out->bdry_format = b.fmt;
    out->V = b.V; out->qs = b.qs; out->c0 = b.c0; out->c1 = b.c1;
    return FEMM_OK;
}
femm_status_t femm_es_get_pointprop(const femm_doc_t* doc, int32_t idx, femm_es_pointprop_t* out) {
    GETTER_GUARD(Document, es_pointprops, FEMM_PHYSICS_ELECTROSTATICS);
    const auto& p = d->es_pointprops[idx];
    out->name = p.name.c_str(); out->V = p.V; out->qp = p.qp;
    return FEMM_OK;
}
femm_status_t femm_es_get_conductor(const femm_doc_t* doc, int32_t idx, femm_es_conductor_t* out) {
    GETTER_GUARD(Document, es_conductors, FEMM_PHYSICS_ELECTROSTATICS);
    const auto& c = d->es_conductors[idx];
    out->name = c.name.c_str(); out->V = c.V; out->q = c.q; out->circ_type = c.circ_type;
    return FEMM_OK;
}

femm_status_t femm_heat_get_material(const femm_doc_t* doc, int32_t idx, femm_heat_material_t* out) {
    GETTER_GUARD(Document, heat_materials, FEMM_PHYSICS_HEAT);
    const auto& m = d->heat_materials[idx];
    out->name = m.name.c_str(); out->Kx = m.Kx; out->Ky = m.Ky; out->Kt = m.Kt; out->qv = m.qv;
    return FEMM_OK;
}
femm_status_t femm_heat_get_boundary(const femm_doc_t* doc, int32_t idx, femm_heat_boundary_t* out) {
    GETTER_GUARD(Document, heat_boundaries, FEMM_PHYSICS_HEAT);
    const auto& b = d->heat_boundaries[idx];
    out->name = b.name.c_str(); out->bdry_format = b.fmt;
    out->Tset = b.Tset; out->qs = b.qs; out->beta = b.beta;
    out->h = b.h; out->Tinf = b.Tinf; out->TinfRad = b.TinfRad;
    return FEMM_OK;
}
femm_status_t femm_heat_get_pointprop(const femm_doc_t* doc, int32_t idx, femm_heat_pointprop_t* out) {
    GETTER_GUARD(Document, heat_pointprops, FEMM_PHYSICS_HEAT);
    const auto& p = d->heat_pointprops[idx];
    out->name = p.name.c_str(); out->T = p.T; out->qp = p.qp;
    return FEMM_OK;
}
femm_status_t femm_heat_get_conductor(const femm_doc_t* doc, int32_t idx, femm_heat_conductor_t* out) {
    GETTER_GUARD(Document, heat_conductors, FEMM_PHYSICS_HEAT);
    const auto& c = d->heat_conductors[idx];
    out->name = c.name.c_str(); out->T = c.T; out->q = c.q; out->circ_type = c.circ_type;
    return FEMM_OK;
}

femm_status_t femm_curr_get_material(const femm_doc_t* doc, int32_t idx, femm_curr_material_t* out) {
    GETTER_GUARD(Document, curr_materials, FEMM_PHYSICS_CURRENT);
    const auto& m = d->curr_materials[idx];
    out->name = m.name.c_str();
    out->ox = m.ox; out->oy = m.oy; out->ex = m.ex; out->ey = m.ey;
    out->ltx = m.ltx; out->lty = m.lty;
    return FEMM_OK;
}
femm_status_t femm_curr_get_boundary(const femm_doc_t* doc, int32_t idx, femm_curr_boundary_t* out) {
    GETTER_GUARD(Document, curr_boundaries, FEMM_PHYSICS_CURRENT);
    const auto& b = d->curr_boundaries[idx];
    out->name = b.name.c_str(); out->bdry_format = b.fmt;
    out->Vs = to_c(b.Vs); out->qs = to_c(b.qs);
    out->c0 = to_c(b.c0); out->c1 = to_c(b.c1);
    return FEMM_OK;
}
femm_status_t femm_curr_get_pointprop(const femm_doc_t* doc, int32_t idx, femm_curr_pointprop_t* out) {
    GETTER_GUARD(Document, curr_pointprops, FEMM_PHYSICS_CURRENT);
    const auto& p = d->curr_pointprops[idx];
    out->name = p.name.c_str();
    out->Vp = to_c(p.Vp); out->qp = to_c(p.qp);
    return FEMM_OK;
}
femm_status_t femm_curr_get_conductor(const femm_doc_t* doc, int32_t idx, femm_curr_conductor_t* out) {
    GETTER_GUARD(Document, curr_conductors, FEMM_PHYSICS_CURRENT);
    const auto& c = d->curr_conductors[idx];
    out->name = c.name.c_str();
    out->Vc = to_c(c.Vc); out->qc = to_c(c.qc); out->circ_type = c.circ_type;
    return FEMM_OK;
}

#undef GETTER_GUARD

/* ======================================================================
 * Updaters — overwrite at idx. If `name` changes, rewrite geometry refs
 * (by 1-based index) so existing nodes/segments/labels keep pointing at
 * the same conceptual entry.
 * ====================================================================== */
#define UPDATE_GUARD(Vec, Physics)                                             \
    auto* d = reinterpret_cast<Document*>(doc);                                \
    if (!d || !in || !in->name) return FEMM_ERR_INVALID_ARG;                   \
    if (d->physics != Physics) return FEMM_ERR_INVALID_ARG;                    \
    if (idx < 0 || (size_t)idx >= d->Vec.size()) return FEMM_ERR_INVALID_ARG;

femm_status_t femm_mag_update_material(femm_doc_t* doc, int32_t idx, const femm_mag_material_t* in) {
    UPDATE_GUARD(mag_materials, FEMM_PHYSICS_MAGNETICS);
    auto& m = d->mag_materials[idx];
    m.name = in->name;
    m.mu_x = in->mu_x; m.mu_y = in->mu_y;
    m.H_c = in->H_c; m.theta_m = in->theta_m;
    m.J_src = to_cpp(in->J_src);
    m.c_duct = in->c_duct; m.lam_d = in->lam_d;
    m.theta_hn = in->theta_hn; m.theta_hx = in->theta_hx; m.theta_hy = in->theta_hy;
    m.lam_type = in->lam_type; m.lam_fill = in->lam_fill;
    m.n_strands = in->n_strands; m.wire_d = in->wire_d;
    return FEMM_OK;
}
femm_status_t femm_mag_update_boundary(femm_doc_t* doc, int32_t idx, const femm_mag_boundary_t* in) {
    UPDATE_GUARD(mag_boundaries, FEMM_PHYSICS_MAGNETICS);
    auto& b = d->mag_boundaries[idx];
    b.name = in->name; b.fmt = in->bdry_format;
    b.A0 = in->A0; b.A1 = in->A1; b.A2 = in->A2; b.phi = in->phi;
    b.c0 = to_cpp(in->c0); b.c1 = to_cpp(in->c1);
    b.mu = in->mu; b.sig = in->sig;
    b.inner_angle = in->inner_angle; b.outer_angle = in->outer_angle;
    return FEMM_OK;
}
femm_status_t femm_mag_update_pointprop(femm_doc_t* doc, int32_t idx, const femm_mag_pointprop_t* in) {
    UPDATE_GUARD(mag_pointprops, FEMM_PHYSICS_MAGNETICS);
    auto& p = d->mag_pointprops[idx];
    p.name = in->name; p.Jp = to_cpp(in->Jp); p.Ap = to_cpp(in->Ap);
    return FEMM_OK;
}
femm_status_t femm_mag_update_circuit(femm_doc_t* doc, int32_t idx, const femm_mag_circuit_t* in) {
    UPDATE_GUARD(mag_circuits, FEMM_PHYSICS_MAGNETICS);
    auto& c = d->mag_circuits[idx];
    c.name = in->name; c.amps = to_cpp(in->amps); c.circ_type = in->circ_type;
    return FEMM_OK;
}

femm_status_t femm_es_update_material(femm_doc_t* doc, int32_t idx, const femm_es_material_t* in) {
    UPDATE_GUARD(es_materials, FEMM_PHYSICS_ELECTROSTATICS);
    auto& m = d->es_materials[idx];
    m.name = in->name; m.ex = in->ex; m.ey = in->ey; m.qv = in->qv;
    return FEMM_OK;
}
femm_status_t femm_es_update_boundary(femm_doc_t* doc, int32_t idx, const femm_es_boundary_t* in) {
    UPDATE_GUARD(es_boundaries, FEMM_PHYSICS_ELECTROSTATICS);
    auto& b = d->es_boundaries[idx];
    b.name = in->name; b.fmt = in->bdry_format;
    b.V = in->V; b.qs = in->qs; b.c0 = in->c0; b.c1 = in->c1;
    return FEMM_OK;
}
femm_status_t femm_es_update_pointprop(femm_doc_t* doc, int32_t idx, const femm_es_pointprop_t* in) {
    UPDATE_GUARD(es_pointprops, FEMM_PHYSICS_ELECTROSTATICS);
    auto& p = d->es_pointprops[idx];
    p.name = in->name; p.V = in->V; p.qp = in->qp;
    return FEMM_OK;
}
femm_status_t femm_es_update_conductor(femm_doc_t* doc, int32_t idx, const femm_es_conductor_t* in) {
    UPDATE_GUARD(es_conductors, FEMM_PHYSICS_ELECTROSTATICS);
    auto& c = d->es_conductors[idx];
    c.name = in->name; c.V = in->V; c.q = in->q; c.circ_type = in->circ_type;
    return FEMM_OK;
}

femm_status_t femm_heat_update_material(femm_doc_t* doc, int32_t idx, const femm_heat_material_t* in) {
    UPDATE_GUARD(heat_materials, FEMM_PHYSICS_HEAT);
    auto& m = d->heat_materials[idx];
    m.name = in->name; m.Kx = in->Kx; m.Ky = in->Ky; m.Kt = in->Kt; m.qv = in->qv;
    return FEMM_OK;
}
femm_status_t femm_heat_update_boundary(femm_doc_t* doc, int32_t idx, const femm_heat_boundary_t* in) {
    UPDATE_GUARD(heat_boundaries, FEMM_PHYSICS_HEAT);
    auto& b = d->heat_boundaries[idx];
    b.name = in->name; b.fmt = in->bdry_format;
    b.Tset = in->Tset; b.qs = in->qs; b.beta = in->beta;
    b.h = in->h; b.Tinf = in->Tinf; b.TinfRad = in->TinfRad;
    return FEMM_OK;
}
femm_status_t femm_heat_update_pointprop(femm_doc_t* doc, int32_t idx, const femm_heat_pointprop_t* in) {
    UPDATE_GUARD(heat_pointprops, FEMM_PHYSICS_HEAT);
    auto& p = d->heat_pointprops[idx];
    p.name = in->name; p.T = in->T; p.qp = in->qp;
    return FEMM_OK;
}
femm_status_t femm_heat_update_conductor(femm_doc_t* doc, int32_t idx, const femm_heat_conductor_t* in) {
    UPDATE_GUARD(heat_conductors, FEMM_PHYSICS_HEAT);
    auto& c = d->heat_conductors[idx];
    c.name = in->name; c.T = in->T; c.q = in->q; c.circ_type = in->circ_type;
    return FEMM_OK;
}

femm_status_t femm_curr_update_material(femm_doc_t* doc, int32_t idx, const femm_curr_material_t* in) {
    UPDATE_GUARD(curr_materials, FEMM_PHYSICS_CURRENT);
    auto& m = d->curr_materials[idx];
    m.name = in->name;
    m.ox = in->ox; m.oy = in->oy; m.ex = in->ex; m.ey = in->ey;
    m.ltx = in->ltx; m.lty = in->lty;
    return FEMM_OK;
}
femm_status_t femm_curr_update_boundary(femm_doc_t* doc, int32_t idx, const femm_curr_boundary_t* in) {
    UPDATE_GUARD(curr_boundaries, FEMM_PHYSICS_CURRENT);
    auto& b = d->curr_boundaries[idx];
    b.name = in->name; b.fmt = in->bdry_format;
    b.Vs = to_cpp(in->Vs); b.qs = to_cpp(in->qs);
    b.c0 = to_cpp(in->c0); b.c1 = to_cpp(in->c1);
    return FEMM_OK;
}
femm_status_t femm_curr_update_pointprop(femm_doc_t* doc, int32_t idx, const femm_curr_pointprop_t* in) {
    UPDATE_GUARD(curr_pointprops, FEMM_PHYSICS_CURRENT);
    auto& p = d->curr_pointprops[idx];
    p.name = in->name; p.Vp = to_cpp(in->Vp); p.qp = to_cpp(in->qp);
    return FEMM_OK;
}
femm_status_t femm_curr_update_conductor(femm_doc_t* doc, int32_t idx, const femm_curr_conductor_t* in) {
    UPDATE_GUARD(curr_conductors, FEMM_PHYSICS_CURRENT);
    auto& c = d->curr_conductors[idx];
    c.name = in->name;
    c.Vc = to_cpp(in->Vc); c.qc = to_cpp(in->qc); c.circ_type = in->circ_type;
    return FEMM_OK;
}

#undef UPDATE_GUARD

/* ======================================================================
 * Deleters — remove at idx, then walk geometry rewriting affected refs.
 * ====================================================================== */
namespace {

enum class RefKind { Point, Bdry, Block, Conductor };

// Rewrite all geometry references of a given kind after deletion of
// (0-based) `removed_zero` in the corresponding property list. `removed_one`
// is the 1-based id that no longer exists.
void shift_all(Document& d, RefKind kind, int removed_zero) {
    switch (kind) {
        case RefKind::Point:
            for (auto& n : d.nodes) shift_geom_ref(n.bdry_idx, removed_zero);
            break;
        case RefKind::Bdry:
            for (auto& s : d.segments) shift_geom_ref(s.bdry_idx, removed_zero);
            for (auto& a : d.arcs)     shift_geom_ref(a.bdry_idx, removed_zero);
            break;
        case RefKind::Block:
            for (auto& l : d.labels) shift_geom_ref(l.block_idx, removed_zero);
            break;
        case RefKind::Conductor:
            for (auto& n : d.nodes) shift_geom_ref(n.in_conductor, removed_zero);
            for (auto& s : d.segments) shift_geom_ref(s.in_conductor, removed_zero);
            for (auto& a : d.arcs) shift_geom_ref(a.in_conductor, removed_zero);
            for (auto& l : d.labels) shift_geom_ref(l.circuit_idx, removed_zero);
            break;
    }
}

} // namespace

#define DELETE_GUARD(Vec, Physics)                                             \
    auto* d = reinterpret_cast<Document*>(doc);                                \
    if (!d) return FEMM_ERR_INVALID_ARG;                                       \
    if (d->physics != Physics) return FEMM_ERR_INVALID_ARG;                    \
    if (idx < 0 || (size_t)idx >= d->Vec.size()) return FEMM_ERR_INVALID_ARG;

femm_status_t femm_mag_delete_material(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(mag_materials, FEMM_PHYSICS_MAGNETICS);
    d->mag_materials.erase(d->mag_materials.begin() + idx);
    shift_all(*d, RefKind::Block, idx);
    return FEMM_OK;
}
femm_status_t femm_mag_delete_boundary(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(mag_boundaries, FEMM_PHYSICS_MAGNETICS);
    d->mag_boundaries.erase(d->mag_boundaries.begin() + idx);
    shift_all(*d, RefKind::Bdry, idx);
    return FEMM_OK;
}
femm_status_t femm_mag_delete_pointprop(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(mag_pointprops, FEMM_PHYSICS_MAGNETICS);
    d->mag_pointprops.erase(d->mag_pointprops.begin() + idx);
    shift_all(*d, RefKind::Point, idx);
    return FEMM_OK;
}
femm_status_t femm_mag_delete_circuit(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(mag_circuits, FEMM_PHYSICS_MAGNETICS);
    d->mag_circuits.erase(d->mag_circuits.begin() + idx);
    shift_all(*d, RefKind::Conductor, idx);
    return FEMM_OK;
}

femm_status_t femm_es_delete_material(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(es_materials, FEMM_PHYSICS_ELECTROSTATICS);
    d->es_materials.erase(d->es_materials.begin() + idx);
    shift_all(*d, RefKind::Block, idx);
    return FEMM_OK;
}
femm_status_t femm_es_delete_boundary(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(es_boundaries, FEMM_PHYSICS_ELECTROSTATICS);
    d->es_boundaries.erase(d->es_boundaries.begin() + idx);
    shift_all(*d, RefKind::Bdry, idx);
    return FEMM_OK;
}
femm_status_t femm_es_delete_pointprop(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(es_pointprops, FEMM_PHYSICS_ELECTROSTATICS);
    d->es_pointprops.erase(d->es_pointprops.begin() + idx);
    shift_all(*d, RefKind::Point, idx);
    return FEMM_OK;
}
femm_status_t femm_es_delete_conductor(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(es_conductors, FEMM_PHYSICS_ELECTROSTATICS);
    d->es_conductors.erase(d->es_conductors.begin() + idx);
    shift_all(*d, RefKind::Conductor, idx);
    return FEMM_OK;
}

femm_status_t femm_heat_delete_material(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(heat_materials, FEMM_PHYSICS_HEAT);
    d->heat_materials.erase(d->heat_materials.begin() + idx);
    shift_all(*d, RefKind::Block, idx);
    return FEMM_OK;
}
femm_status_t femm_heat_delete_boundary(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(heat_boundaries, FEMM_PHYSICS_HEAT);
    d->heat_boundaries.erase(d->heat_boundaries.begin() + idx);
    shift_all(*d, RefKind::Bdry, idx);
    return FEMM_OK;
}
femm_status_t femm_heat_delete_pointprop(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(heat_pointprops, FEMM_PHYSICS_HEAT);
    d->heat_pointprops.erase(d->heat_pointprops.begin() + idx);
    shift_all(*d, RefKind::Point, idx);
    return FEMM_OK;
}
femm_status_t femm_heat_delete_conductor(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(heat_conductors, FEMM_PHYSICS_HEAT);
    d->heat_conductors.erase(d->heat_conductors.begin() + idx);
    shift_all(*d, RefKind::Conductor, idx);
    return FEMM_OK;
}

femm_status_t femm_curr_delete_material(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(curr_materials, FEMM_PHYSICS_CURRENT);
    d->curr_materials.erase(d->curr_materials.begin() + idx);
    shift_all(*d, RefKind::Block, idx);
    return FEMM_OK;
}
femm_status_t femm_curr_delete_boundary(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(curr_boundaries, FEMM_PHYSICS_CURRENT);
    d->curr_boundaries.erase(d->curr_boundaries.begin() + idx);
    shift_all(*d, RefKind::Bdry, idx);
    return FEMM_OK;
}
femm_status_t femm_curr_delete_pointprop(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(curr_pointprops, FEMM_PHYSICS_CURRENT);
    d->curr_pointprops.erase(d->curr_pointprops.begin() + idx);
    shift_all(*d, RefKind::Point, idx);
    return FEMM_OK;
}
femm_status_t femm_curr_delete_conductor(femm_doc_t* doc, int32_t idx) {
    DELETE_GUARD(curr_conductors, FEMM_PHYSICS_CURRENT);
    d->curr_conductors.erase(d->curr_conductors.begin() + idx);
    shift_all(*d, RefKind::Conductor, idx);
    return FEMM_OK;
}

#undef DELETE_GUARD

/* ======================================================================
 * BH curve helpers
 * ====================================================================== */
size_t femm_mag_num_bh_points(const femm_doc_t* doc, int32_t mat_idx) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || d->physics != FEMM_PHYSICS_MAGNETICS) return 0;
    if (mat_idx < 0 || (size_t)mat_idx >= d->mag_materials.size()) return 0;
    return d->mag_materials[mat_idx].bh.size();
}
femm_status_t femm_mag_get_bh_point(const femm_doc_t* doc, int32_t mat_idx, int32_t i,
                                    double* B_out, double* H_out) {
    auto* d = reinterpret_cast<const Document*>(doc);
    if (!d || !B_out || !H_out || d->physics != FEMM_PHYSICS_MAGNETICS)
        return FEMM_ERR_INVALID_ARG;
    if (mat_idx < 0 || (size_t)mat_idx >= d->mag_materials.size())
        return FEMM_ERR_INVALID_ARG;
    const auto& bh = d->mag_materials[mat_idx].bh;
    if (i < 0 || (size_t)i >= bh.size()) return FEMM_ERR_INVALID_ARG;
    *B_out = bh[i].first; *H_out = bh[i].second;
    return FEMM_OK;
}
femm_status_t femm_mag_clear_bh(femm_doc_t* doc, int32_t mat_idx) {
    auto* d = reinterpret_cast<Document*>(doc);
    if (!d || d->physics != FEMM_PHYSICS_MAGNETICS) return FEMM_ERR_INVALID_ARG;
    if (mat_idx < 0 || (size_t)mat_idx >= d->mag_materials.size()) return FEMM_ERR_INVALID_ARG;
    d->mag_materials[mat_idx].bh.clear();
    return FEMM_OK;
}

} // extern "C"
