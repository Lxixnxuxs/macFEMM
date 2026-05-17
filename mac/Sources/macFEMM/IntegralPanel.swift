// IntegralPanel.swift — Line + block integral UI for the Result view.
//
// Sits inside PostProcessorPanel when the post-tool is .contour. Lets the
// user pick an integral type, selects which block labels participate (for
// block integrals), and computes a value against the current contour /
// label selection via the C ABI wrappers on FemmDocument.

import SwiftUI
import AppKit
import FemmCore

enum IntegralKind: String, CaseIterable, Identifiable {
    case line  = "Line"
    case block = "Block"
    var id: String { rawValue }
}

struct IntegralType: Identifiable, Hashable {
    let id: Int32
    let name: String
    let unit0: String
    let unit1: String?
}

/* --- Per-physics type tables -------------------------------------------- */

let magLineTypes: [IntegralType] = [
    .init(id: 0, name: "B·n (flux)",        unit0: "Wb",   unit1: "T"),
    .init(id: 1, name: "H·t (MMF)",         unit0: "A",    unit1: "A/m"),
    .init(id: 2, name: "Length",            unit0: "m",    unit1: "m² or m³"),
    .init(id: 3, name: "Stress force",      unit0: "N",    unit1: "N"),
    .init(id: 4, name: "Stress torque",     unit0: "N·m",  unit1: nil),
    .init(id: 5, name: "(B·n)²",            unit0: "T²·m", unit1: "T²"),
]
let magBlockTypes: [IntegralType] = [
    .init(id: 0,  name: "A·J",              unit0: "Wb·A", unit1: nil),
    .init(id: 1,  name: "∫A",               unit0: "Wb·m", unit1: nil),
    .init(id: 2,  name: "Stored energy",    unit0: "J",    unit1: nil),
    .init(id: 4,  name: "Resistive loss",   unit0: "W",    unit1: nil),
    .init(id: 5,  name: "Area",             unit0: "m²",   unit1: nil),
    .init(id: 7,  name: "Total current",    unit0: "A",    unit1: nil),
    .init(id: 8,  name: "∫Bx",              unit0: "T·m³", unit1: nil),
    .init(id: 9,  name: "∫By",              unit0: "T·m³", unit1: nil),
    .init(id: 10, name: "Volume",           unit0: "m³",   unit1: nil),
    .init(id: 11, name: "Lorentz force",    unit0: "N",    unit1: "N"),
    .init(id: 15, name: "Lorentz torque",   unit0: "N·m",  unit1: nil),
]

let esLineTypes: [IntegralType] = [
    .init(id: 0, name: "E·t (ΔV)",          unit0: "V",    unit1: "V/m"),
    .init(id: 1, name: "D·n (charge)",      unit0: "C",    unit1: "C/m²"),
    .init(id: 2, name: "Length",            unit0: "m",    unit1: "m² or m³"),
]
let esBlockTypes: [IntegralType] = [
    .init(id: 0, name: "Stored energy",     unit0: "J",    unit1: nil),
    .init(id: 1, name: "Area",              unit0: "m²",   unit1: nil),
    .init(id: 2, name: "Volume",            unit0: "m³",   unit1: nil),
    .init(id: 3, name: "∫V",                unit0: "V·m³", unit1: nil),
    .init(id: 4, name: "∫|E|²",             unit0: "V²/m", unit1: nil),
]

let heatLineTypes: [IntegralType] = [
    .init(id: 0, name: "ΔT",                unit0: "K",    unit1: nil),
    .init(id: 1, name: "F·n (heat flux)",   unit0: "W",    unit1: nil),
    .init(id: 2, name: "Length",            unit0: "m",    unit1: "m² or m³"),
    .init(id: 3, name: "Avg T",             unit0: "K",    unit1: nil),
]
let heatBlockTypes: [IntegralType] = [
    .init(id: 0, name: "∫T",                unit0: "K·m³", unit1: nil),
    .init(id: 1, name: "Area",              unit0: "m²",   unit1: nil),
    .init(id: 2, name: "Volume",            unit0: "m³",   unit1: nil),
]

let currLineTypes: [IntegralType] = [
    .init(id: 0, name: "ΔV",                unit0: "V",    unit1: "V/m"),
    .init(id: 1, name: "J·n (current)",     unit0: "A",    unit1: nil),
    .init(id: 2, name: "Length",            unit0: "m",    unit1: "m² or m³"),
]
let currBlockTypes: [IntegralType] = [
    .init(id: 0, name: "Real power",        unit0: "W",    unit1: nil),
    .init(id: 1, name: "Area",              unit0: "m²",   unit1: nil),
    .init(id: 2, name: "Volume",            unit0: "m³",   unit1: nil),
    .init(id: 3, name: "∫V",                unit0: "V·m³", unit1: nil),
]

struct IntegralResult: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let unit: String
}

