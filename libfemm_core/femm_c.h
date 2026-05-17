/* femm_c.h — C ABI for libfemm_core.
 *
 * Phase A surface: document model, file I/O (.fem/.fee/.feh/.fec), mesh +
 * analyze via subprocess, result loading (.ans/.res/.anh), read-back of
 * nodes/elements/field. Later phases add integrals, editing ops, events,
 * and Lua.
 *
 * Design notes:
 *   - No C++ types cross the boundary. Handles are opaque.
 *   - UTF-8 strings in. Short-lived return strings are valid until the next
 *     call on the same handle; callers must copy if they need to retain.
 *   - All calls return femm_status_t. femm_last_error_message(NULL) returns
 *     the thread-local last-error detail.
 */

#ifndef LIBFEMM_CORE_FEMM_C_H
#define LIBFEMM_CORE_FEMM_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- Status / error codes ------------------------------------------------ */
typedef enum femm_status_e {
    FEMM_OK              = 0,
    FEMM_ERR_IO          = 1,
    FEMM_ERR_PARSE       = 2,
    FEMM_ERR_INVALID_ARG = 3,
    FEMM_ERR_OUT_OF_MEM  = 4,
    FEMM_ERR_NOT_FOUND   = 5,
    FEMM_ERR_SOLVER      = 6,
    FEMM_ERR_LUA         = 7,
    FEMM_ERR_UNSUPPORTED = 8,
    FEMM_ERR_UNKNOWN     = 99
} femm_status_t;

/* --- Physics + problem types -------------------------------------------- */
typedef enum femm_physics_e {
    FEMM_PHYSICS_MAGNETICS      = 0, /* .fem  — fknsolve  */
    FEMM_PHYSICS_ELECTROSTATICS = 1, /* .fee  — belasolve */
    FEMM_PHYSICS_HEAT           = 2, /* .feh  — hsolve    */
    FEMM_PHYSICS_CURRENT        = 3  /* .fec  — csolve    */
} femm_physics_t;

typedef enum femm_problem_type_e {
    FEMM_PROBLEM_PLANAR       = 0,
    FEMM_PROBLEM_AXISYMMETRIC = 1
} femm_problem_type_t;

typedef enum femm_length_units_e {
    FEMM_UNITS_INCHES       = 0,
    FEMM_UNITS_MILLIMETERS  = 1,
    FEMM_UNITS_CENTIMETERS  = 2,
    FEMM_UNITS_METERS       = 3,
    FEMM_UNITS_MILS         = 4,
    FEMM_UNITS_MICROMETERS  = 5
} femm_length_units_t;

typedef struct femm_complex_s { double re, im; } femm_complex_t;

/* --- Opaque handles ----------------------------------------------------- */
typedef struct femm_doc femm_doc_t;
typedef struct femm_result femm_result_t;
typedef struct femm_lua_session femm_lua_session_t;

/* --- Global ------------------------------------------------------------- */
const char*   femm_last_error_message(void);
const char*   femm_version_string(void);

/* --- Document lifecycle ------------------------------------------------- */
femm_status_t femm_doc_new(femm_physics_t physics, femm_doc_t** out);
void          femm_doc_free(femm_doc_t* doc);

femm_status_t femm_doc_open(const char* path, femm_doc_t** out);
femm_status_t femm_doc_save(femm_doc_t* doc, const char* path);

femm_physics_t femm_doc_physics(const femm_doc_t* doc);

/* --- Problem definition ------------------------------------------------- */
femm_status_t femm_doc_set_length_units(femm_doc_t*, femm_length_units_t);
femm_status_t femm_doc_set_problem_type(femm_doc_t*, femm_problem_type_t);
femm_status_t femm_doc_set_depth(femm_doc_t*, double depth);
femm_status_t femm_doc_set_precision(femm_doc_t*, double precision);
femm_status_t femm_doc_set_min_angle(femm_doc_t*, double min_angle_deg);
femm_status_t femm_doc_set_smart_mesh(femm_doc_t*, int32_t on);
femm_status_t femm_doc_set_frequency(femm_doc_t*, double hz); /* magnetics, current */
femm_status_t femm_doc_set_ac_solver(femm_doc_t*, int32_t mode); /* magnetics */
femm_status_t femm_doc_set_comment(femm_doc_t*, const char* utf8);

