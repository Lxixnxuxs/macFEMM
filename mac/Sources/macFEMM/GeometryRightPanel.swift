// GeometryRightPanel.swift — Collapsible macOS-style inspector and property libraries.

import SwiftUI

private enum GeometryRightTab: String, CaseIterable, Identifiable {
    case inspector
    case materials
    case boundaries
    case pointProps
    case circuits

    var id: String { rawValue }

    func title(for physics: Physics) -> String {
        switch self {
        case .inspector: return "Inspector"
        case .materials: return "Materials"
        case .boundaries: return "Boundaries"
        case .pointProps: return "Points"
        case .circuits: return physics == .magnetics ? "Circuits" : "Conductors"
        }
    }

    var symbol: String {
        switch self {
        case .inspector: return "sidebar.right"
        case .materials: return PropCategory.materials.symbol
        case .boundaries: return PropCategory.boundaries.symbol
        case .pointProps: return PropCategory.pointProps.symbol
        case .circuits: return PropCategory.circuits.symbol
        }
    }

    var category: PropCategory? {
        switch self {
        case .inspector: return nil
        case .materials: return .materials
        case .boundaries: return .boundaries
        case .pointProps: return .pointProps
        case .circuits: return .circuits
        }
    }
}

struct GeometryRightPanel: View {
    @ObservedObject var doc: FemmDocument
    @Binding var isExpanded: Bool
    @State private var tab: GeometryRightTab = .inspector
    @State private var railHovered = false

    var body: some View {
        Group {
            isExpanded ? AnyView(expandedPanel) : AnyView(collapsedRail)
        }
        .frame(width: isExpanded ? 328 : 34)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
    }

