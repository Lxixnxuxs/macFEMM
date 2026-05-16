// FemmDocument.swift — Swift wrapper around the C ABI's opaque femm_doc_t*.
// Owns the handle; publishes an immutable Snapshot whenever geometry mutates
// so SwiftUI views can diff efficiently without touching raw memory.

import Foundation
import FemmCore
import Combine

// Convert a C string pointer into a Swift String; nil pointer -> empty.
fileprivate func str(_ c: UnsafePointer<CChar>?) -> String {
    guard let c else { return "" }
    return String(cString: c)
}

// Compact complex formatter for summaries.
fileprivate func fmtC(_ c: femm_complex_t) -> String {
    if c.im == 0 { return String(format: "%.3g", c.re) }
    return String(format: "%.3g%+.3gj", c.re, c.im)
}

enum Physics: Int32 {
    case magnetics = 0, electrostatics, heat, current
    var fileExt: String {
        switch self {
        case .magnetics: return "fem"
        case .electrostatics: return "fee"
        case .heat: return "feh"
        case .current: return "fec"
        }
    }
    var displayName: String {
        switch self {
        case .magnetics: return "Magnetics"
        case .electrostatics: return "Electrostatics"
        case .heat: return "Heat Flow"
        case .current: return "Current Flow"
        }
    }
    var resultExt: String {
        switch self {
        case .magnetics: return ".ans"
        case .electrostatics: return ".res"
        case .heat: return ".anh"
        case .current: return ".anc"
        }
    }
    var scalarName: String {
        switch self {
        case .magnetics: return "A"
        case .electrostatics: return "V"
        case .heat: return "T"
        case .current: return "V"
        }
    }
    var vectorName: String {
        switch self {
        case .magnetics: return "B"
        case .electrostatics: return "E"
        case .heat: return "F"
        case .current: return "E"
        }
    }
    var femmPhysics: femm_physics_t {
        switch self {
        case .magnetics: return FEMM_PHYSICS_MAGNETICS
        case .electrostatics: return FEMM_PHYSICS_ELECTROSTATICS
        case .heat: return FEMM_PHYSICS_HEAT
        case .current: return FEMM_PHYSICS_CURRENT
        }
    }
}

struct DocSnapshot: Equatable {
    struct Node: Equatable { var x, y: Double; var bdryIdx: Int32 }
    struct Segment: Equatable { var n0, n1: Int32; var bdryIdx: Int32 }
    struct Arc: Equatable { var n0, n1: Int32; var arcDeg, maxSideDeg: Double; var bdryIdx: Int32 }
    struct Label: Equatable {
        var x, y: Double
        var blockIdx: Int32
        var maxArea: Double
        var circuitIdx: Int32
        var magDir: Double
        var turns: Int32
        var isExternal: Bool
    }

    // Lightweight property-list mirrors. We only display the name + a one-
    // line summary; the editor sheet round-trips the full C struct on demand.
    struct PropEntry: Equatable, Identifiable {
        var idx: Int32
        var name: String
        var summary: String
        var id: Int32 { idx }
    }

    var physics: Physics = .magnetics
    var nodes: [Node] = []
    var segments: [Segment] = []
    var arcs: [Arc] = []
    var labels: [Label] = []

    var materials: [PropEntry] = []
    var boundaries: [PropEntry] = []
    var pointProps: [PropEntry] = []
    var circuits: [PropEntry] = []   // magnetics = circuits; other physics = conductors

    // Problem-def mirrors (enough for the form).
    var lengthUnits: femm_length_units_t = FEMM_UNITS_MILLIMETERS
    var problemType: femm_problem_type_t = FEMM_PROBLEM_PLANAR
    var depth: Double = 1.0
    var precision: Double = 1e-8
    var minAngle: Double = 30.0
    var smartMesh: Bool = true
    var frequency: Double = 0.0
    var acSolver: Int32 = 0
    var comment: String = ""
}

struct ResultSnapshot {
    var physics: Physics = .magnetics
    var frequency: Double = 0.0
    var nodeX: [Double] = []
    var nodeY: [Double] = []
    var nodeScalar: [Double] = []          // A / V / T / V
    var elements: [Int32] = []             // 3*M node indices
    var elementLabels: [Int32] = []        // M, 1-based label idx
    var elementCentroidX: [Double] = []
    var elementCentroidY: [Double] = []
    var elementVx: [Double] = []           // M
    var elementVy: [Double] = []           // M
    // Field stats
    var scalarMin: Double = 0
    var scalarMax: Double = 0
    var vectorMagMin: Double = 0
    var vectorMagMax: Double = 0
    var bounds: (min: (x: Double, y: Double), max: (x: Double, y: Double))? = nil