/* --- Geometry: add primitives ------------------------------------------ */
/* Each returns a stable 0-based index in the respective list. */
femm_status_t femm_add_node(femm_doc_t*, double x, double y, int32_t* idx_out);
femm_status_t femm_add_segment(femm_doc_t*, int32_t n0, int32_t n1, int32_t* idx_out);
femm_status_t femm_add_arc(femm_doc_t*, int32_t n0, int32_t n1,
                           double arc_deg, double max_side_deg,
                           int32_t* idx_out);
femm_status_t femm_add_block_label(femm_doc_t*, double x, double y,
                                   int32_t* idx_out);

femm_status_t femm_set_node_boundary(femm_doc_t*, int32_t idx,
                                     const char* point_prop_name_or_null);
femm_status_t femm_set_node_group(femm_doc_t*, int32_t idx, int32_t group);
femm_status_t femm_set_node_conductor(femm_doc_t*, int32_t idx,
                                      const char* conductor_name_or_null);
femm_status_t femm_set_segment_boundary(femm_doc_t*, int32_t idx,
                                        const char* bdry_name_or_null);
femm_status_t femm_set_segment_max_side(femm_doc_t*, int32_t idx, double max_side);
femm_status_t femm_set_segment_hidden(femm_doc_t*, int32_t idx, int32_t hidden);
femm_status_t femm_set_segment_group(femm_doc_t*, int32_t idx, int32_t group);
femm_status_t femm_set_segment_conductor(femm_doc_t*, int32_t idx,
                                         const char* conductor_name_or_null);
femm_status_t femm_set_arc_boundary(femm_doc_t*, int32_t idx,
                                    const char* bdry_name_or_null);
femm_status_t femm_set_arc_max_side(femm_doc_t*, int32_t idx, double max_side_deg);
femm_status_t femm_set_arc_hidden(femm_doc_t*, int32_t idx, int32_t hidden);
femm_status_t femm_set_arc_group(femm_doc_t*, int32_t idx, int32_t group);
femm_status_t femm_set_arc_conductor(femm_doc_t*, int32_t idx,
                                     const char* conductor_name_or_null);
femm_status_t femm_set_block_label_material(femm_doc_t*, int32_t idx,
                                            const char* block_prop_name_or_null);
femm_status_t femm_set_block_label_max_area(femm_doc_t*, int32_t idx, double max_area);
femm_status_t femm_set_block_label_circuit(femm_doc_t*, int32_t idx,
                                           const char* circuit_name_or_null,
                                           int32_t turns);
femm_status_t femm_set_block_label_magdir(femm_doc_t*, int32_t idx, double mag_dir_deg);
femm_status_t femm_set_block_label_group(femm_doc_t*, int32_t idx, int32_t group);
femm_status_t femm_set_block_label_external(femm_doc_t*, int32_t idx, int32_t is_external);
femm_status_t femm_set_block_label_default(femm_doc_t*, int32_t idx, int32_t is_default);

/* --- Geometry: read-back ------------------------------------------------ */
typedef struct femm_node_view_s {
    double x, y;
    int32_t in_group;
    int32_t bdry_idx;
    int32_t conductor_idx;
} femm_node_view_t;
typedef struct femm_seg_view_s  {
    int32_t n0, n1;
    double max_side;
    int32_t bdry_idx;
    int32_t hidden;
    int32_t in_group;
    int32_t conductor_idx;
} femm_seg_view_t;
typedef struct femm_arc_view_s  {
    int32_t n0, n1;
    double arc_deg, max_side_deg;
    int32_t bdry_idx;
    int32_t hidden;
    int32_t in_group;
    int32_t conductor_idx;
} femm_arc_view_t;
typedef struct femm_lbl_view_s  { double x, y; int32_t block_idx; double max_area;
                                  int32_t circuit_idx; double mag_dir; int32_t turns;
                                  int32_t is_external; int32_t is_default;
                                  int32_t in_group; } femm_lbl_view_t;

size_t femm_num_nodes   (const femm_doc_t*);
size_t femm_num_segments(const femm_doc_t*);
size_t femm_num_arcs    (const femm_doc_t*);
size_t femm_num_labels  (const femm_doc_t*);

femm_status_t femm_get_node   (const femm_doc_t*, int32_t idx, femm_node_view_t* out);
femm_status_t femm_get_segment(const femm_doc_t*, int32_t idx, femm_seg_view_t*  out);
femm_status_t femm_get_arc    (const femm_doc_t*, int32_t idx, femm_arc_view_t*  out);
femm_status_t femm_get_label  (const femm_doc_t*, int32_t idx, femm_lbl_view_t*  out);