struct IntegralPanel: View {
    @ObservedObject var doc: FemmDocument
    @State private var kind: IntegralKind = .line
    @State private var lineType: Int32 = 0
    @State private var blockType: Int32 = 0
    @State private var results: [IntegralResult] = []
    @State private var errorMessage: String?

    private var lineTypes: [IntegralType] {
        switch doc.snapshot.physics {
        case .magnetics:        return magLineTypes
        case .electrostatics:   return esLineTypes
        case .heat:             return heatLineTypes
        case .current:          return currLineTypes
        }
    }
    private var blockTypes: [IntegralType] {
        switch doc.snapshot.physics {
        case .magnetics:        return magBlockTypes
        case .electrostatics:   return esBlockTypes
        case .heat:             return heatBlockTypes
        case .current:          return currBlockTypes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Integrals", systemImage: "sum").font(.subheadline).bold()
            Picker("Kind", selection: $kind) {
                ForEach(IntegralKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            switch kind {
            case .line:  lineControls
            case .block: blockControls
            }

            if let msg = errorMessage {
                Text(msg).foregroundStyle(.red)
            }

            if !results.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { r in
                        HStack {
                            Text(r.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(r.value).font(.system(.caption, design: .monospaced))
                            Text(r.unit).foregroundStyle(.secondary).font(.caption2)
                        }
                    }
                    HStack {
                        Button("Copy CSV") { copyCSV() }
                        Button("Clear") { results.removeAll() }
                    }
                    .font(.caption).padding(.top, 2)
                }
            }
        }
        .font(.caption)
        .onChange(of: doc.snapshot.physics) { _, _ in
            // Reset selection when switching physics (tag may no longer exist).
            lineType = lineTypes.first?.id ?? 0
            blockType = blockTypes.first?.id ?? 0
        }
        .onAppear {
            lineType = lineTypes.first?.id ?? 0
            blockType = blockTypes.first?.id ?? 0
        }
    }

    private var lineControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Type", selection: $lineType) {
                ForEach(lineTypes) { t in Text(t.name).tag(t.id) }
            }
            LabeledContent("Contour points", value: "\(doc.contour.count)")
            Button("Compute") { computeLine() }
                .disabled(doc.contour.count < 2)
        }
    }

    private var blockControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Type", selection: $blockType) {
                ForEach(blockTypes) { t in Text(t.name).tag(t.id) }
            }
            LabeledContent("Selected labels", value: "\(doc.selectedLabels.count)")
            Text("Tip: switch to Geometry and click block labels to restrict the integral.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Compute") { computeBlock() }
        }
    }

    private func computeLine() {
        errorMessage = nil
        guard let t = lineTypes.first(where: { $0.id == lineType }) else { return }
        do {
            let zs: [femm_complex_t]
            switch doc.snapshot.physics {
            case .magnetics:      zs = try doc.magLineIntegral(type: lineType)
            case .electrostatics: zs = try doc.esLineIntegral(type: lineType)
            case .heat:           zs = try doc.heatLineIntegral(type: lineType)
            case .current:        zs = try doc.currLineIntegral(type: lineType)
            }
            for (i, z) in zs.enumerated() {
                let unit = (i == 0) ? t.unit0 : (t.unit1 ?? "")
                let label = "\(t.name) [\(i)]"
                results.insert(
                    .init(label: label, value: fmtComplex(z), unit: unit),
                    at: 0
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func computeBlock() {
        errorMessage = nil
        guard let t = blockTypes.first(where: { $0.id == blockType }) else { return }
        do {
            let z: femm_complex_t
            switch doc.snapshot.physics {
            case .magnetics:
                z = try doc.magBlockIntegral(type: blockType, labelIndices: doc.selectedLabels)
            case .electrostatics:
                z = try doc.esBlockIntegral(type: blockType, labelIndices: doc.selectedLabels)
            case .heat:
                z = try doc.heatBlockIntegral(type: blockType, labelIndices: doc.selectedLabels)
            case .current:
                z = try doc.currBlockIntegral(type: blockType, labelIndices: doc.selectedLabels)
            }
            let scope = doc.selectedLabels.isEmpty ? "all" : "sel"
            results.insert(
                .init(label: "\(t.name) (\(scope))",
                      value: fmtComplex(z),
                      unit: t.unit0),
                at: 0
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyCSV() {
        var buf = "label,value,unit\n"
        for r in results.reversed() { // oldest first for file-like ordering
            let esc = r.label.replacingOccurrences(of: "\"", with: "\"\"")
            buf += "\"\(esc)\",\(r.value),\(r.unit)\n"
        }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(buf, forType: .string)
        #endif
    }

    private func fmtComplex(_ z: femm_complex_t) -> String {
        if z.im == 0 { return String(format: "%.6g", z.re) }
        return String(format: "%.6g%+.6gj", z.re, z.im)
    }
}
