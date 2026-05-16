// PropertyEditors.swift — SwiftUI editor sheets for materials, boundaries,
// point properties, and circuits/conductors across all four physics.
//
// Each sheet fetches the existing C struct via the doc bridge, presents a
// Form with editable bindings, and calls add_* or update_* on save.

import SwiftUI
import Charts
import FemmCore

// MARK: - Shared helpers

fileprivate struct EditorHeader: View {
    let title: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let canSave: Bool
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Save", action: onSave).keyboardShortcut(.defaultAction).disabled(!canSave)
                .buttonStyle(.borderedProminent)
        }
    }
}

fileprivate struct DoubleField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        LabeledContent(title) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
                .multilineTextAlignment(.trailing)
        }
    }
}

fileprivate struct ComplexField: View {
    let title: String
    @Binding var re: Double
    @Binding var im: Double
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("re", value: $re, format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                Text("+")
                TextField("im", value: $im, format: .number)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
                Text("j")
            }
        }
    }
}

// Turn a Swift String into an owned C buffer valid for the enclosing scope.
fileprivate func withCStr<R>(_ s: String, _ f: (UnsafePointer<CChar>) -> R) -> R {
    s.withCString(f)
}

// MARK: - Magnetics

struct MagMaterialEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name: String = ""
    @State private var muX: Double = 1
    @State private var muY: Double = 1
    @State private var hC: Double = 0
    @State private var thetaM: Double = 0
    @State private var jRe: Double = 0
    @State private var jIm: Double = 0
    @State private var sigma: Double = 0
    @State private var dLam: Double = 0
    @State private var lamType: Int32 = 0
    @State private var lamFill: Double = 1
    @State private var nStrands: Int32 = 0
    @State private var wireD: Double = 0
    @State private var bh: [(B: Double, H: Double)] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Material" : "Edit Material",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            ScrollView {
                Form {
                    Section("Identity") {
                        LabeledContent("Name") {
                            TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                        }
                    }
                    Section("Linear Permeability") {
                        DoubleField(title: "μx (relative)", value: $muX)
                        DoubleField(title: "μy (relative)", value: $muY)
                    }
                    Section("Permanent Magnet") {
                        DoubleField(title: "H_c  (A/m)", value: $hC)
                        DoubleField(title: "θ_m  (deg)", value: $thetaM)
                    }
                    Section("Source Current Density (MA/m²)") {
                        ComplexField(title: "J_src", re: $jRe, im: $jIm)
                    }
                    Section("Losses & Lamination") {
                        DoubleField(title: "σ (MS/m)", value: $sigma)
                        DoubleField(title: "d_lam (mm)", value: $dLam)
                        LabeledContent("Lamination type") {
                            Picker("", selection: $lamType) {
                                Text("not laminated / solid").tag(Int32(0))
                                Text("laminated in-plane").tag(Int32(1))
                                Text("magnet wire").tag(Int32(3))
                                Text("plain stranded wire").tag(Int32(4))
                                Text("Litz wire").tag(Int32(5))
                                Text("square wire").tag(Int32(6))
                            }.labelsHidden()
                        }
                        DoubleField(title: "lamination fill factor", value: $lamFill)
                        LabeledContent("# Strands") {
                            TextField("", value: $nStrands, format: .number)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 100)
                                .multilineTextAlignment(.trailing)
                        }
                        DoubleField(title: "wire diameter", value: $wireD)
                    }
                    Section("Nonlinear B-H Curve (\(bh.count) points)") {
                        if !bh.isEmpty {
                            Chart {
                                ForEach(Array(bh.enumerated()), id: \.offset) { _, p in
                                    LineMark(x: .value("H", p.H), y: .value("B", p.B))
                                    PointMark(x: .value("H", p.H), y: .value("B", p.B))
                                }
                            }
                            .frame(height: 160)
                            .padding(.vertical, 4)
                        }
                        HStack {
                            Button("Add Point") { bh.append((B: 0, H: 0)) }
                            Button("Clear") { bh.removeAll() }.disabled(bh.isEmpty)
                            if let last = bh.indices.last {
                                Button("Remove Last") { bh.remove(at: last) }
                            }
                        }
                        if !bh.isEmpty {
                            ForEach(bh.indices, id: \.self) { i in
                                HStack {
                                    Text("#\(i)").font(.caption).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                    TextField("B", value: Binding(
                                        get: { bh[i].B },
                                        set: { bh[i].B = $0 }), format: .number)
                                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                                    TextField("H", value: Binding(
                                        get: { bh[i].H },
                                        set: { bh[i].H = $0 }), format: .number)
                                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minHeight: 500, idealHeight: 640)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_mag_material_t()
        guard femm_mag_get_material(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name)
        muX = s.mu_x; muY = s.mu_y; hC = s.H_c; thetaM = s.theta_m
        jRe = s.J_src.re; jIm = s.J_src.im
        sigma = s.c_duct; dLam = s.lam_d; lamType = s.lam_type
        lamFill = s.lam_fill; nStrands = s.n_strands; wireD = s.wire_d
        bh = doc.bhPoints(materialIdx: idx)
        loaded = true
    }

    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_mag_material_t(
                name: cName, mu_x: muX, mu_y: muY, H_c: hC, theta_m: thetaM,
                J_src: femm_complex_t(re: jRe, im: jIm),
                c_duct: sigma, lam_d: dLam,
                theta_hn: 0, theta_hx: 0, theta_hy: 0,
                lam_type: lamType, lam_fill: lamFill,
                n_strands: nStrands, wire_d: wireD)
            if let idx = editingIdx {
                _ = femm_mag_update_material(h, idx, &s)
                doc.setBHPoints(materialIdx: idx, materialName: name, points: bh)
            } else {
                _ = femm_mag_add_material(h, &s)
                let newIdx = Int32(femm_mag_num_materials(h)) - 1
                if newIdx >= 0 { doc.setBHPoints(materialIdx: newIdx, materialName: name, points: bh) }
            }
        }
        doc.markDirtyAndReload()
        onDismiss()
    }
}

