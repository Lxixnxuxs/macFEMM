// ResultIntegralWindows.swift — live integral controls + result panels.

import SwiftUI
import AppKit
import FemmCore

enum BlockIntegralScope: String, CaseIterable, Identifiable {
    case selected = "Selected"
    case all = "All"
    var id: String { rawValue }
}

enum IntegralResultKind {
    case line
    case block
}

final class ResultIntegralAnalysisModel: ObservableObject {
    @Published var lineType: Int32 = 0
    @Published var lineSamples: Int32 = 400
    @Published private(set) var lineResults: [IntegralResult] = []
    @Published private(set) var lineError: String?

    @Published var blockType: Int32 = 0
    @Published var blockScope: BlockIntegralScope = .selected
    @Published private(set) var blockResults: [IntegralResult] = []
    @Published private(set) var blockError: String?

    func resetForPhysics(_ physics: Physics) {
        lineType = lineTypes(for: physics).first?.id ?? 0
        blockType = blockTypes(for: physics).first?.id ?? 0
        lineResults.removeAll()
        blockResults.removeAll()
        lineError = nil
        blockError = nil
    }

    func computeLine(doc: FemmDocument) {
        lineError = nil
        guard let type = lineTypes(for: doc.snapshot.physics).first(where: { $0.id == lineType }) else { return }
        guard doc.contour.count >= 2 else {
            lineResults.removeAll()
            lineError = "Add at least two contour points."
            return
        }
        do {
            let values: [femm_complex_t]
            switch doc.snapshot.physics {
            case .magnetics:      values = try doc.magLineIntegral(type: lineType, samples: lineSamples)
            case .electrostatics: values = try doc.esLineIntegral(type: lineType, samples: lineSamples)
            case .heat:           values = try doc.heatLineIntegral(type: lineType, samples: lineSamples)
            case .current:        values = try doc.currLineIntegral(type: lineType, samples: lineSamples)
            }
            lineResults = lineIntegralRows(physics: doc.snapshot.physics, type: type, values: values)
        } catch {
            lineResults.removeAll()
            lineError = error.localizedDescription
        }
    }

    func computeBlock(doc: FemmDocument) {
        blockError = nil
        guard let type = blockTypes(for: doc.snapshot.physics).first(where: { $0.id == blockType }) else { return }
        let labels = blockScope == .all ? Set<Int>() : doc.selectedLabels
        guard blockScope == .all || !labels.isEmpty else {
            blockResults.removeAll()
            blockError = "Select regions or switch scope to All."
            return
        }
        do {
            let value: femm_complex_t
            switch doc.snapshot.physics {
            case .magnetics:
                value = try doc.magBlockIntegral(type: blockType, labelIndices: labels)
            case .electrostatics:
                value = try doc.esBlockIntegral(type: blockType, labelIndices: labels)
            case .heat:
                value = try doc.heatBlockIntegral(type: blockType, labelIndices: labels)
            case .current:
                value = try doc.currBlockIntegral(type: blockType, labelIndices: labels)
            }
            let scope = blockScope == .all ? "all regions" : "\(labels.count) selected"
            blockResults = [.init(label: "\(type.name) (\(scope))",
                                  value: fmtIntegralComplex(value),
                                  unit: type.unit0)]
        } catch {
            blockResults.removeAll()
            blockError = error.localizedDescription
        }
    }

    func clear(_ kind: IntegralResultKind) {
        switch kind {
        case .line:
            lineResults.removeAll()
            lineError = nil
        case .block:
            blockResults.removeAll()
            blockError = nil
        }
    }

    func results(for kind: IntegralResultKind) -> [IntegralResult] {
        switch kind {
        case .line: return lineResults
        case .block: return blockResults
        }
    }

    func error(for kind: IntegralResultKind) -> String? {
        switch kind {
        case .line: return lineError
        case .block: return blockError
        }
    }
}