/* --- Properties — magnetics (mi_*) -------------------------------------- */
/* The existing .fem tag set; callers pass NULLs for fields they don't care
 * about (NaN means "use default"). Complex fields use femm_complex_t. */
typedef struct femm_mag_material_s {
    const char* name;
    double mu_x;         /* default 1 */
    double mu_y;         /* default 1 */
    double H_c;          /* default 0 */
    double theta_m;      /* deg */
    femm_complex_t J_src; /* MA/m^2 */
    double c_duct;       /* MS/m */
    double lam_d;
    double theta_hn;
    double theta_hx;
    double theta_hy;
    int32_t lam_type;
    double lam_fill;     /* default 1 */
    int32_t n_strands;
    double wire_d;
} femm_mag_material_t;

typedef struct femm_mag_boundary_s {
    const char* name;
    int32_t bdry_format; /* 0..5 */
    double A0, A1, A2, phi;
    femm_complex_t c0, c1;
    double mu, sig;
    double inner_angle, outer_angle;
} femm_mag_boundary_t;

typedef struct femm_mag_pointprop_s {
    const char* name;
    femm_complex_t Jp;   /* A */
    femm_complex_t Ap;   /* Wb/m */
} femm_mag_pointprop_t;

typedef struct femm_mag_circuit_s {
    const char* name;
    femm_complex_t amps;
    int32_t circ_type;   /* 0 parallel, 1 series */
} femm_mag_circuit_t;

femm_status_t femm_mag_add_material  (femm_doc_t*, const femm_mag_material_t*);
femm_status_t femm_mag_add_bh_point  (femm_doc_t*, const char* material_name,
                                      double B, double H);
femm_status_t femm_mag_add_boundary  (femm_doc_t*, const femm_mag_boundary_t*);
femm_status_t femm_mag_add_pointprop (femm_doc_t*, const femm_mag_pointprop_t*);
femm_status_t femm_mag_add_circuit   (femm_doc_t*, const femm_mag_circuit_t*);

/* --- Properties — electrostatics (ei_*) --------------------------------- */
typedef struct femm_es_material_s {
    const char* name;
    double ex, ey;
    double qv; /* volume charge */
} femm_es_material_t;

typedef struct femm_es_boundary_s {
    const char* name;
    int32_t bdry_format; /* 0 fixed-V, 1 mixed, 2 surface-charge, 3 pbc, 4 apbc */
    double V, qs;
    double c0, c1;
} femm_es_boundary_t;

typedef struct femm_es_pointprop_s {
    const char* name;
    double V, qp;
} femm_es_pointprop_t;

typedef struct femm_es_conductor_s {
    const char* name;
    double V, q;
    int32_t circ_type; /* 0 prescribed charge, 1 prescribed voltage */
} femm_es_conductor_t;

femm_status_t femm_es_add_material (femm_doc_t*, const femm_es_material_t*);
femm_status_t femm_es_add_boundary (femm_doc_t*, const femm_es_boundary_t*);
femm_status_t femm_es_add_pointprop(femm_doc_t*, const femm_es_pointprop_t*);
femm_status_t femm_es_add_conductor(femm_doc_t*, const femm_es_conductor_t*);

/* --- Properties — heat (hi_*) ------------------------------------------- */
typedef struct femm_heat_material_s {
    const char* name;
    double Kx, Ky, Kt, qv;
} femm_heat_material_t;

typedef struct femm_heat_boundary_s {
    const char* name;
    int32_t bdry_format; /* 0 fixed-T, 1 heat flux, 2 convection, 3 radiation, 4/5 pbc/apbc */
    double Tset, qs, beta, h, Tinf, TinfRad;
} femm_heat_boundary_t;

typedef struct femm_heat_pointprop_s {
    const char* name;
    double T, qp;
} femm_heat_pointprop_t;

typedef struct femm_heat_conductor_s {
    const char* name;
    double T, q;
    int32_t circ_type;
} femm_heat_conductor_t;

femm_status_t femm_heat_add_material (femm_doc_t*, const femm_heat_material_t*);
femm_status_t femm_heat_add_boundary (femm_doc_t*, const femm_heat_boundary_t*);
femm_status_t femm_heat_add_pointprop(femm_doc_t*, const femm_heat_pointprop_t*);
femm_status_t femm_heat_add_conductor(femm_doc_t*, const femm_heat_conductor_t*);