    private var collapsedRail: some View {
        VStack(spacing: 0) {
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded = true }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(railHovered ? Color(nsColor: .controlAccentColor).opacity(0.12) : .clear)
                    }
            }
            .buttonStyle(.plain)
            .help("Show Properties")
            .onHover { railHovered = $0 }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider()
            activeTab
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            tabStrip
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Text("Properties")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded = false }
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Hide Properties")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var tabStrip: some View {
        Picker("", selection: $tab) {
            ForEach(GeometryRightTab.allCases) { item in
                Text(item.title(for: doc.snapshot.physics)).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder private var activeTab: some View {
        switch tab {
        case .inspector:
            GeometrySelectionInspector(doc: doc)
        case .materials:
            PropertyCategoryPanel(doc: doc, category: .materials)
        case .boundaries:
            PropertyCategoryPanel(doc: doc, category: .boundaries)
        case .pointProps:
            PropertyCategoryPanel(doc: doc, category: .pointProps)
        case .circuits:
            PropertyCategoryPanel(doc: doc, category: .circuits)
        }
    }
}

private struct GeometrySelectionInspector: View {
    @ObservedObject var doc: FemmDocument

    @State private var materialChoice = "<None>"
    @State private var circuitChoice = "<None>"
    @State private var boundaryChoice = "<None>"
    @State private var conductorChoice = "<None>"
    @State private var segmentBoundaryChoice = "<None>"
    @State private var segmentConductorChoice = "<None>"
    @State private var turns: Int32 = 1
    @State private var maxArea: Double = 0
    @State private var magDir: Double = 0
    @State private var labelGroup: Int32 = 0
    @State private var labelExternal = false
    @State private var labelDefault = false
    @State private var segmentMaxSide: Double = -1
    @State private var segmentGroup: Int32 = 0
    @State private var segmentHidden = false
    @State private var arcMaxSide: Double = 1
    @State private var arcGroup: Int32 = 0
    @State private var arcHidden = false
    @State private var suppressWrite = false

    private var hasEditableSelection: Bool {
        !doc.selectedLabels.isEmpty || !doc.selectedSegments.isEmpty || !doc.selectedArcs.isEmpty
    }

    var body: some View {
        Group {
            if hasEditableSelection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !doc.selectedLabels.isEmpty { labelEditor }
                        if !doc.selectedSegments.isEmpty { segmentEditor }
                        if !doc.selectedArcs.isEmpty { arcEditor }
                    }
                    .padding(12)
                }
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
        }
        .onAppear(perform: syncFromSelection)
        .onChange(of: doc.selectedLabels) { _, _ in syncFromSelection() }
        .onChange(of: doc.selectedSegments) { _, _ in syncFromSelection() }
        .onChange(of: doc.selectedArcs) { _, _ in syncFromSelection() }
        .onChange(of: doc.snapshot) { _, _ in syncFromSelection() }
    }

    private var labelEditor: some View {
        inspectorSection(
            title: doc.selectedLabels.count == 1 ? "Region Label" : "Region Labels",
            subtitle: "\(doc.selectedLabels.count) selected",
            symbol: "tag"
        ) {
            Picker("Material", selection: $materialChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.materials) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: materialChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignLabelMaterial(value == "<None>" ? nil : value)
            }

            Picker(circuitLabel, selection: $circuitChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.circuits) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: circuitChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignLabelCircuit(value == "<None>" ? nil : value, turns: turns)
            }

            if doc.snapshot.physics == .magnetics {
                compactNumberField("Turns", value: $turns)
                    .onSubmit {
                        guard !suppressWrite else { return }
                        doc.assignLabelCircuit(circuitChoice == "<None>" ? nil : circuitChoice, turns: turns)
                    }
                compactNumberField("Mag Dir", value: $magDir, suffix: "deg")
                    .onSubmit {
                        guard !suppressWrite else { return }
                        doc.setLabelMagDir(magDir)
                    }
            }

            compactNumberField("Max Area", value: $maxArea)
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setLabelMaxArea(maxArea)
                }
            compactNumberField("Group", value: $labelGroup)
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setSelectedGroup(labelGroup)
                }

            Toggle("External Region", isOn: $labelExternal)
                .onChange(of: labelExternal) { _, value in
                    guard !suppressWrite else { return }
                    doc.setSelectedLabelExternal(value)
                }
            Toggle("Default Region", isOn: $labelDefault)
                .onChange(of: labelDefault) { _, value in
                    guard !suppressWrite else { return }
                    doc.setSelectedLabelDefault(value)
                }
        }
    }

    private var segmentEditor: some View {
        inspectorSection(
            title: doc.selectedSegments.count == 1 ? "Line" : "Lines",
            subtitle: "\(doc.selectedSegments.count) selected",
            symbol: "line.diagonal"
        ) {
            Picker("Boundary", selection: $segmentBoundaryChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.boundaries) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: segmentBoundaryChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignSegmentBoundary(value == "<None>" ? nil : value)
            }

            Picker(circuitLabel, selection: $segmentConductorChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.circuits) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: segmentConductorChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignSegmentConductor(value == "<None>" ? nil : value)
            }

            compactNumberField("Max Side", value: $segmentMaxSide)
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setSegmentMaxSide(segmentMaxSide)
                }
            compactNumberField("Group", value: $segmentGroup)
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setSelectedGroup(segmentGroup)
                }
            Toggle("Hidden", isOn: $segmentHidden)
                .onChange(of: segmentHidden) { _, value in
                    guard !suppressWrite else { return }
                    doc.setSelectedSegmentHidden(value)
                }
        }
    }

    private var arcEditor: some View {
        inspectorSection(
            title: doc.selectedArcs.count == 1 ? "Arc" : "Arcs",
            subtitle: "\(doc.selectedArcs.count) selected",
            symbol: "arc"
        ) {
            Picker("Boundary", selection: $boundaryChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.boundaries) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: boundaryChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignArcBoundary(value == "<None>" ? nil : value)
            }

            Picker(circuitLabel, selection: $conductorChoice) {
                Text("None").tag("<None>")
                ForEach(doc.snapshot.circuits) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .onChange(of: conductorChoice) { _, value in
                guard !suppressWrite else { return }
                doc.assignArcConductor(value == "<None>" ? nil : value)
            }

            compactNumberField("Max Side", value: $arcMaxSide, suffix: "deg")
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setArcMaxSideDeg(arcMaxSide)
                }
            compactNumberField("Group", value: $arcGroup)
                .onSubmit {
                    guard !suppressWrite else { return }
                    doc.setSelectedGroup(arcGroup)
                }
            Toggle("Hidden", isOn: $arcHidden)
                .onChange(of: arcHidden) { _, value in
                    guard !suppressWrite else { return }
                    doc.setSelectedArcHidden(value)
                }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Text("No Label or Line Selected")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func inspectorSection<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private func compactNumberField(_ title: String, value: Binding<Double>, suffix: String? = nil) -> some View {
        LabeledContent(title) {
            HStack(spacing: 5) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 92)
                if let suffix {
                    Text(suffix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compactNumberField(_ title: String, value: Binding<Int32>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)
        }
    }

    private func syncFromSelection() {
        suppressWrite = true
        defer { DispatchQueue.main.async { suppressWrite = false } }

        let snapshot = doc.snapshot
        if let idx = doc.selectedLabels.sorted().first,
           snapshot.labels.indices.contains(idx) {
            let label = snapshot.labels[idx]
            materialChoice = name(from: snapshot.materials, idx1: label.blockIdx) ?? "<None>"
            circuitChoice = name(from: snapshot.circuits, idx1: label.circuitIdx) ?? "<None>"
            turns = label.turns
            maxArea = label.maxArea
            magDir = label.magDir
            labelGroup = label.group
            labelExternal = label.isExternal
            labelDefault = label.isDefault
        }

        if let idx = doc.selectedSegments.sorted().first,
           snapshot.segments.indices.contains(idx) {
            let segment = snapshot.segments[idx]
            segmentBoundaryChoice = name(from: snapshot.boundaries, idx1: segment.bdryIdx) ?? "<None>"
            segmentConductorChoice = name(from: snapshot.circuits, idx1: segment.conductorIdx) ?? "<None>"
            segmentMaxSide = segment.maxSide
            segmentGroup = segment.group
            segmentHidden = segment.hidden
        }

        if let idx = doc.selectedArcs.sorted().first,
           snapshot.arcs.indices.contains(idx) {
            let arc = snapshot.arcs[idx]
            boundaryChoice = name(from: snapshot.boundaries, idx1: arc.bdryIdx) ?? "<None>"
            conductorChoice = name(from: snapshot.circuits, idx1: arc.conductorIdx) ?? "<None>"
            arcMaxSide = arc.maxSideDeg
            arcGroup = arc.group
            arcHidden = arc.hidden
        }
    }

    private func name(from entries: [DocSnapshot.PropEntry], idx1: Int32) -> String? {
        guard idx1 > 0 else { return nil }
        return entries.first(where: { $0.idx == idx1 - 1 })?.name
    }

    private var circuitLabel: String {
        doc.snapshot.physics == .magnetics ? "Circuit" : "Conductor"
    }
}

private struct PropertyCategoryPanel: View {
    @ObservedObject var doc: FemmDocument
    let category: PropCategory

    @State private var selectedIdx: Int32?
    @State private var editingIdx: Int32?
    @State private var creatingNew = false
    @State private var searchText = ""
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .padding(10)

            Divider()

            List(selection: $selectedIdx) {
                ForEach(filteredEntries) { entry in
                    PropertyEntryRow(entry: entry)
                        .tag(Optional(entry.idx))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editingIdx = entry.idx }
                }
            }
            .listStyle(.inset)
            .overlay {
                if filteredEntries.isEmpty {
                    Text(emptyText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                }
            }

            Divider()
            footer
        }
        .sheet(isPresented: Binding(
            get: { editingIdx != nil || creatingNew },
            set: { isPresented in
                if !isPresented {
                    editingIdx = nil
                    creatingNew = false
                }
            })
        ) {
            PropertyEditorSheet(doc: doc, category: category, editingIdx: editingIdx) {
                editingIdx = nil
                creatingNew = false
            }
        }
        .onChange(of: category) { _, _ in
            selectedIdx = nil
            searchText = ""
        }
        .onChange(of: doc.snapshot.physics) { _, _ in
            selectedIdx = nil
            searchText = ""
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Button { creatingNew = true } label: {
                Image(systemName: "plus")
            }
            .help("Add \(category.displayName(for: doc.snapshot.physics))")

            Button {
                if let selectedIdx { editingIdx = selectedIdx }
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(selectedIdx == nil)
            .help("Edit")

            Button {
                if let selectedIdx {
                    doc.deleteProp(kind: category.kind(), idx: selectedIdx)
                    self.selectedIdx = nil
                }
            } label: {
                Image(systemName: "trash")
            }
            .disabled(selectedIdx == nil)
            .help("Delete")

            Spacer()

            if hasLibrary {
                Button {
                    showLibrary.toggle()
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .popover(isPresented: $showLibrary, arrowEdge: .bottom) {
                    PropertyLibraryPopover(doc: doc, category: category)
                        .frame(width: 310, height: 360)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(8)
    }

    private var entries: [DocSnapshot.PropEntry] {
        switch category {
        case .materials: return doc.snapshot.materials
        case .boundaries: return doc.snapshot.boundaries
        case .pointProps: return doc.snapshot.pointProps
        case .circuits: return doc.snapshot.circuits
        }
    }

    private var filteredEntries: [DocSnapshot.PropEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasLibrary: Bool {
        category == .materials || category == .boundaries
    }

    private var emptyText: String {
        searchText.isEmpty
            ? "No \(category.displayName(for: doc.snapshot.physics).lowercased()) yet."
            : "No matches."
    }
}

private struct PropertyEntryRow: View {
    let entry: DocSnapshot.PropEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct PropertyLibraryPopover: View {
    @ObservedObject var doc: FemmDocument
    let category: PropCategory
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Library", systemImage: "books.vertical")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(12)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .padding(10)
            List(filteredPresets) { preset in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(preset.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        doc.importPreset(preset)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add to document")
                }
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            .overlay {
                if filteredPresets.isEmpty {
                    Text("No library entries.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var presets: [PropertyLibraryPreset] {
        PropertyLibraryStore.presets(for: doc.snapshot.physics, category: category)
    }

    private var filteredPresets: [PropertyLibraryPreset] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return presets }
        return presets.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query)
        }
    }
}