struct ResultIntegralToolbar: View {
    @ObservedObject var doc: FemmDocument
    @ObservedObject var analysis: ResultIntegralAnalysisModel
    let postTool: PostTool
    var openResults: (IntegralResultKind) -> Void
    @State private var copiedResultID: UUID?

    var body: some View {
        switch postTool {
        case .contour:
            lineToolbar
        case .region:
            blockToolbar
        case .query:
            EmptyView()
        }
    }

    private var lineToolbar: some View {
        HStack(spacing: 10) {
            Label("Line Integral", systemImage: "sum")
                .font(.caption.weight(.semibold))
            Picker("Type", selection: $analysis.lineType) {
                ForEach(lineTypes(for: doc.snapshot.physics)) { type in
                    Text(type.name).tag(type.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            Stepper("Samples \(analysis.lineSamples)",
                    value: $analysis.lineSamples, in: 20...4000, step: 20)
                .frame(width: 150)
            Divider().frame(height: 20)
            statusText(kind: .line, fallback: "\(doc.contour.count) contour points")
            Spacer(minLength: 8)
            Button {
                doc.contourRemoveLast()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Undo Last Contour Point")
            .disabled(doc.contour.isEmpty)
            Button(role: .destructive) {
                doc.contourClear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear Contour")
            .disabled(doc.contour.isEmpty)
            Button {
                openResults(.line)
            } label: {
                Label("Results", systemImage: "macwindow")
            }
        }
        .onAppear { ensureLineType(); analysis.computeLine(doc: doc) }
        .onChange(of: doc.snapshot.physics) { _, physics in
            analysis.resetForPhysics(physics)
            analysis.computeLine(doc: doc)
        }
        .onChange(of: analysis.lineType) { _, _ in analysis.computeLine(doc: doc) }
        .onChange(of: analysis.lineSamples) { _, _ in analysis.computeLine(doc: doc) }
        .onChange(of: contourSignature) { _, _ in analysis.computeLine(doc: doc) }
        .modifier(IntegralBottomBarStyle())
    }

    private var blockToolbar: some View {
        HStack(spacing: 10) {
            Label("Block Integral", systemImage: "square.stack.3d.up")
                .font(.caption.weight(.semibold))
            Picker("Type", selection: $analysis.blockType) {
                ForEach(blockTypes(for: doc.snapshot.physics)) { type in
                    Text(type.name).tag(type.id)
                }
            }
            .labelsHidden()
            .frame(width: 210)
            Picker("Scope", selection: $analysis.blockScope) {
                ForEach(BlockIntegralScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 128)
            Divider().frame(height: 20)
            statusText(kind: .block, fallback: "\(doc.selectedLabels.count) selected")
            Spacer(minLength: 8)
            Button {
                doc.selectedLabels = Set(doc.snapshot.labels.indices)
                analysis.blockScope = .selected
            } label: {
                Image(systemName: "checklist.checked")
            }
            .buttonStyle(.borderless)
            .help("Select All Region Labels")
            .disabled(doc.snapshot.labels.isEmpty)
            Button(role: .destructive) {
                doc.selectedLabels = []
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Clear Region Selection")
            .disabled(doc.selectedLabels.isEmpty)
            Button {
                openResults(.block)
            } label: {
                Label("Results", systemImage: "macwindow")
            }
        }
        .onAppear { ensureBlockType(); analysis.computeBlock(doc: doc) }
        .onChange(of: doc.snapshot.physics) { _, physics in
            analysis.resetForPhysics(physics)
            analysis.computeBlock(doc: doc)
        }
        .onChange(of: analysis.blockType) { _, _ in analysis.computeBlock(doc: doc) }
        .onChange(of: analysis.blockScope) { _, _ in analysis.computeBlock(doc: doc) }
        .onChange(of: selectedLabelsSignature) { _, _ in analysis.computeBlock(doc: doc) }
        .modifier(IntegralBottomBarStyle())
    }

    @ViewBuilder private func statusText(kind: IntegralResultKind, fallback: String) -> some View {
        if let error = analysis.error(for: kind) {
            Text(error)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else {
            let rows = analysis.results(for: kind)
            if !rows.isEmpty {
                HStack(spacing: 18) {
                    ForEach(rows.prefix(3)) { row in
                        integralValueButton(row)
                    }
                }
                .lineLimit(1)
                .layoutPriority(1)
            } else {
                Text(fallback)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func integralValueButton(_ row: IntegralResult) -> some View {
        let copied = copiedResultID == row.id
        return Button {
            copyIntegralValue(row)
            withAnimation(.spring(response: 0.22, dampingFraction: 0.62)) {
                copiedResultID = row.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                guard copiedResultID == row.id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    copiedResultID = nil
                }
            }
        } label: {
            Text(integralDisplay(row))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
            .background {
                if copied {
                    Capsule(style: .continuous)
                        .fill(Color.green.opacity(0.18))
                        .transition(.opacity.combined(with: .scale(scale: 0.88)))
                }
            }
            .overlay {
                if copied {
                    Capsule(style: .continuous)
                        .stroke(Color.green.opacity(0.55), lineWidth: 0.5)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.green)
                        .offset(x: 8, y: -7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(copied ? 1.03 : 1.0)
        .help("Copy \(row.label)")
    }

    private func integralDisplay(_ row: IntegralResult) -> String {
        let unit = row.unit.isEmpty ? "" : " \(row.unit)"
        return "\(row.label): \(row.value)\(unit)"
    }

    private var contourSignature: String {
        doc.contour.map { "\(Double($0.x)):\(Double($0.y))" }.joined(separator: "|")
    }

    private var selectedLabelsSignature: String {
        doc.selectedLabels.sorted().map(String.init).joined(separator: ",")
    }

    private func ensureLineType() {
        let types = lineTypes(for: doc.snapshot.physics)
        if !types.contains(where: { $0.id == analysis.lineType }) {
            analysis.lineType = types.first?.id ?? 0
        }
    }

    private func ensureBlockType() {
        let types = blockTypes(for: doc.snapshot.physics)
        if !types.contains(where: { $0.id == analysis.blockType }) {
            analysis.blockType = types.first?.id ?? 0
        }
    }
}

private struct IntegralBottomBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 4)
    }
}

struct IntegralResultsPanel: View {
    let title: String
    let kind: IntegralResultKind
    @ObservedObject var analysis: ResultIntegralAnalysisModel
    var setPinned: (Bool) -> Void
    @State private var pinned = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: kind == .line ? "sum" : "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Toggle(isOn: $pinned) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .help(pinned ? "Unpin Window" : "Pin Window")
            }
            if let error = analysis.error(for: kind) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            resultList
            HStack {
                Button("Copy CSV") { copyIntegralRowsCSV(analysis.results(for: kind)) }
                    .disabled(analysis.results(for: kind).isEmpty)
                Button("Clear") { analysis.clear(kind) }
                    .disabled(analysis.results(for: kind).isEmpty)
                Spacer()
            }
        }
        .padding(14)
        .frame(minWidth: 360, minHeight: 240)
        .onAppear { setPinned(pinned) }
        .onChange(of: pinned) { _, value in setPinned(value) }
    }

    @ViewBuilder private var resultList: some View {
        let rows = analysis.results(for: kind)
        if rows.isEmpty {
            Text("No result yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        integralResultRow(row)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

final class ResultIntegralWindowController: NSObject, NSWindowDelegate {
    private let kind: IntegralResultKind
    private let analysis: ResultIntegralAnalysisModel
    private var panel: NSPanel?

    init(kind: IntegralResultKind, analysis: ResultIntegralAnalysisModel) {
        self.kind = kind
        self.analysis = analysis
        super.init()
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            let title = kind == .line ? "Line Integral Results" : "Block Integral Results"
            panel.title = title
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: IntegralResultsPanel(title: title,
                                                                             kind: kind,
                                                                             analysis: analysis,
                                                                             setPinned: { [weak panel] pinned in
                panel?.isFloatingPanel = pinned
            }))
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

func lineTypes(for physics: Physics) -> [IntegralType] {
    switch physics {
    case .magnetics:      return magLineTypes
    case .electrostatics: return esLineTypes
    case .heat:           return heatLineTypes
    case .current:        return currLineTypes
    }
}

func blockTypes(for physics: Physics) -> [IntegralType] {
    switch physics {
    case .magnetics:      return magBlockTypes
    case .electrostatics: return esBlockTypes
    case .heat:           return heatBlockTypes
    case .current:        return currBlockTypes
    }
}

@ViewBuilder
private func integralResultRow(_ row: IntegralResult) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.label)
            .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(row.value)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        Text(row.unit)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(minWidth: 42, alignment: .leading)
    }
    .font(.caption)
    .padding(.vertical, 2)
}

private func lineIntegralRows(physics: Physics,
                              type: IntegralType,
                              values: [femm_complex_t]) -> [IntegralResult] {
    if type.name == "Length", let z = values.first {
        return [
            .init(label: "Contour length", value: String(format: "%.6g", z.re), unit: type.unit0),
            .init(label: "Swept area / volume", value: String(format: "%.6g", z.im), unit: type.unit1 ?? "")
        ]
    }
    let labels = lineIntegralComponentLabels(physics: physics, typeID: type.id)
    return values.enumerated().map { i, z in
        let label = i < labels.count ? labels[i].0 : "\(type.name) [\(i)]"
        let unit = i < labels.count ? labels[i].1 : (i == 0 ? type.unit0 : (type.unit1 ?? ""))
        return .init(label: label, value: fmtIntegralComplex(z), unit: unit)
    }
}

private func lineIntegralComponentLabels(physics: Physics,
                                         typeID: Int32) -> [(String, String)] {
    switch physics {
    case .magnetics:
        switch typeID {
        case 0: return [("Flux", "Wb"), ("Average B.n", "T")]
        case 1: return [("MMF drop", "A"), ("Average H.t", "A/m")]
        case 3: return [("Force x", "N"), ("Force y", "N")]
        case 4: return [("Torque", "N.m")]
        case 5: return [("Integral (B.n)^2", "T^2.m"), ("Average (B.n)^2", "T^2")]
        default: return []
        }
    case .electrostatics:
        switch typeID {
        case 0: return [("Voltage drop", "V"), ("Average E.t", "V/m")]
        case 1: return [("Charge", "C"), ("Average D.n", "C/m^2")]
        default: return []
        }
    case .heat:
        switch typeID {
        case 0: return [("Temperature drop", "K")]
        case 1: return [("Heat flux", "W")]
        case 3: return [("Average temperature", "K")]
        default: return []
        }
    case .current:
        switch typeID {
        case 0: return [("Voltage drop", "V"), ("Average E.t", "V/m")]
        case 1: return [("Current", "A")]
        default: return []
        }
    }
}

private func fmtIntegralComplex(_ z: femm_complex_t) -> String {
    if z.im == 0 { return String(format: "%.6g", z.re) }
    return String(format: "%.6g%+.6gj", z.re, z.im)
}

private func copyIntegralValue(_ row: IntegralResult) {
    let value = row.unit.isEmpty ? row.value : "\(row.value) \(row.unit)"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func copyIntegralRowsCSV(_ rows: [IntegralResult]) {
    var buf = "label,value,unit\n"
    for row in rows {
        let esc = row.label.replacingOccurrences(of: "\"", with: "\"\"")
        buf += "\"\(esc)\",\(row.value),\(row.unit)\n"
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(buf, forType: .string)
}
