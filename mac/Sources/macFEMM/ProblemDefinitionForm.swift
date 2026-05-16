// ProblemDefinitionForm.swift — Edit length units, problem type, depth,
// mesh precision/min-angle/smart-mesh, frequency (mag only), AC solver, comment.

import SwiftUI
import FemmCore

struct ProblemDefinitionForm: View {
    @ObservedObject var doc: FemmDocument
    let onDismiss: () -> Void

    @State private var lengthUnits: femm_length_units_t = FEMM_UNITS_MILLIMETERS
    @State private var problemType: femm_problem_type_t = FEMM_PROBLEM_PLANAR
    @State private var depth: Double = 1
    @State private var precision: Double = 1e-8
    @State private var minAngle: Double = 30
    @State private var smartMesh: Bool = true
    @State private var frequency: Double = 0
    @State private var acSolver: Int32 = 0
    @State private var comment: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Problem Definition").font(.headline)
                Spacer()
                Button("Cancel") { onDismiss() }
                Button("Save") { save() }.keyboardShortcut(.return).buttonStyle(.borderedProminent)
            }
            Form {
                Picker("Length Units", selection: $lengthUnits) {
                    Text("Inches").tag(FEMM_UNITS_INCHES)
                    Text("Millimeters").tag(FEMM_UNITS_MILLIMETERS)
                    Text("Centimeters").tag(FEMM_UNITS_CENTIMETERS)
                    Text("Meters").tag(FEMM_UNITS_METERS)
                    Text("Mils").tag(FEMM_UNITS_MILS)
                    Text("Micrometers").tag(FEMM_UNITS_MICROMETERS)
                }
                Picker("Problem Type", selection: $problemType) {
                    Text("Planar").tag(FEMM_PROBLEM_PLANAR)
                    Text("Axisymmetric").tag(FEMM_PROBLEM_AXISYMMETRIC)
                }
                LabeledContent("Depth") {
                    TextField("", value: $depth, format: .number).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                LabeledContent("Solver Precision") {
                    TextField("", value: $precision, format: .number).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                LabeledContent("Min. Angle (deg)") {
                    TextField("", value: $minAngle, format: .number).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                Toggle("Smart Mesh", isOn: $smartMesh)
                if doc.snapshot.physics == .magnetics {
                    LabeledContent("Frequency (Hz)") {
                        TextField("", value: $frequency, format: .number).textFieldStyle(.roundedBorder).frame(width: 140)
                    }
                    Picker("AC Solver", selection: $acSolver) {
                        Text("Succ. Approx.").tag(Int32(0))
                        Text("Newton").tag(Int32(1))
                    }
                }
                LabeledContent("Comment") {
                    TextEditor(text: $comment).frame(minHeight: 60).border(Color.secondary.opacity(0.3))
                }
            }.formStyle(.grouped)
        }
        .frame(minWidth: 460)
        .padding(16)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        let s = doc.snapshot
        lengthUnits = s.lengthUnits
        problemType = s.problemType
        depth = s.depth
        precision = s.precision
        minAngle = s.minAngle
        smartMesh = s.smartMesh
        frequency = s.frequency
        acSolver = s.acSolver
        comment = s.comment
        loaded = true
    }

    private func save() {
        doc.setProblemDef(lengthUnits: lengthUnits, problemType: problemType,
                          depth: depth, precision: precision, minAngle: minAngle,
                          smartMesh: smartMesh, frequency: frequency, acSolver: acSolver,
                          comment: comment)
        onDismiss()
    }
}