struct MagBoundaryEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var fmt: Int32 = 0
    @State private var A0: Double = 0
    @State private var A1: Double = 0
    @State private var A2: Double = 0
    @State private var phi: Double = 0
    @State private var c0re: Double = 0
    @State private var c0im: Double = 0
    @State private var c1re: Double = 0
    @State private var c1im: Double = 0
    @State private var mu: Double = 0
    @State private var sig: Double = 0
    @State private var innerAngle: Double = 0
    @State private var outerAngle: Double = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Boundary" : "Edit Boundary",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            ScrollView {
                Form {
                    LabeledContent("Name") {
                        TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    LabeledContent("BC type") {
                        Picker("", selection: $fmt) {
                            Text("Prescribed A").tag(Int32(0))
                            Text("Small skin depth").tag(Int32(1))
                            Text("Mixed").tag(Int32(2))
                            Text("Strategic dual image").tag(Int32(3))
                            Text("Periodic").tag(Int32(4))
                            Text("Antiperiodic").tag(Int32(5))
                        }.labelsHidden()
                    }
                    Section("Prescribed A") {
                        DoubleField(title: "A₀", value: $A0)
                        DoubleField(title: "A₁", value: $A1)
                        DoubleField(title: "A₂", value: $A2)
                        DoubleField(title: "φ (deg)", value: $phi)
                    }
                    Section("Mixed BC coefficients") {
                        ComplexField(title: "c₀", re: $c0re, im: $c0im)
                        ComplexField(title: "c₁", re: $c1re, im: $c1im)
                    }
                    Section("Small Skin Depth") {
                        DoubleField(title: "μ_r", value: $mu)
                        DoubleField(title: "σ (MS/m)", value: $sig)
                    }
                    Section("Strategic Dual Image") {
                        DoubleField(title: "inner angle (deg)", value: $innerAngle)
                        DoubleField(title: "outer angle (deg)", value: $outerAngle)
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minHeight: 460)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_mag_boundary_t()
        guard femm_mag_get_boundary(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); fmt = s.bdry_format
        A0 = s.A0; A1 = s.A1; A2 = s.A2; phi = s.phi
        c0re = s.c0.re; c0im = s.c0.im; c1re = s.c1.re; c1im = s.c1.im
        mu = s.mu; sig = s.sig
        innerAngle = s.inner_angle; outerAngle = s.outer_angle
        loaded = true
    }

    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_mag_boundary_t(
                name: cName, bdry_format: fmt,
                A0: A0, A1: A1, A2: A2, phi: phi,
                c0: femm_complex_t(re: c0re, im: c0im),
                c1: femm_complex_t(re: c1re, im: c1im),
                mu: mu, sig: sig,
                inner_angle: innerAngle, outer_angle: outerAngle)
            if let idx = editingIdx {
                _ = femm_mag_update_boundary(h, idx, &s)
            } else {
                _ = femm_mag_add_boundary(h, &s)
            }
        }
        doc.markDirtyAndReload()
        onDismiss()
    }
}