    var isEmpty: Bool { nodeX.isEmpty }
}

final class FemmDocument: ObservableObject {
    private var handle: OpaquePointer?
    private var resultHandle: OpaquePointer?
    @Published private(set) var snapshot = DocSnapshot()
    @Published private(set) var result = ResultSnapshot()
    @Published var fileURL: URL?
    @Published var isDirty: Bool = false

    // Selection (indices into snapshot lists).
    @Published var selectedNodes: Set<Int> = []
    @Published var selectedSegments: Set<Int> = []
    @Published var selectedLabels: Set<Int> = []

    // Post-processor contour (world-space polyline for line-integrals and
    // XY plots). Cleared whenever the solution is reloaded.
    @Published var contour: [CGPoint] = []

    func contourAppend(_ p: CGPoint) { contour.append(p) }
    func contourRemoveLast() { if !contour.isEmpty { contour.removeLast() } }
    func contourClear() { contour.removeAll() }

    /// Replace the last contour segment with a circular arc sampled at
    /// `anglestep` degrees. Matches `femm/*viewDoc.cpp::BendContour`. Angle is
    /// the subtended arc in degrees; positive bends left (CCW), negative
    /// bends right (CW). Clamped to [-180, 180].
    func contourBendLast(angleDeg: Double, stepDeg: Double = 1.0) {
        if angleDeg == 0 { return }
        if angleDeg < -180 || angleDeg > 180 { return }
        guard contour.count >= 2 else { return }
        let step = stepDeg == 0 ? 1.0 : stepDeg
        let n = Int(ceil(abs(angleDeg / step)))
        let tta = angleDeg * .pi / 180.0
        let dtta = tta / Double(n)
        let a1 = contour.removeLast()
        let a0 = contour.last!
        let dx = Double(a1.x - a0.x)
        let dy = Double(a1.y - a0.y)
        let d = (dx*dx + dy*dy).squareRoot()
        if d == 0 { contour.append(a1); return }
        let R = d / (2.0 * sin(abs(tta / 2.0)))
        /* rotate the a0→a1 chord by ±(π ∓ tta)/2 and walk R/d along it. */
        let phi = tta > 0 ? (.pi - tta) / 2.0 : -(.pi + tta) / 2.0
        let cs = cos(phi), sn = sin(phi)
        let cx = Double(a0.x) + (R / d) * (dx * cs - dy * sn)
        let cy = Double(a0.y) + (R / d) * (dx * sn + dy * cs)
        for k in 1...n {
            let ang = Double(k) * dtta
            let ca = cos(ang), sa = sin(ang)
            let vx = Double(a0.x) - cx
            let vy = Double(a0.y) - cy
            let px = cx + vx * ca - vy * sa
            let py = cy + vx * sa + vy * ca
            contour.append(CGPoint(x: px, y: py))
        }
    }

    init(physics: Physics) {
        var out: OpaquePointer?
        let st = femm_doc_new(femm_physics_t(UInt32(physics.rawValue)), &out)
        precondition(st == FEMM_OK, "femm_doc_new failed")
        self.handle = out
        self.snapshot.physics = physics
    }

    init(url: URL) throws {
        var out: OpaquePointer?
        let st = url.path.withCString { femm_doc_open($0, &out) }
        guard st == FEMM_OK, let h = out else {
            throw NSError(domain: "FEMM", code: Int(st.rawValue),
                          userInfo: [NSLocalizedDescriptionKey:
                            String(cString: femm_last_error_message())])
        }
        self.handle = h
        self.fileURL = url
        rebuildSnapshot()
    }

    deinit {
        if let h = handle { femm_doc_free(h) }
        if let r = resultHandle { femm_result_free(r) }
    }

    var raw: OpaquePointer? { handle }

    func adoptLuaDocument(_ newHandle: OpaquePointer, path: String?) {
        if let old = handle { femm_doc_free(old) }
        if let oldResult = resultHandle { femm_result_free(oldResult) }
        handle = newHandle
        resultHandle = nil
        fileURL = path.map { URL(fileURLWithPath: $0) }
        selectedNodes.removeAll()
        selectedSegments.removeAll()
        selectedLabels.removeAll()
        contour.removeAll()
        result = ResultSnapshot()
        isDirty = true
        rebuildSnapshot()
    }

    func adoptLuaResult(_ newHandle: OpaquePointer) {
        if let old = resultHandle { femm_result_free(old) }
        resultHandle = newHandle
        contour.removeAll()
        rebuildResultSnapshot()
    }