/* --- Properties — current flow (ci_*) ----------------------------------- */
typedef struct femm_curr_material_s {
    const char* name;
    double ox, oy, ex, ey, ltx, lty;
} femm_curr_material_t;

typedef struct femm_curr_boundary_s {
    const char* name;
    int32_t bdry_format;
    femm_complex_t Vs, qs, c0, c1;
} femm_curr_boundary_t;

typedef struct femm_curr_pointprop_s {
    const char* name;
    femm_complex_t Vp, qp;
} femm_curr_pointprop_t;

typedef struct femm_curr_conductor_s {
    const char* name;
    femm_complex_t Vc, qc;
    int32_t circ_type;
} femm_curr_conductor_t;

femm_status_t femm_curr_add_material (femm_doc_t*, const femm_curr_material_t*);
femm_status_t femm_curr_add_boundary (femm_doc_t*, const femm_curr_boundary_t*);
femm_status_t femm_curr_add_pointprop(femm_doc_t*, const femm_curr_pointprop_t*);
femm_status_t femm_curr_add_conductor(femm_doc_t*, const femm_curr_conductor_t*);

/* --- Property list — count + get/update/delete -------------------------- */
/* All property indices are 0-based and stable until a delete mutates the list.
 * Getter-returned pointers (name strings) remain valid until the next call on
 * the same doc handle; callers must copy if they need to retain them. */

size_t femm_mag_num_materials (const femm_doc_t*);
size_t femm_mag_num_boundaries(const femm_doc_t*);
size_t femm_mag_num_pointprops(const femm_doc_t*);
size_t femm_mag_num_circuits  (const femm_doc_t*);
size_t femm_es_num_materials  (const femm_doc_t*);
size_t femm_es_num_boundaries (const femm_doc_t*);
size_t femm_es_num_pointprops (const femm_doc_t*);
size_t femm_es_num_conductors (const femm_doc_t*);
size_t femm_heat_num_materials (const femm_doc_t*);
size_t femm_heat_num_boundaries(const femm_doc_t*);
size_t femm_heat_num_pointprops(const femm_doc_t*);
size_t femm_heat_num_conductors(const femm_doc_t*);
size_t femm_curr_num_materials (const femm_doc_t*);
size_t femm_curr_num_boundaries(const femm_doc_t*);
size_t femm_curr_num_pointprops(const femm_doc_t*);
size_t femm_curr_num_conductors(const femm_doc_t*);

/* The getters fill the same structs used by the add_* calls. The `name`
 * field points into the document's storage. */
femm_status_t femm_mag_get_material  (const femm_doc_t*, int32_t idx, femm_mag_material_t* out);
femm_status_t femm_mag_get_boundary  (const femm_doc_t*, int32_t idx, femm_mag_boundary_t* out);
femm_status_t femm_mag_get_pointprop (const femm_doc_t*, int32_t idx, femm_mag_pointprop_t* out);
femm_status_t femm_mag_get_circuit   (const femm_doc_t*, int32_t idx, femm_mag_circuit_t* out);
femm_status_t femm_es_get_material   (const femm_doc_t*, int32_t idx, femm_es_material_t* out);
femm_status_t femm_es_get_boundary   (const femm_doc_t*, int32_t idx, femm_es_boundary_t* out);
femm_status_t femm_es_get_pointprop  (const femm_doc_t*, int32_t idx, femm_es_pointprop_t* out);
femm_status_t femm_es_get_conductor  (const femm_doc_t*, int32_t idx, femm_es_conductor_t* out);
femm_status_t femm_heat_get_material (const femm_doc_t*, int32_t idx, femm_heat_material_t* out);
femm_status_t femm_heat_get_boundary (const femm_doc_t*, int32_t idx, femm_heat_boundary_t* out);
femm_status_t femm_heat_get_pointprop(const femm_doc_t*, int32_t idx, femm_heat_pointprop_t* out);
femm_status_t femm_heat_get_conductor(const femm_doc_t*, int32_t idx, femm_heat_conductor_t* out);
femm_status_t femm_curr_get_material (const femm_doc_t*, int32_t idx, femm_curr_material_t* out);
femm_status_t femm_curr_get_boundary (const femm_doc_t*, int32_t idx, femm_curr_boundary_t* out);
femm_status_t femm_curr_get_pointprop(const femm_doc_t*, int32_t idx, femm_curr_pointprop_t* out);
femm_status_t femm_curr_get_conductor(const femm_doc_t*, int32_t idx, femm_curr_conductor_t* out);

