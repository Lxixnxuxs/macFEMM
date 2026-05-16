// PropertyBrowser.swift — Browser sidebar + per-physics property editor sheets.
//
// The browser is physics-agnostic: it lists Materials / Boundaries / Point
// Properties / Circuits|Conductors, supports Add / Duplicate / Delete, and
// opens the appropriate editor sheet. Each editor round-trips the full C
// struct (no lossy display-only fields).

import SwiftUI
import FemmCore

enum PropCategory: String, CaseIterable, Identifiable {
    case materials = "Materials"
    case boundaries = "Boundaries"
    case pointProps = "Point Properties"
    case circuits = "Circuits"
    var id: String { rawValue }
    func displayName(for p: Physics) -> String {
        switch (self, p) {
        case (.circuits, .magnetics): return "Circuits"
        case (.circuits, _):          return "Conductors"
        default: return rawValue
        }
    }
    func kind() -> FemmDocument.PropKind {
        switch self {
        case .materials:  return .materials
        case .boundaries: return .boundaries
        case .pointProps: return .pointProps
        case .circuits:   return .circuits
        }
    }
}

struct PropertyBrowser: View {
    @ObservedObject var doc: FemmDocument
    @State private var category: PropCategory = .materials
    @State private var selectedIdx: Int32?
    @State private var editingIdx: Int32?
    @State private var creatingNew: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $category) {
                ForEach(PropCategory.allCases) { c in
                    Text(c.displayName(for: doc.snapshot.physics)).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()
            list
            Divider()
            footer
        }
        .sheet(isPresented: Binding(
            get: { editingIdx != nil || creatingNew },
            set: { newVal in
                if !newVal { editingIdx = nil; creatingNew = false }
            })
        ) {
            editorSheet
        }
    }

    private var list: some View {
        let items = entries()
        return List(selection: $selectedIdx) {
            ForEach(items) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name).font(.callout).fontWeight(.medium)
                    Text(e.summary).font(.caption).foregroundStyle(.secondary)
                }
                .tag(Optional(e.idx))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editingIdx = e.idx }
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty {
                Text("No \(category.displayName(for: doc.snapshot.physics).lowercased()) defined.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button { creatingNew = true } label: { Image(systemName: "plus") }
            Button {
                if let idx = selectedIdx { editingIdx = idx }
            } label: { Image(systemName: "pencil") }
                .disabled(selectedIdx == nil)
            Button {
                if let idx = selectedIdx {
                    doc.deleteProp(kind: category.kind(), idx: idx)
                    selectedIdx = nil
                }
            } label: { Image(systemName: "minus") }
                .disabled(selectedIdx == nil)
            Spacer()
            Text("\(entries().count) item(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }

    private func entries() -> [DocSnapshot.PropEntry] {
        switch category {
        case .materials:  return doc.snapshot.materials
        case .boundaries: return doc.snapshot.boundaries
        case .pointProps: return doc.snapshot.pointProps
        case .circuits:   return doc.snapshot.circuits
        }
    }

    @ViewBuilder private var editorSheet: some View {
        let idx = editingIdx
        PropertyEditorSheet(doc: doc, category: category, editingIdx: idx) {
            editingIdx = nil
            creatingNew = false
        }
    }
}

// MARK: - Editor sheet dispatcher

struct PropertyEditorSheet: View {
    @ObservedObject var doc: FemmDocument
    let category: PropCategory
    let editingIdx: Int32?          // nil == create new
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch (category, doc.snapshot.physics) {
            case (.materials, .magnetics):
                MagMaterialEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.boundaries, .magnetics):
                MagBoundaryEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.pointProps, .magnetics):
                MagPointEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.circuits, .magnetics):
                MagCircuitEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.materials, .electrostatics):
                ESMaterialEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.boundaries, .electrostatics):
                ESBoundaryEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.pointProps, .electrostatics):
                ESPointEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.circuits, .electrostatics):
                ESConductorEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.materials, .heat):
                HeatMaterialEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.boundaries, .heat):
                HeatBoundaryEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.pointProps, .heat):
                HeatPointEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.circuits, .heat):
                HeatConductorEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.materials, .current):
                CurrMaterialEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.boundaries, .current):
                CurrBoundaryEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.pointProps, .current):
                CurrPointEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            case (.circuits, .current):
                CurrConductorEditor(doc: doc, editingIdx: editingIdx, onDismiss: onDismiss)
            }
        }
        .frame(minWidth: 440)
        .padding(16)
    }
}