    func refreshAfterLuaEvaluation() {
        selectedNodes.removeAll()
        selectedSegments.removeAll()
        selectedLabels.removeAll()
        isDirty = true
        rebuildSnapshot()
        if resultHandle != nil { rebuildResultSnapshot() }
    }

    // MARK: - Snapshot rebuild
    func rebuildSnapshot() {
        guard let h = handle else { return }
        var snap = DocSnapshot()
        snap.physics = Physics(rawValue: Int32(femm_doc_physics(h).rawValue)) ?? .magnetics

        let nn = femm_num_nodes(h)
        snap.nodes.reserveCapacity(Int(nn))
        for i in 0..<Int32(nn) {
            var v = femm_node_view_t(); femm_get_node(h, i, &v)
            snap.nodes.append(.init(x: v.x, y: v.y, bdryIdx: v.bdry_idx))
        }
        let ns = femm_num_segments(h)
        snap.segments.reserveCapacity(Int(ns))
        for i in 0..<Int32(ns) {
            var v = femm_seg_view_t(); femm_get_segment(h, i, &v)
            snap.segments.append(.init(n0: v.n0, n1: v.n1, bdryIdx: v.bdry_idx))
        }
        let na = femm_num_arcs(h)
        snap.arcs.reserveCapacity(Int(na))
        for i in 0..<Int32(na) {
            var v = femm_arc_view_t(); femm_get_arc(h, i, &v)
            snap.arcs.append(.init(n0: v.n0, n1: v.n1,
                                   arcDeg: v.arc_deg, maxSideDeg: v.max_side_deg,
                                   bdryIdx: v.bdry_idx))
        }
        let nl = femm_num_labels(h)
        snap.labels.reserveCapacity(Int(nl))
        for i in 0..<Int32(nl) {
            var v = femm_lbl_view_t(); femm_get_label(h, i, &v)
            snap.labels.append(.init(x: v.x, y: v.y, blockIdx: v.block_idx, maxArea: v.max_area,
                                     circuitIdx: v.circuit_idx, magDir: v.mag_dir, turns: v.turns,
                                     isExternal: v.is_external != 0))
        }

        // Problem def
        snap.lengthUnits = femm_doc_get_length_units(h)
        snap.problemType = femm_doc_get_problem_type(h)
        snap.depth     = femm_doc_get_depth(h)
        snap.precision = femm_doc_get_precision(h)
        snap.minAngle  = femm_doc_get_min_angle(h)
        snap.smartMesh = femm_doc_get_smart_mesh(h) != 0
        snap.frequency = femm_doc_get_frequency(h)
        snap.acSolver  = femm_doc_get_ac_solver(h)
        snap.comment   = String(cString: femm_doc_get_comment(h))

        // Property lists
        snap.materials   = loadPropEntries(h: h, kind: .materials, physics: snap.physics)
        snap.boundaries  = loadPropEntries(h: h, kind: .boundaries, physics: snap.physics)
        snap.pointProps  = loadPropEntries(h: h, kind: .pointProps, physics: snap.physics)
        snap.circuits    = loadPropEntries(h: h, kind: .circuits, physics: snap.physics)

        self.snapshot = snap
    }

    enum PropKind { case materials, boundaries, pointProps, circuits }

    private func loadPropEntries(h: OpaquePointer, kind: PropKind, physics: Physics) -> [DocSnapshot.PropEntry] {
        var out: [DocSnapshot.PropEntry] = []
        let count: Int
        switch (kind, physics) {
        case (.materials, .magnetics):      count = Int(femm_mag_num_materials(h))
        case (.boundaries, .magnetics):     count = Int(femm_mag_num_boundaries(h))
        case (.pointProps, .magnetics):     count = Int(femm_mag_num_pointprops(h))
        case (.circuits, .magnetics):       count = Int(femm_mag_num_circuits(h))
        case (.materials, .electrostatics): count = Int(femm_es_num_materials(h))
        case (.boundaries, .electrostatics):count = Int(femm_es_num_boundaries(h))
        case (.pointProps, .electrostatics):count = Int(femm_es_num_pointprops(h))
        case (.circuits, .electrostatics):  count = Int(femm_es_num_conductors(h))
        case (.materials, .heat):           count = Int(femm_heat_num_materials(h))
        case (.boundaries, .heat):          count = Int(femm_heat_num_boundaries(h))
        case (.pointProps, .heat):          count = Int(femm_heat_num_pointprops(h))
        case (.circuits, .heat):            count = Int(femm_heat_num_conductors(h))
        case (.materials, .current):        count = Int(femm_curr_num_materials(h))
        case (.boundaries, .current):       count = Int(femm_curr_num_boundaries(h))
        case (.pointProps, .current):       count = Int(femm_curr_num_pointprops(h))
        case (.circuits, .current):         count = Int(femm_curr_num_conductors(h))
        }
        out.reserveCapacity(count)
        for i in 0..<Int32(count) {
            if let entry = readPropEntry(h: h, kind: kind, physics: physics, idx: i) {
                out.append(entry)
            }
        }
        return out
    }