struct MagPointEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var jRe: Double = 0
    @State private var jIm: Double = 0
    @State private var aRe: Double = 0
    @State private var aIm: Double = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Point Property" : "Edit Point Property",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                ComplexField(title: "I (A)", re: $jRe, im: $jIm)
                ComplexField(title: "A (Wb/m)", re: $aRe, im: $aIm)
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_mag_pointprop_t()
        guard femm_mag_get_pointprop(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name)
        jRe = s.Jp.re; jIm = s.Jp.im; aRe = s.Ap.re; aIm = s.Ap.im
        loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_mag_pointprop_t(
                name: cName,
                Jp: femm_complex_t(re: jRe, im: jIm),
                Ap: femm_complex_t(re: aRe, im: aIm))
            if let idx = editingIdx { _ = femm_mag_update_pointprop(h, idx, &s) }
            else { _ = femm_mag_add_pointprop(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct MagCircuitEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var iRe: Double = 0
    @State private var iIm: Double = 0
    @State private var circType: Int32 = 1
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Circuit" : "Edit Circuit",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                ComplexField(title: "Total current (A)", re: $iRe, im: $iIm)
                LabeledContent("Circuit type") {
                    Picker("", selection: $circType) {
                        Text("Parallel").tag(Int32(0))
                        Text("Series").tag(Int32(1))
                    }.labelsHidden()
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_mag_circuit_t()
        guard femm_mag_get_circuit(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name)
        iRe = s.amps.re; iIm = s.amps.im; circType = s.circ_type
        loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_mag_circuit_t(
                name: cName,
                amps: femm_complex_t(re: iRe, im: iIm),
                circ_type: circType)
            if let idx = editingIdx { _ = femm_mag_update_circuit(h, idx, &s) }
            else { _ = femm_mag_add_circuit(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

// MARK: - Electrostatics

struct ESMaterialEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var ex: Double = 1
    @State private var ey: Double = 1
    @State private var qv: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Material" : "Edit Material",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                DoubleField(title: "εx (relative)", value: $ex)
                DoubleField(title: "εy (relative)", value: $ey)
                DoubleField(title: "qv (C/m³)", value: $qv)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_es_material_t()
        guard femm_es_get_material(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); ex = s.ex; ey = s.ey; qv = s.qv
        loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_es_material_t(name: cName, ex: ex, ey: ey, qv: qv)
            if let idx = editingIdx { _ = femm_es_update_material(h, idx, &s) }
            else { _ = femm_es_add_material(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct ESBoundaryEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var fmt: Int32 = 0
    @State private var V: Double = 0
    @State private var qs: Double = 0
    @State private var c0: Double = 0
    @State private var c1: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Boundary" : "Edit Boundary",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("BC type") {
                    Picker("", selection: $fmt) {
                        Text("Fixed V").tag(Int32(0))
                        Text("Mixed").tag(Int32(1))
                        Text("Surface charge").tag(Int32(2))
                        Text("Periodic").tag(Int32(3))
                        Text("Antiperiodic").tag(Int32(4))
                    }.labelsHidden()
                }
                DoubleField(title: "V (V)", value: $V)
                DoubleField(title: "qs (C/m²)", value: $qs)
                DoubleField(title: "c0", value: $c0)
                DoubleField(title: "c1", value: $c1)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_es_boundary_t()
        guard femm_es_get_boundary(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); fmt = s.bdry_format
        V = s.V; qs = s.qs; c0 = s.c0; c1 = s.c1
        loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_es_boundary_t(name: cName, bdry_format: fmt, V: V, qs: qs, c0: c0, c1: c1)
            if let idx = editingIdx { _ = femm_es_update_boundary(h, idx, &s) }
            else { _ = femm_es_add_boundary(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct ESPointEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var V: Double = 0
    @State private var qp: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Point Property" : "Edit Point Property",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                DoubleField(title: "V (V)", value: $V)
                DoubleField(title: "qp (C/m)", value: $qp)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_es_pointprop_t()
        guard femm_es_get_pointprop(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); V = s.V; qp = s.qp; loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_es_pointprop_t(name: cName, V: V, qp: qp)
            if let idx = editingIdx { _ = femm_es_update_pointprop(h, idx, &s) }
            else { _ = femm_es_add_pointprop(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct ESConductorEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var V: Double = 0
    @State private var q: Double = 0
    @State private var circType: Int32 = 1
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Conductor" : "Edit Conductor",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("Type") {
                    Picker("", selection: $circType) {
                        Text("Prescribed charge").tag(Int32(0))
                        Text("Prescribed voltage").tag(Int32(1))
                    }.labelsHidden()
                }
                DoubleField(title: "V (V)", value: $V)
                DoubleField(title: "q (C)", value: $q)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_es_conductor_t()
        guard femm_es_get_conductor(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); V = s.V; q = s.q; circType = s.circ_type; loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_es_conductor_t(name: cName, V: V, q: q, circ_type: circType)
            if let idx = editingIdx { _ = femm_es_update_conductor(h, idx, &s) }
            else { _ = femm_es_add_conductor(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

// MARK: - Heat

struct HeatMaterialEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var Kx: Double = 1
    @State private var Ky: Double = 1
    @State private var Kt: Double = 0
    @State private var qv: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Material" : "Edit Material",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                DoubleField(title: "Kx (W/(m·K))", value: $Kx)
                DoubleField(title: "Ky (W/(m·K))", value: $Ky)
                DoubleField(title: "Volumetric heat capacity", value: $Kt)
                DoubleField(title: "qv (W/m³)", value: $qv)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let h = doc.raw else { loaded = true; return }
        var s = femm_heat_material_t()
        guard femm_heat_get_material(h, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); Kx = s.Kx; Ky = s.Ky; Kt = s.Kt; qv = s.qv; loaded = true
    }
    private func save() {
        guard let h = doc.raw else { return }
        name.withCString { cName in
            var s = femm_heat_material_t(name: cName, Kx: Kx, Ky: Ky, Kt: Kt, qv: qv)
            if let idx = editingIdx { _ = femm_heat_update_material(h, idx, &s) }
            else { _ = femm_heat_add_material(h, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct HeatBoundaryEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var fmt: Int32 = 0
    @State private var Tset: Double = 0
    @State private var qs: Double = 0
    @State private var beta: Double = 0
    @State private var h0: Double = 0
    @State private var Tinf: Double = 0
    @State private var TinfRad: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Boundary" : "Edit Boundary",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("BC type") {
                    Picker("", selection: $fmt) {
                        Text("Fixed T").tag(Int32(0))
                        Text("Heat flux").tag(Int32(1))
                        Text("Convection").tag(Int32(2))
                        Text("Radiation").tag(Int32(3))
                        Text("Periodic").tag(Int32(4))
                        Text("Antiperiodic").tag(Int32(5))
                    }.labelsHidden()
                }
                DoubleField(title: "T (K)", value: $Tset)
                DoubleField(title: "qs (W/m²)", value: $qs)
                DoubleField(title: "β (emissivity)", value: $beta)
                DoubleField(title: "h (W/(m²·K))", value: $h0)
                DoubleField(title: "T∞ convection (K)", value: $Tinf)
                DoubleField(title: "T∞ radiation (K)", value: $TinfRad)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_heat_boundary_t()
        guard femm_heat_get_boundary(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); fmt = s.bdry_format
        Tset = s.Tset; qs = s.qs; beta = s.beta; h0 = s.h; Tinf = s.Tinf; TinfRad = s.TinfRad
        loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_heat_boundary_t(name: cName, bdry_format: fmt,
                Tset: Tset, qs: qs, beta: beta, h: h0, Tinf: Tinf, TinfRad: TinfRad)
            if let idx = editingIdx { _ = femm_heat_update_boundary(hh, idx, &s) }
            else { _ = femm_heat_add_boundary(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct HeatPointEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var T: Double = 0
    @State private var qp: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Point Property" : "Edit Point Property",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                DoubleField(title: "T (K)", value: $T)
                DoubleField(title: "qp (W/m)", value: $qp)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_heat_pointprop_t()
        guard femm_heat_get_pointprop(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); T = s.T; qp = s.qp; loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_heat_pointprop_t(name: cName, T: T, qp: qp)
            if let idx = editingIdx { _ = femm_heat_update_pointprop(hh, idx, &s) }
            else { _ = femm_heat_add_pointprop(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct HeatConductorEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var T: Double = 0
    @State private var q: Double = 0
    @State private var circType: Int32 = 1
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Conductor" : "Edit Conductor",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("Type") {
                    Picker("", selection: $circType) {
                        Text("Prescribed flux").tag(Int32(0))
                        Text("Prescribed T").tag(Int32(1))
                    }.labelsHidden()
                }
                DoubleField(title: "T (K)", value: $T)
                DoubleField(title: "q (W)", value: $q)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_heat_conductor_t()
        guard femm_heat_get_conductor(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); T = s.T; q = s.q; circType = s.circ_type; loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_heat_conductor_t(name: cName, T: T, q: q, circ_type: circType)
            if let idx = editingIdx { _ = femm_heat_update_conductor(hh, idx, &s) }
            else { _ = femm_heat_add_conductor(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

// MARK: - Current flow

struct CurrMaterialEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var ox: Double = 1
    @State private var oy: Double = 1
    @State private var ex: Double = 1
    @State private var ey: Double = 1
    @State private var ltx: Double = 0
    @State private var lty: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Material" : "Edit Material",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                DoubleField(title: "σx (MS/m)", value: $ox)
                DoubleField(title: "σy (MS/m)", value: $oy)
                DoubleField(title: "εx (relative)", value: $ex)
                DoubleField(title: "εy (relative)", value: $ey)
                DoubleField(title: "tan δx", value: $ltx)
                DoubleField(title: "tan δy", value: $lty)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_curr_material_t()
        guard femm_curr_get_material(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); ox = s.ox; oy = s.oy; ex = s.ex; ey = s.ey
        ltx = s.ltx; lty = s.lty
        loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_curr_material_t(name: cName, ox: ox, oy: oy, ex: ex, ey: ey, ltx: ltx, lty: lty)
            if let idx = editingIdx { _ = femm_curr_update_material(hh, idx, &s) }
            else { _ = femm_curr_add_material(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct CurrBoundaryEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var fmt: Int32 = 0
    @State private var vsR: Double = 0
    @State private var vsI: Double = 0
    @State private var qsR: Double = 0
    @State private var qsI: Double = 0
    @State private var c0R: Double = 0
    @State private var c0I: Double = 0
    @State private var c1R: Double = 0
    @State private var c1I: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Boundary" : "Edit Boundary",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            ScrollView {
                Form {
                    LabeledContent("Name") {
                        TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    }
                    LabeledContent("BC type") {
                        Picker("", selection: $fmt) {
                            Text("Fixed V").tag(Int32(0))
                            Text("Mixed").tag(Int32(1))
                            Text("Surface current").tag(Int32(2))
                            Text("Periodic").tag(Int32(3))
                            Text("Antiperiodic").tag(Int32(4))
                        }.labelsHidden()
                    }
                    ComplexField(title: "Vs", re: $vsR, im: $vsI)
                    ComplexField(title: "qs", re: $qsR, im: $qsI)
                    ComplexField(title: "c0", re: $c0R, im: $c0I)
                    ComplexField(title: "c1", re: $c1R, im: $c1I)
                }.formStyle(.grouped)
            }
        }
        .frame(minHeight: 460)
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_curr_boundary_t()
        guard femm_curr_get_boundary(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); fmt = s.bdry_format
        vsR = s.Vs.re; vsI = s.Vs.im; qsR = s.qs.re; qsI = s.qs.im
        c0R = s.c0.re; c0I = s.c0.im; c1R = s.c1.re; c1I = s.c1.im
        loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_curr_boundary_t(name: cName, bdry_format: fmt,
                Vs: femm_complex_t(re: vsR, im: vsI),
                qs: femm_complex_t(re: qsR, im: qsI),
                c0: femm_complex_t(re: c0R, im: c0I),
                c1: femm_complex_t(re: c1R, im: c1I))
            if let idx = editingIdx { _ = femm_curr_update_boundary(hh, idx, &s) }
            else { _ = femm_curr_add_boundary(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct CurrPointEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var vR: Double = 0
    @State private var vI: Double = 0
    @State private var qR: Double = 0
    @State private var qI: Double = 0
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Point Property" : "Edit Point Property",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                ComplexField(title: "V", re: $vR, im: $vI)
                ComplexField(title: "qp", re: $qR, im: $qI)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_curr_pointprop_t()
        guard femm_curr_get_pointprop(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name); vR = s.Vp.re; vI = s.Vp.im; qR = s.qp.re; qI = s.qp.im
        loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_curr_pointprop_t(name: cName,
                Vp: femm_complex_t(re: vR, im: vI),
                qp: femm_complex_t(re: qR, im: qI))
            if let idx = editingIdx { _ = femm_curr_update_pointprop(hh, idx, &s) }
            else { _ = femm_curr_add_pointprop(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}

struct CurrConductorEditor: View {
    @ObservedObject var doc: FemmDocument
    let editingIdx: Int32?
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var vR: Double = 0
    @State private var vI: Double = 0
    @State private var qR: Double = 0
    @State private var qI: Double = 0
    @State private var circType: Int32 = 1
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorHeader(title: editingIdx == nil ? "New Conductor" : "Edit Conductor",
                         onCancel: onDismiss, onSave: save, canSave: !name.isEmpty)
            Form {
                LabeledContent("Name") {
                    TextField("", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                }
                LabeledContent("Type") {
                    Picker("", selection: $circType) {
                        Text("Prescribed current").tag(Int32(0))
                        Text("Prescribed voltage").tag(Int32(1))
                    }.labelsHidden()
                }
                ComplexField(title: "V", re: $vR, im: $vI)
                ComplexField(title: "q", re: $qR, im: $qI)
            }.formStyle(.grouped)
        }
        .onAppear(perform: load)
    }
    private func load() {
        guard !loaded, let idx = editingIdx, let hh = doc.raw else { loaded = true; return }
        var s = femm_curr_conductor_t()
        guard femm_curr_get_conductor(hh, idx, &s) == FEMM_OK else { loaded = true; return }
        name = String(cString: s.name)
        vR = s.Vc.re; vI = s.Vc.im; qR = s.qc.re; qI = s.qc.im
        circType = s.circ_type
        loaded = true
    }
    private func save() {
        guard let hh = doc.raw else { return }
        name.withCString { cName in
            var s = femm_curr_conductor_t(name: cName,
                Vc: femm_complex_t(re: vR, im: vI),
                qc: femm_complex_t(re: qR, im: qI),
                circ_type: circType)
            if let idx = editingIdx { _ = femm_curr_update_conductor(hh, idx, &s) }
            else { _ = femm_curr_add_conductor(hh, &s) }
        }
        doc.markDirtyAndReload(); onDismiss()
    }
}
