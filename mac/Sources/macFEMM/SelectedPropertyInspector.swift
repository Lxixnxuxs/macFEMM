// SelectedPropertyInspector.swift — Assign materials/boundaries/circuits/points
// and per-primitive mesh params to the current selection. Writes on change.

import SwiftUI
import FemmCore

struct SelectedPropertyInspector: View {
    @ObservedObject var doc: FemmDocument

    @State private var materialChoice: String = "<None>"
    @State private var boundaryChoice: String = "<None>"
    @State private var pointChoice: String = "<None>"
    @State private var circuitChoice: String = "<None>"
    @State private var turns: Int32 = 1
    @State private var maxArea: Double = 0
    @State private var magDir: Double = 0
    @State private var maxSide: Double = -1

    // When true, state mutations come from syncFromSelection and must not be
    // echoed back to the document.
    @State private var suppressWrite: Bool = false

    private func syncFromSelection() {
        suppressWrite = true
        defer { DispatchQueue.main.async { self.suppressWrite = false } }

        let s = doc.snapshot
        if let i = doc.selectedLabels.first, i < s.labels.count {
            let l = s.labels[i]
            materialChoice = name(from: s.materials, idx1: l.blockIdx) ?? "<None>"
            circuitChoice  = name(from: s.circuits,  idx1: l.circuitIdx) ?? "<None>"
            turns   = l.turns
            magDir  = l.magDir
            maxArea = l.maxArea
        }
        if let i = doc.selectedSegments.first, i < s.segments.count {
            let seg = s.segments[i]
            boundaryChoice = name(from: s.boundaries, idx1: seg.bdryIdx) ?? "<None>"
        }
        if let i = doc.selectedNodes.first, i < s.nodes.count {
            let n = s.nodes[i]
            pointChoice = name(from: s.pointProps, idx1: n.bdryIdx) ?? "<None>"
        }
    }

    private func name(from entries: [DocSnapshot.PropEntry], idx1: Int32) -> String? {
        guard idx1 > 0 else { return nil }
        return entries.first(where: { $0.idx == idx1 - 1 })?.name
    }

    var body: some View {
        let hasNodes = !doc.selectedNodes.isEmpty
        let hasSegs  = !doc.selectedSegments.isEmpty
        let hasLbls  = !doc.selectedLabels.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if hasNodes {
                Text("Selected Nodes (\(doc.selectedNodes.count))").font(.subheadline).bold()
                Picker("Point Prop", selection: $pointChoice) {
                    Text("<None>").tag("<None>")
                    ForEach(doc.snapshot.pointProps) { p in Text(p.name).tag(p.name) }
                }
                .onChange(of: pointChoice) { _, v in
                    if !suppressWrite { doc.assignNodePointProp(v == "<None>" ? nil : v) }
                }
                Divider()
            }
            if hasSegs {
                Text("Selected Segments (\(doc.selectedSegments.count))").font(.subheadline).bold()
                Picker("Boundary", selection: $boundaryChoice) {
                    Text("<None>").tag("<None>")
                    ForEach(doc.snapshot.boundaries) { b in Text(b.name).tag(b.name) }
                }
                .onChange(of: boundaryChoice) { _, v in
                    if !suppressWrite { doc.assignSegmentBoundary(v == "<None>" ? nil : v) }
                }
                LabeledContent("Max Side") {
                    TextField("", value: $maxSide, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .onSubmit { if !suppressWrite { doc.setSegmentMaxSide(maxSide) } }
                }
                Divider()
            }
            if hasLbls {
                Text("Selected Labels (\(doc.selectedLabels.count))").font(.subheadline).bold()
                Picker("Material", selection: $materialChoice) {
                    Text("<None>").tag("<None>")
                    ForEach(doc.snapshot.materials) { m in Text(m.name).tag(m.name) }
                }
                .onChange(of: materialChoice) { _, v in
                    if !suppressWrite { doc.assignLabelMaterial(v == "<None>" ? nil : v) }
                }
                Picker(circuitLabel, selection: $circuitChoice) {
                    Text("<None>").tag("<None>")
                    ForEach(doc.snapshot.circuits) { c in Text(c.name).tag(c.name) }
                }
                .onChange(of: circuitChoice) { _, v in
                    if !suppressWrite {
                        doc.assignLabelCircuit(v == "<None>" ? nil : v, turns: turns)
                    }
                }
                if doc.snapshot.physics == .magnetics {
                    LabeledContent("Turns") {
                        TextField("", value: $turns, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                            .onSubmit {
                                if !suppressWrite {
                                    doc.assignLabelCircuit(
                                        circuitChoice == "<None>" ? nil : circuitChoice,
                                        turns: turns)
                                }
                            }
                    }
                    LabeledContent("Mag Dir (deg)") {
                        TextField("", value: $magDir, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                            .onSubmit { if !suppressWrite { doc.setLabelMagDir(magDir) } }
                    }
                }
                LabeledContent("Max Area") {
                    TextField("", value: $maxArea, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                        .onSubmit { if !suppressWrite { doc.setLabelMaxArea(maxArea) } }
                }
            }
            if !hasNodes && !hasSegs && !hasLbls {
                Text("No selection — click nodes, segments, or labels to assign properties.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: syncFromSelection)
        .onChange(of: doc.selectedNodes) { _, _ in syncFromSelection() }
        .onChange(of: doc.selectedSegments) { _, _ in syncFromSelection() }
        .onChange(of: doc.selectedLabels) { _, _ in syncFromSelection() }
    }

    private var circuitLabel: String {
        doc.snapshot.physics == .magnetics ? "Circuit" : "Conductor"
    }
}