    private func readPropEntry(h: OpaquePointer, kind: PropKind, physics: Physics, idx: Int32) -> DocSnapshot.PropEntry? {
        switch (kind, physics) {
        case (.materials, .magnetics):
            var s = femm_mag_material_t()
            guard femm_mag_get_material(h, idx, &s) == FEMM_OK else { return nil }
            let summary = String(format: "μx=%.3g μy=%.3g σ=%.3g", s.mu_x, s.mu_y, s.c_duct)
            return .init(idx: idx, name: str(s.name), summary: summary)
        case (.boundaries, .magnetics):
            var s = femm_mag_boundary_t()
            guard femm_mag_get_boundary(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "type \(s.bdry_format)")
        case (.pointProps, .magnetics):
            var s = femm_mag_pointprop_t()
            guard femm_mag_get_pointprop(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "J=\(fmtC(s.Jp)) A=\(fmtC(s.Ap))")
        case (.circuits, .magnetics):
            var s = femm_mag_circuit_t()
            guard femm_mag_get_circuit(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "I=\(fmtC(s.amps)) A")
        case (.materials, .electrostatics):
            var s = femm_es_material_t()
            guard femm_es_get_material(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: String(format: "εx=%.3g εy=%.3g", s.ex, s.ey))
        case (.boundaries, .electrostatics):
            var s = femm_es_boundary_t()
            guard femm_es_get_boundary(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "type \(s.bdry_format)")
        case (.pointProps, .electrostatics):
            var s = femm_es_pointprop_t()
            guard femm_es_get_pointprop(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: String(format: "V=%.3g qp=%.3g", s.V, s.qp))
        case (.circuits, .electrostatics):
            var s = femm_es_conductor_t()
            guard femm_es_get_conductor(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: s.circ_type == 1 ? String(format: "V=%.3g", s.V)
                                                   : String(format: "q=%.3g", s.q))
        case (.materials, .heat):
            var s = femm_heat_material_t()
            guard femm_heat_get_material(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: String(format: "Kx=%.3g Ky=%.3g", s.Kx, s.Ky))
        case (.boundaries, .heat):
            var s = femm_heat_boundary_t()
            guard femm_heat_get_boundary(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "type \(s.bdry_format)")
        case (.pointProps, .heat):
            var s = femm_heat_pointprop_t()
            guard femm_heat_get_pointprop(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: String(format: "T=%.3g qp=%.3g", s.T, s.qp))
        case (.circuits, .heat):
            var s = femm_heat_conductor_t()
            guard femm_heat_get_conductor(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: s.circ_type == 1 ? String(format: "T=%.3g", s.T)
                                                   : String(format: "q=%.3g", s.q))
        case (.materials, .current):
            var s = femm_curr_material_t()
            guard femm_curr_get_material(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: String(format: "σx=%.3g σy=%.3g", s.ox, s.oy))
        case (.boundaries, .current):
            var s = femm_curr_boundary_t()
            guard femm_curr_get_boundary(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "type \(s.bdry_format)")
        case (.pointProps, .current):
            var s = femm_curr_pointprop_t()
            guard femm_curr_get_pointprop(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name), summary: "V=\(fmtC(s.Vp))")
        case (.circuits, .current):
            var s = femm_curr_conductor_t()
            guard femm_curr_get_conductor(h, idx, &s) == FEMM_OK else { return nil }
            return .init(idx: idx, name: str(s.name),
                         summary: s.circ_type == 1 ? "V=\(fmtC(s.Vc))" : "q=\(fmtC(s.qc))")
        }
    }

    // MARK: - Mutations
    @discardableResult
    func addNode(x: Double, y: Double) -> Int32 {
        guard let h = handle else { return -1 }
        var idx: Int32 = -1
        femm_add_node(h, x, y, &idx)
        isDirty = true
        rebuildSnapshot()
        return idx
    }

    @discardableResult
    func addSegment(n0: Int32, n1: Int32) -> Int32 {
        guard let h = handle, n0 != n1 else { return -1 }
        var idx: Int32 = -1
        let st = femm_add_segment(h, n0, n1, &idx)
        guard st == FEMM_OK else { return -1 }
        isDirty = true
        rebuildSnapshot()
        return idx
    }

    @discardableResult
    func addLabel(x: Double, y: Double) -> Int32 {
        guard let h = handle else { return -1 }
        var idx: Int32 = -1
        femm_add_block_label(h, x, y, &idx)
        isDirty = true
        rebuildSnapshot()
        return idx
    }

    // Delete all currently-selected geometry via the C ABI. Nodes go last so
    // segment/label index shifts don't invalidate earlier index choices (the
    // C side drops referencing segments/arcs anyway, so we explicitly delete
    // segments/labels first to keep user intent clean).
    func deleteSelected() {
        guard let h = handle else { return }
        if !selectedSegments.isEmpty {
            for i in selectedSegments.sorted(by: >) { femm_delete_segment(h, Int32(i)) }
        }
        if !selectedLabels.isEmpty {
            for i in selectedLabels.sorted(by: >) { femm_delete_label(h, Int32(i)) }
        }
        if !selectedNodes.isEmpty {
            for i in selectedNodes.sorted(by: >) { femm_delete_node(h, Int32(i)) }
        }
        selectedNodes.removeAll(); selectedSegments.removeAll(); selectedLabels.removeAll()
        isDirty = true
        rebuildSnapshot()
    }

    // MARK: - I/O
    func save(to url: URL) throws {
        guard let h = handle else { return }
        let st = url.path.withCString { femm_doc_save(h, $0) }
        guard st == FEMM_OK else {
            throw NSError(domain: "FEMM", code: Int(st.rawValue),
                          userInfo: [NSLocalizedDescriptionKey:
                            String(cString: femm_last_error_message())])
        }
        fileURL = url
        isDirty = false
    }

    // MARK: - Property CRUD bridge
    func deleteProp(kind: PropKind, idx: Int32) {
        guard let h = handle else { return }
        let status: femm_status_t
        switch (kind, snapshot.physics) {
        case (.materials, .magnetics):       status = femm_mag_delete_material(h, idx)
        case (.boundaries, .magnetics):      status = femm_mag_delete_boundary(h, idx)
        case (.pointProps, .magnetics):      status = femm_mag_delete_pointprop(h, idx)
        case (.circuits, .magnetics):        status = femm_mag_delete_circuit(h, idx)
        case (.materials, .electrostatics):  status = femm_es_delete_material(h, idx)
        case (.boundaries, .electrostatics): status = femm_es_delete_boundary(h, idx)
        case (.pointProps, .electrostatics): status = femm_es_delete_pointprop(h, idx)
        case (.circuits, .electrostatics):   status = femm_es_delete_conductor(h, idx)
        case (.materials, .heat):            status = femm_heat_delete_material(h, idx)
        case (.boundaries, .heat):           status = femm_heat_delete_boundary(h, idx)
        case (.pointProps, .heat):           status = femm_heat_delete_pointprop(h, idx)
        case (.circuits, .heat):             status = femm_heat_delete_conductor(h, idx)
        case (.materials, .current):         status = femm_curr_delete_material(h, idx)
        case (.boundaries, .current):        status = femm_curr_delete_boundary(h, idx)
        case (.pointProps, .current):        status = femm_curr_delete_pointprop(h, idx)
        case (.circuits, .current):          status = femm_curr_delete_conductor(h, idx)
        }
        if status == FEMM_OK { isDirty = true }
        rebuildSnapshot()
    }

    // MARK: - BH curve
    func bhPoints(materialIdx: Int32) -> [(B: Double, H: Double)] {
        guard let h = handle else { return [] }
        let n = Int(femm_mag_num_bh_points(h, materialIdx))
        var out: [(Double, Double)] = []
        out.reserveCapacity(n)
        for i in 0..<Int32(n) {
            var B = 0.0, H = 0.0
            if femm_mag_get_bh_point(h, materialIdx, i, &B, &H) == FEMM_OK {
                out.append((B, H))
            }
        }
        return out
    }

    func setBHPoints(materialIdx: Int32, materialName: String, points: [(B: Double, H: Double)]) {
        guard let h = handle else { return }
        femm_mag_clear_bh(h, materialIdx)
        for (B, H) in points {
            materialName.withCString { femm_mag_add_bh_point(h, $0, B, H) }
        }
        isDirty = true
        rebuildSnapshot()
    }

    // MARK: - Geometry mutators bridging to C ABI
    func deleteNodes(at indices: [Int]) {
        guard let h = handle else { return }
        // Delete in descending order so indices stay stable.
        for i in indices.sorted(by: >) {
            femm_delete_node(h, Int32(i))
        }
        isDirty = true
        rebuildSnapshot()
        selectedNodes.removeAll()
    }
    func deleteSegments(at indices: [Int]) {
        guard let h = handle else { return }
        for i in indices.sorted(by: >) { femm_delete_segment(h, Int32(i)) }
        isDirty = true; rebuildSnapshot(); selectedSegments.removeAll()
    }
    func deleteLabels(at indices: [Int]) {
        guard let h = handle else { return }
        for i in indices.sorted(by: >) { femm_delete_label(h, Int32(i)) }
        isDirty = true; rebuildSnapshot(); selectedLabels.removeAll()
    }
    func moveNode(idx: Int, x: Double, y: Double) {
        guard let h = handle else { return }
        femm_move_node(h, Int32(idx), x, y)
        isDirty = true; rebuildSnapshot()
    }
    func moveLabel(idx: Int, x: Double, y: Double) {
        guard let h = handle else { return }
        femm_move_label(h, Int32(idx), x, y)
        isDirty = true; rebuildSnapshot()
    }

    // MARK: - Selected-geometry property assignment
    func assignNodePointProp(_ name: String?) {
        guard let h = handle else { return }
        let cname = name ?? ""
        for i in selectedNodes {
            cname.withCString { femm_set_node_boundary(h, Int32(i), name == nil ? nil : $0) }
        }
        isDirty = true; rebuildSnapshot()
    }
    func assignSegmentBoundary(_ name: String?) {
        guard let h = handle else { return }
        let cname = name ?? ""
        for i in selectedSegments {
            cname.withCString { femm_set_segment_boundary(h, Int32(i), name == nil ? nil : $0) }
        }
        isDirty = true; rebuildSnapshot()
    }
    func assignLabelMaterial(_ name: String?) {
        guard let h = handle else { return }
        let cname = name ?? ""
        for i in selectedLabels {
            cname.withCString { femm_set_block_label_material(h, Int32(i), name == nil ? nil : $0) }
        }
        isDirty = true; rebuildSnapshot()
    }
    func assignLabelCircuit(_ name: String?, turns: Int32) {
        guard let h = handle else { return }
        let cname = name ?? ""
        for i in selectedLabels {
            cname.withCString { femm_set_block_label_circuit(h, Int32(i), name == nil ? nil : $0, turns) }
        }
        isDirty = true; rebuildSnapshot()
    }
    func setLabelMaxArea(_ area: Double) {
        guard let h = handle else { return }
        for i in selectedLabels { femm_set_block_label_max_area(h, Int32(i), area) }
        isDirty = true; rebuildSnapshot()
    }
    func setLabelMagDir(_ deg: Double) {
        guard let h = handle else { return }
        for i in selectedLabels { femm_set_block_label_magdir(h, Int32(i), deg) }
        isDirty = true; rebuildSnapshot()
    }
    func setSegmentMaxSide(_ ms: Double) {
        guard let h = handle else { return }
        for i in selectedSegments { femm_set_segment_max_side(h, Int32(i), ms) }
        isDirty = true; rebuildSnapshot()
    }

    // MARK: - Problem definition setters
    func setProblemDef(lengthUnits: femm_length_units_t? = nil,
                       problemType: femm_problem_type_t? = nil,
                       depth: Double? = nil,
                       precision: Double? = nil,
                       minAngle: Double? = nil,
                       smartMesh: Bool? = nil,
                       frequency: Double? = nil,
                       acSolver: Int32? = nil,
                       comment: String? = nil) {
        guard let h = handle else { return }
        if let v = lengthUnits  { femm_doc_set_length_units(h, v) }
        if let v = problemType  { femm_doc_set_problem_type(h, v) }
        if let v = depth        { femm_doc_set_depth(h, v) }
        if let v = precision    { femm_doc_set_precision(h, v) }
        if let v = minAngle     { femm_doc_set_min_angle(h, v) }
        if let v = smartMesh    { femm_doc_set_smart_mesh(h, v ? 1 : 0) }
        if let v = frequency    { femm_doc_set_frequency(h, v) }
        if let v = acSolver     { femm_doc_set_ac_solver(h, v) }
        if let v = comment      { v.withCString { femm_doc_set_comment(h, $0) } }
        isDirty = true; rebuildSnapshot()
    }

    func markDirtyAndReload() {
        isDirty = true
        rebuildSnapshot()
        // Any edit invalidates the post-processor view.
        if !result.isEmpty { clearResult() }
    }

    // MARK: - Results

    func loadSolution(at path: String) {
        var rp: OpaquePointer?
        let st = path.withCString { femm_result_load($0, snapshot.physics.femmPhysics, &rp) }
        guard st == FEMM_OK, let rp = rp else { return }
        if let old = resultHandle { femm_result_free(old) }
        resultHandle = rp
        rebuildResultSnapshot()
    }

    func clearResult() {
        if let r = resultHandle { femm_result_free(r); resultHandle = nil }
        result = ResultSnapshot()
        contour.removeAll()
    }

    var rawResult: OpaquePointer? { resultHandle }

    private func rebuildResultSnapshot() {
        guard let rp = resultHandle, let h = handle else { return }
        let n = Int(femm_result_num_nodes(rp))
        let m = Int(femm_result_num_elements(rp))
        var snap = ResultSnapshot()
        snap.physics = snapshot.physics
        snap.frequency = femm_result_frequency(rp)
        snap.nodeX = Array(repeating: 0.0, count: n)
        snap.nodeY = Array(repeating: 0.0, count: n)
        snap.nodeX.withUnsafeMutableBufferPointer { xb in
            snap.nodeY.withUnsafeMutableBufferPointer { yb in
                _ = femm_result_get_node_xy(rp, xb.baseAddress, yb.baseAddress)
            }
        }
        snap.nodeScalar = Array(repeating: 0.0, count: n)
        snap.nodeScalar.withUnsafeMutableBufferPointer { b in
            _ = femm_result_get_nodal_scalar(rp, b.baseAddress)
        }
        snap.elements = Array(repeating: 0, count: 3 * m)
        snap.elements.withUnsafeMutableBufferPointer { b in
            _ = femm_result_get_elements(rp, b.baseAddress)
        }
        snap.elementLabels = Array(repeating: 0, count: m)
        snap.elementLabels.withUnsafeMutableBufferPointer { b in
            _ = femm_result_get_element_labels(rp, b.baseAddress)
        }
        snap.elementCentroidX = Array(repeating: 0.0, count: m)
        snap.elementCentroidY = Array(repeating: 0.0, count: m)
        snap.elementCentroidX.withUnsafeMutableBufferPointer { xb in
            snap.elementCentroidY.withUnsafeMutableBufferPointer { yb in
                _ = femm_result_get_element_centroids(rp, xb.baseAddress, yb.baseAddress)
            }
        }
        var vxy = Array(repeating: 0.0, count: 2 * m)
        vxy.withUnsafeMutableBufferPointer { b in
            _ = femm_result_get_element_vector(rp, h, b.baseAddress)
        }
        snap.elementVx = Array(repeating: 0.0, count: m)
        snap.elementVy = Array(repeating: 0.0, count: m)
        for e in 0..<m {
            snap.elementVx[e] = vxy[2*e]
            snap.elementVy[e] = vxy[2*e + 1]
        }
        if !snap.nodeScalar.isEmpty {
            snap.scalarMin = snap.nodeScalar.min() ?? 0
            snap.scalarMax = snap.nodeScalar.max() ?? 0
        }
        var magMin = Double.infinity, magMax = -Double.infinity
        for e in 0..<m {
            let v = (snap.elementVx[e] * snap.elementVx[e] + snap.elementVy[e] * snap.elementVy[e]).squareRoot()
            if v < magMin { magMin = v }
            if v > magMax { magMax = v }
        }
        if m > 0 { snap.vectorMagMin = magMin; snap.vectorMagMax = magMax }
        if n > 0 {
            snap.bounds = (min: (snap.nodeX.min()!, snap.nodeY.min()!),
                           max: (snap.nodeX.max()!, snap.nodeY.max()!))
        }
        result = snap
    }

    func samplePoint(x: Double, y: Double) -> (scalar: Double, vx: Double, vy: Double)? {
        guard let rp = resultHandle, let h = handle else { return nil }
        var s: Double = 0
        var v = [Double](repeating: 0, count: 2)
        let st = v.withUnsafeMutableBufferPointer { vb -> femm_status_t in
            return femm_result_point_values(rp, h, x, y, &s, vb.baseAddress)
        }
        guard st == FEMM_OK else { return nil }
        return (s, v[0], v[1])
    }

    // MARK: - Integrals

    struct IntegralError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    typealias LineIntegralFn = (
        OpaquePointer?, OpaquePointer?, Int32,
        UnsafePointer<Double>?, Int, Int32,
        UnsafeMutablePointer<femm_complex_t>?, UnsafeMutablePointer<Int32>?
    ) -> femm_status_t

    typealias BlockIntegralFn = (
        OpaquePointer?, OpaquePointer?, Int32,
        UnsafePointer<Int32>?, Int,
        UnsafeMutablePointer<femm_complex_t>?
    ) -> femm_status_t

    private func callLineIntegral(_ fn: LineIntegralFn,
                                  type: Int32, samples: Int32) throws -> [femm_complex_t] {
        guard let rp = resultHandle, let h = handle else {
            throw IntegralError(message: "No solution loaded")
        }
        let pts = contour
        guard pts.count >= 2 else {
            throw IntegralError(message: "Need at least 2 contour points")
        }
        var flat = [Double]()
        flat.reserveCapacity(pts.count * 2)
        for p in pts { flat.append(Double(p.x)); flat.append(Double(p.y)) }
        var out = [femm_complex_t](repeating: femm_complex_t(re: 0, im: 0), count: 4)
        var count: Int32 = 0
        let st = flat.withUnsafeBufferPointer { fb in
            out.withUnsafeMutableBufferPointer { ob in
                fn(rp, h, type, fb.baseAddress, pts.count, samples,
                   ob.baseAddress, &count)
            }
        }
        guard st == FEMM_OK else {
            throw IntegralError(message: String(cString: femm_last_error_message()))
        }
        return Array(out.prefix(Int(count)))
    }

    private func callBlockIntegral(_ fn: BlockIntegralFn,
                                   type: Int32,
                                   labelIndices: Set<Int>) throws -> femm_complex_t {
        guard let rp = resultHandle, let h = handle else {
            throw IntegralError(message: "No solution loaded")
        }
        let n = snapshot.labels.count
        var out = femm_complex_t(re: 0, im: 0)
        let st: femm_status_t
        if labelIndices.isEmpty {
            st = fn(rp, h, type, nil, 0, &out)
        } else {
            var mask = [Int32](repeating: 0, count: n)
            for i in labelIndices where i >= 0 && i < n { mask[i] = 1 }
            st = mask.withUnsafeBufferPointer { mb in
                fn(rp, h, type, mb.baseAddress, n, &out)
            }
        }
        guard st == FEMM_OK else {
            throw IntegralError(message: String(cString: femm_last_error_message()))
        }
        return out
    }

    func magLineIntegral (type: Int32, samples: Int32 = 400) throws -> [femm_complex_t] {
        try callLineIntegral(femm_result_mag_line_integral, type: type, samples: samples)
    }
    func magBlockIntegral(type: Int32, labelIndices: Set<Int>) throws -> femm_complex_t {
        try callBlockIntegral(femm_result_mag_block_integral, type: type, labelIndices: labelIndices)
    }
    func esLineIntegral (type: Int32, samples: Int32 = 400) throws -> [femm_complex_t] {
        try callLineIntegral(femm_result_es_line_integral, type: type, samples: samples)
    }
    func esBlockIntegral(type: Int32, labelIndices: Set<Int>) throws -> femm_complex_t {
        try callBlockIntegral(femm_result_es_block_integral, type: type, labelIndices: labelIndices)
    }
    func heatLineIntegral (type: Int32, samples: Int32 = 400) throws -> [femm_complex_t] {
        try callLineIntegral(femm_result_heat_line_integral, type: type, samples: samples)
    }
    func heatBlockIntegral(type: Int32, labelIndices: Set<Int>) throws -> femm_complex_t {
        try callBlockIntegral(femm_result_heat_block_integral, type: type, labelIndices: labelIndices)
    }
    func currLineIntegral (type: Int32, samples: Int32 = 400) throws -> [femm_complex_t] {
        try callLineIntegral(femm_result_curr_line_integral, type: type, samples: samples)
    }
    func currBlockIntegral(type: Int32, labelIndices: Set<Int>) throws -> femm_complex_t {
        try callBlockIntegral(femm_result_curr_block_integral, type: type, labelIndices: labelIndices)
    }

    // MARK: - Bounding box (world units)
    var bounds: (min: (x: Double, y: Double), max: (x: Double, y: Double))? {
        let xs = snapshot.nodes.map(\.x) + snapshot.labels.map(\.x)
        let ys = snapshot.nodes.map(\.y) + snapshot.labels.map(\.y)
        guard let mnx = xs.min(), let mxx = xs.max(),
              let mny = ys.min(), let mxy = ys.max() else { return nil }
        return ((mnx, mny), (mxx, mxy))
    }
}