/* Update overwrites prop at `idx` from the struct. Name must be non-NULL.
 * Renaming an entry auto-updates any geometry reference that pointed at it. */
femm_status_t femm_mag_update_material  (femm_doc_t*, int32_t idx, const femm_mag_material_t*);
femm_status_t femm_mag_update_boundary  (femm_doc_t*, int32_t idx, const femm_mag_boundary_t*);
femm_status_t femm_mag_update_pointprop (femm_doc_t*, int32_t idx, const femm_mag_pointprop_t*);
femm_status_t femm_mag_update_circuit   (femm_doc_t*, int32_t idx, const femm_mag_circuit_t*);
femm_status_t femm_es_update_material   (femm_doc_t*, int32_t idx, const femm_es_material_t*);
femm_status_t femm_es_update_boundary   (femm_doc_t*, int32_t idx, const femm_es_boundary_t*);
femm_status_t femm_es_update_pointprop  (femm_doc_t*, int32_t idx, const femm_es_pointprop_t*);
femm_status_t femm_es_update_conductor  (femm_doc_t*, int32_t idx, const femm_es_conductor_t*);
femm_status_t femm_heat_update_material (femm_doc_t*, int32_t idx, const femm_heat_material_t*);
femm_status_t femm_heat_update_boundary (femm_doc_t*, int32_t idx, const femm_heat_boundary_t*);
femm_status_t femm_heat_update_pointprop(femm_doc_t*, int32_t idx, const femm_heat_pointprop_t*);
femm_status_t femm_heat_update_conductor(femm_doc_t*, int32_t idx, const femm_heat_conductor_t*);
femm_status_t femm_curr_update_material (femm_doc_t*, int32_t idx, const femm_curr_material_t*);
femm_status_t femm_curr_update_boundary (femm_doc_t*, int32_t idx, const femm_curr_boundary_t*);
femm_status_t femm_curr_update_pointprop(femm_doc_t*, int32_t idx, const femm_curr_pointprop_t*);
femm_status_t femm_curr_update_conductor(femm_doc_t*, int32_t idx, const femm_curr_conductor_t*);

/* Delete removes the entry and rewrites any geometry index that pointed at
 * the deleted prop to 0 ("none"); indices >idx are decremented. */
femm_status_t femm_mag_delete_material  (femm_doc_t*, int32_t idx);
femm_status_t femm_mag_delete_boundary  (femm_doc_t*, int32_t idx);
femm_status_t femm_mag_delete_pointprop (femm_doc_t*, int32_t idx);
femm_status_t femm_mag_delete_circuit   (femm_doc_t*, int32_t idx);
femm_status_t femm_es_delete_material   (femm_doc_t*, int32_t idx);
femm_status_t femm_es_delete_boundary   (femm_doc_t*, int32_t idx);
femm_status_t femm_es_delete_pointprop  (femm_doc_t*, int32_t idx);
femm_status_t femm_es_delete_conductor  (femm_doc_t*, int32_t idx);
femm_status_t femm_heat_delete_material (femm_doc_t*, int32_t idx);
femm_status_t femm_heat_delete_boundary (femm_doc_t*, int32_t idx);
femm_status_t femm_heat_delete_pointprop(femm_doc_t*, int32_t idx);
femm_status_t femm_heat_delete_conductor(femm_doc_t*, int32_t idx);
femm_status_t femm_curr_delete_material (femm_doc_t*, int32_t idx);
femm_status_t femm_curr_delete_boundary (femm_doc_t*, int32_t idx);
femm_status_t femm_curr_delete_pointprop(femm_doc_t*, int32_t idx);
femm_status_t femm_curr_delete_conductor(femm_doc_t*, int32_t idx);

/* BH-curve read/clear for magnetics. */
size_t        femm_mag_num_bh_points(const femm_doc_t*, int32_t mat_idx);
femm_status_t femm_mag_get_bh_point (const femm_doc_t*, int32_t mat_idx, int32_t i,
                                     double* B_out, double* H_out);
femm_status_t femm_mag_clear_bh     (femm_doc_t*, int32_t mat_idx);

/* Problem-def getters (write-only setters are already defined above). */
double   femm_doc_get_precision    (const femm_doc_t*);
double   femm_doc_get_min_angle    (const femm_doc_t*);
int32_t  femm_doc_get_smart_mesh   (const femm_doc_t*);
double   femm_doc_get_depth        (const femm_doc_t*);
double   femm_doc_get_frequency    (const femm_doc_t*);
int32_t  femm_doc_get_ac_solver    (const femm_doc_t*);
femm_length_units_t femm_doc_get_length_units(const femm_doc_t*);
femm_problem_type_t femm_doc_get_problem_type(const femm_doc_t*);
const char* femm_doc_get_comment   (const femm_doc_t*);

/* Geometry mutators the Phase B app was simulating client-side. */
femm_status_t femm_delete_node    (femm_doc_t*, int32_t idx);
femm_status_t femm_delete_segment (femm_doc_t*, int32_t idx);
femm_status_t femm_delete_arc     (femm_doc_t*, int32_t idx);
femm_status_t femm_delete_label   (femm_doc_t*, int32_t idx);
femm_status_t femm_move_node      (femm_doc_t*, int32_t idx, double x, double y);
femm_status_t femm_move_label     (femm_doc_t*, int32_t idx, double x, double y);

/* --- Mesh / analyze ----------------------------------------------------- */
/* Progress callback, invoked from inside femm_doc_analyze — may be NULL.
 * `msg` is a short status line from the solver (non-owning). */
typedef void (*femm_progress_cb)(int32_t percent, const char* msg, void* user);

/* femm_doc_create_mesh writes <root>.poly + .pbc and invokes triangle.
 * femm_doc_analyze runs the appropriate solver binary. Both locate binaries
 * via $FEMM_BIN or by searching upward for build/ (mirrors pymacfemm). */
femm_status_t femm_doc_create_mesh(femm_doc_t*, const char* path);
femm_status_t femm_doc_analyze    (femm_doc_t*, const char* path,
                                   femm_progress_cb cb, void* user);

/* --- Results ------------------------------------------------------------ */
femm_status_t femm_result_load(const char* path, femm_physics_t physics,
                               femm_result_t** out);
void          femm_result_free(femm_result_t*);

size_t        femm_result_num_nodes   (const femm_result_t*);
size_t        femm_result_num_elements(const femm_result_t*);

/* Node coordinates — caller fills two N-length arrays. */
femm_status_t femm_result_get_node_xy(const femm_result_t*,
                                      double* x_out, double* y_out);

/* Scalar nodal field:
 *   magnetics static    → vector potential A     (1 component)
 *   electrostatics      → voltage V              (1 component)
 *   heat                → temperature T          (1 component)
 *   current DC          → voltage V.real         (1 component — use _complex for AC)
 * Returns N values. */
femm_status_t femm_result_get_nodal_scalar(const femm_result_t*, double* out);

/* Complex nodal field: magnetics harmonic / current AC. 2*N doubles (re,im). */
femm_status_t femm_result_get_nodal_complex(const femm_result_t*, femm_complex_t* out);

/* Triangle elements, 3*M int32 — node indices per triangle. */
femm_status_t femm_result_get_elements(const femm_result_t*, int32_t* out_ijk);

/* Frequency stored in the result file header (0 for static). */
double        femm_result_frequency(const femm_result_t*);

/* Per-element label index (1-based block label index from the mesh). M values. */
femm_status_t femm_result_get_element_labels(const femm_result_t*, int32_t* out);

/* Per-element centroid (Mx, My doubles). */
femm_status_t femm_result_get_element_centroids(const femm_result_t*,
                                                double* xo, double* yo);

/* Per-element vector field derived from the nodal scalar + document materials.
 * For magnetics static:   out = B = curl(A) → (Bx, By) per element
 * For electrostatics:     out = E = -grad(V)
 * For heat:               out = F = -k*grad(T)  (uses Kx,Ky from material)
 * For current flow:       out = E = -grad(V.real)  (DC only for now)
 * Output is 2*M doubles (Vx, Vy interleaved). */
femm_status_t femm_result_get_element_vector(const femm_result_t*,
                                             const femm_doc_t* doc,
                                             double* out_vxy);

/* Locate element containing point; returns element index, or -1 if outside.
 * If found and values_out != NULL, writes interpolated scalar (linear T3). */
int32_t       femm_result_locate(const femm_result_t*, double x, double y);

/* Sample nodal scalar + per-element vector at (x,y); returns FEMM_OK if inside.
 * scalar_out (1 double), vec_out (2 doubles) — either may be NULL. */
femm_status_t femm_result_point_values(const femm_result_t*,
                                       const femm_doc_t* doc,
                                       double x, double y,
                                       double* scalar_out,
                                       double* vec_out);

/* --- Post-processor integrals ------------------------------------------ */
/* Line-integral types for magnetics. Contour is an ordered list of (x,y)
 * points in problem units. Each segment is resampled `samples_per_seg`
 * times (0 → default 400). out_z has room for up to 4 complex values; the
 * number actually written is returned in *out_count. */
typedef enum femm_mag_line_int_e {
    FEMM_MAG_LINE_B_DOT_N      = 0, /* Φ flux (Wb) + avg B·n (T)              */
    FEMM_MAG_LINE_H_DOT_T      = 1, /* MMF (A) + avg H·t (A/m)                */
    FEMM_MAG_LINE_LENGTH       = 2, /* length (m) + swept area (m², m²/axi)   */
    FEMM_MAG_LINE_STRESS_FORCE = 3, /* Fx, Fy (N)   — planar; DC only for v1  */
    FEMM_MAG_LINE_STRESS_TORQ  = 4, /* Tz (N·m)                               */
    FEMM_MAG_LINE_B_DOT_N_SQ   = 5  /* ∫(B·n)² dl + avg                        */
} femm_mag_line_int_t;

femm_status_t femm_result_mag_line_integral(const femm_result_t* r,
                                            const femm_doc_t* doc,
                                            int32_t type,
                                            const double* contour_xy,
                                            size_t npts,
                                            int32_t samples_per_seg,
                                            femm_complex_t* out_z,
                                            int32_t* out_count);

/* Magnetics block-integral types. Supported subset (DC, linear materials); AC
 * returns FEMM_ERR_UNSUPPORTED. `label_mask` is a length-`num_labels` array
 * where nonzero elements count toward the integral; NULL = all labels. */
typedef enum femm_mag_block_int_e {
    FEMM_MAG_BLOCK_AJ          = 0,  /* ∫A·J dV  (Wb·A?)                    */
    FEMM_MAG_BLOCK_A           = 1,  /* ∫A dV                                */
    FEMM_MAG_BLOCK_ENERGY      = 2,  /* DC stored energy (J)                 */
    FEMM_MAG_BLOCK_RESISTIVE   = 4,  /* resistive losses (W) — DC: I²·R-ish  */
    FEMM_MAG_BLOCK_AREA        = 5,  /* cross-section area (m²)              */
    FEMM_MAG_BLOCK_CURRENT     = 7,  /* total current in block (A)           */
    FEMM_MAG_BLOCK_BX          = 8,  /* ∫Bx dV                               */
    FEMM_MAG_BLOCK_BY          = 9,  /* ∫By dV                               */
    FEMM_MAG_BLOCK_VOLUME      = 10  /* volume (m³)                          */
} femm_mag_block_int_t;

femm_status_t femm_result_mag_block_integral(const femm_result_t* r,
                                             const femm_doc_t* doc,
                                             int32_t type,
                                             const int32_t* label_mask,
                                             size_t num_labels,
                                             femm_complex_t* out_z);

/* Electrostatics line integral types:
 *   0: E·t — voltage drop (V) + avg (V/m)
 *   1: D·n — total charge (C) + avg D·n (C/m²)
 *   2: length (m)                                                          */
typedef enum femm_es_line_int_e {
    FEMM_ES_LINE_E_DOT_T = 0,
    FEMM_ES_LINE_D_DOT_N = 1,
    FEMM_ES_LINE_LENGTH  = 2
} femm_es_line_int_t;

/* Electrostatics block integral types:
 *   0: ½∫D·E dV — stored energy (J)
 *   1: area (m²)       2: volume (m³)
 *   3: ∫V dV           4: ∫|E|² dV                                         */
typedef enum femm_es_block_int_e {
    FEMM_ES_BLOCK_ENERGY = 0,
    FEMM_ES_BLOCK_AREA   = 1,
    FEMM_ES_BLOCK_VOLUME = 2,
    FEMM_ES_BLOCK_INT_V  = 3,
    FEMM_ES_BLOCK_INT_E2 = 4
} femm_es_block_int_t;

femm_status_t femm_result_es_line_integral (const femm_result_t*, const femm_doc_t*,
    int32_t type, const double* contour_xy, size_t npts, int32_t samples,
    femm_complex_t* out_z, int32_t* out_count);
femm_status_t femm_result_es_block_integral(const femm_result_t*, const femm_doc_t*,
    int32_t type, const int32_t* label_mask, size_t num_labels,
    femm_complex_t* out_z);

/* Heat flow line integral types:
 *   0: ΔT        (K)      1: F·n — heat flux through contour (W)
 *   2: length    (m)      3: avg T along contour (K)                       */
typedef enum femm_heat_line_int_e {
    FEMM_HEAT_LINE_TEMP_DROP = 0,
    FEMM_HEAT_LINE_FLUX      = 1,
    FEMM_HEAT_LINE_LENGTH    = 2,
    FEMM_HEAT_LINE_AVG_T     = 3
} femm_heat_line_int_t;

/* Heat flow block integral types:
 *   0: ∫T dV    (planar: K·m³ via depth, axi: K·m³ via 2π r)
 *   1: area (m²)   2: volume (m³)                                            */
typedef enum femm_heat_block_int_e {
    FEMM_HEAT_BLOCK_INT_T  = 0,
    FEMM_HEAT_BLOCK_AREA   = 1,
    FEMM_HEAT_BLOCK_VOLUME = 2
} femm_heat_block_int_t;

femm_status_t femm_result_heat_line_integral (const femm_result_t*, const femm_doc_t*,
    int32_t type, const double* contour_xy, size_t npts, int32_t samples,
    femm_complex_t* out_z, int32_t* out_count);
femm_status_t femm_result_heat_block_integral(const femm_result_t*, const femm_doc_t*,
    int32_t type, const int32_t* label_mask, size_t num_labels,
    femm_complex_t* out_z);

/* Current flow line integral types (DC subset only):
 *   0: ΔV (V)     1: J·n — total current through contour (A)
 *   2: length (m)                                                            */
typedef enum femm_curr_line_int_e {
    FEMM_CURR_LINE_VOLT_DROP = 0,
    FEMM_CURR_LINE_CURRENT   = 1,
    FEMM_CURR_LINE_LENGTH    = 2
} femm_curr_line_int_t;

/* Current flow block integral types (DC subset):
 *   0: real power ∫|J|²/σ dV (W)
 *   1: area (m²)      2: volume (m³)
 *   3: ∫V dV                                                                 */
typedef enum femm_curr_block_int_e {
    FEMM_CURR_BLOCK_POWER_REAL = 0,
    FEMM_CURR_BLOCK_AREA       = 1,
    FEMM_CURR_BLOCK_VOLUME     = 2,
    FEMM_CURR_BLOCK_INT_V      = 3
} femm_curr_block_int_t;

femm_status_t femm_result_curr_line_integral (const femm_result_t*, const femm_doc_t*,
    int32_t type, const double* contour_xy, size_t npts, int32_t samples,
    femm_complex_t* out_z, int32_t* out_count);
femm_status_t femm_result_curr_block_integral(const femm_result_t*, const femm_doc_t*,
    int32_t type, const int32_t* label_mask, size_t num_labels,
    femm_complex_t* out_z);

/* --- Lua 4.0 compatibility session ---------------------------------------- */
/* The Lua session owns the interpreter and console text. It does not own the
 * active document/result passed through femm_lua_session_set_active. Handles
 * returned by femm_lua_take_replacement_* transfer ownership to the caller. */
femm_status_t femm_lua_session_new(femm_lua_session_t** out);
void          femm_lua_session_free(femm_lua_session_t*);
void          femm_lua_session_set_active(femm_lua_session_t*,
                                          femm_doc_t* doc,
                                          femm_result_t* result,
                                          const char* doc_path_or_null);

femm_status_t femm_lua_eval     (femm_lua_session_t*, const char* text);
femm_status_t femm_lua_eval_file(femm_lua_session_t*, const char* path);

const char*   femm_lua_output(const femm_lua_session_t*);
const char*   femm_lua_error (const femm_lua_session_t*);
void          femm_lua_clear_output(femm_lua_session_t*);

int32_t       femm_lua_take_replacement_doc(femm_lua_session_t*,
                                            femm_doc_t** out_doc,
                                            femm_physics_t* out_physics,
                                            const char** out_path);
int32_t       femm_lua_take_replacement_result(femm_lua_session_t*,
                                               femm_result_t** out_result,
                                               const char** out_path);

size_t        femm_lua_num_commands(void);
const char*   femm_lua_command_name(size_t idx);

#ifdef __cplusplus
}
#endif

#endif /* LIBFEMM_CORE_FEMM_C_H */
