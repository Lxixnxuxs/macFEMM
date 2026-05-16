// ContentView.swift — Main window: tool palette, canvas, analyze button,
// inspector, and solver log.

import SwiftUI
import AppKit
import FemmCore

struct ContentView: View {
    @StateObject var doc: FemmDocument
    @StateObject var solver = SolverRun()
    @State private var viewport = Viewport()
    @State private var tool: Tool = .select
    @State private var pendingSegStart: Int32?
    @State private var showSavePanel = false
    @State private var showProblemSheet = false
    @State private var viewMode: ViewMode = .preprocessor
    @State private var plotSettings = PlotSettings()
    @State private var pointQuery: PointQuery?
    @State private var postTool: PostTool = .query
    @State private var logExpanded = false
    @StateObject private var luaConsole = LuaConsoleModel()
    @State private var luaConsoleWindow: LuaConsoleWindowController?

    var body: some View {
        VStack(spacing: 0) {
            toolbarBar
            Divider()
            HSplitView {
                Group {
                    if viewMode == .preprocessor {
                        CanvasView(doc: doc, viewport: $viewport, tool: $tool,
                                   pendingSegmentStart: $pendingSegStart)
                    } else {
                        PostCanvasView(doc: doc, viewport: $viewport,
                                       settings: $plotSettings, query: $pointQuery,
                                       postTool: $postTool)
                    }
                }
                .frame(minWidth: 500, idealWidth: 1130, minHeight: 300)
                VSplitView {
                    if viewMode == .preprocessor {
                        inspector.frame(minHeight: 180, idealHeight: 220)
                        PropertyBrowser(doc: doc).frame(minHeight: 200)
                    } else {
                        PostProcessorPanel(doc: doc, settings: $plotSettings,
                                           query: $pointQuery, postTool: $postTool)
                            .frame(minHeight: 400)
                    }
                }
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 500)
            }
            if logExpanded {
                Divider()
                logPane.frame(height: 180)
            }
            Divider()
            footerBar
        }
        .navigationTitle(titleText)
        .toolbar {
            if !doc.result.isEmpty {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $viewMode) {
                        ForEach(ViewMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
            }
        }
        .onKeyPress(.delete) {
            doc.deleteSelected()
            return .handled
        }
        .onAppear { fitOnce() }
        .sheet(isPresented: $showProblemSheet) {
            ProblemDefinitionForm(doc: doc) { showProblemSheet = false }
        }
        .onChange(of: doc.result.isEmpty) { _, isEmpty in
            if !isEmpty { viewMode = .postprocessor }
            if isEmpty && viewMode == .postprocessor { viewMode = .preprocessor }
        }
    }

    private var titleText: String {
        let base = doc.fileURL?.lastPathComponent ?? "Untitled.\(doc.snapshot.physics.fileExt)"
        return doc.isDirty ? "• " + base : base
    }

    private var toolbarBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)

            Spacer()

            Button("Open LUA Console") { openLuaConsole() }

            Button("Simulation Settings") { showProblemSheet = true }

            Button {
                analyze()
            } label: {
                if solver.running {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Run", systemImage: "play.fill")
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(solver.running)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Label("Document", systemImage: "doc").font(.headline)
                LabeledContent("Physics", value: doc.snapshot.physics.displayName)
                LabeledContent("Nodes",    value: "\(doc.snapshot.nodes.count)")
                LabeledContent("Segments", value: "\(doc.snapshot.segments.count)")
                LabeledContent("Arcs",     value: "\(doc.snapshot.arcs.count)")
                LabeledContent("Labels",   value: "\(doc.snapshot.labels.count)")
                Divider()
                Label("Selection", systemImage: "selection.pin.in.out").font(.headline)
                LabeledContent("Nodes", value: "\(doc.selectedNodes.count)")
                LabeledContent("Segments", value: "\(doc.selectedSegments.count)")
                LabeledContent("Labels", value: "\(doc.selectedLabels.count)")
                if !doc.selectedNodes.isEmpty || !doc.selectedSegments.isEmpty || !doc.selectedLabels.isEmpty {
                    Button(role: .destructive) { doc.deleteSelected() } label: {
                        Label("Delete Selected", systemImage: "trash")
                    }
                }
                Divider()
                SelectedPropertyInspector(doc: doc)
                Divider()
                Text("Tip: click to place nodes; in *Add Segment* mode, two clicks create a segment (snaps to nearby nodes within 14 px). Option+drag pans.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(solver.log.isEmpty ? "Solver log appears here." : solver.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
                    .id("logEnd")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: solver.log) { _, _ in
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }

    private var footerBar: some View {
        let lastLine = solver.log
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init) ?? "Ready"
        return HStack(spacing: 6) {
            Image(systemName: logExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if solver.running {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(lastLine)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
            Spacer()
            Text(logExpanded ? "Hide Log" : "Show Log")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { logExpanded.toggle() }
        }
        .help(logExpanded ? "Hide solver log" : "Show solver log")
    }

    // MARK: - Actions
    private func fitView() {
        guard let b = doc.bounds else { return }
        let w = max(b.max.x - b.min.x, 1e-6)
        let h = max(b.max.y - b.min.y, 1e-6)
        viewport.center = CGPoint(x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2)
        viewport.scale = min(700 / (w * 1.2), 450 / (h * 1.2))
    }

    private func fitOnce() {
        // If we loaded a file with geometry, fit the view to it.
        if !doc.snapshot.nodes.isEmpty { fitView() }
    }

    private func analyze() {
        // Pick a stable scratch path next to the document (or tmp).
        let base: URL
        if let url = doc.fileURL {
            base = url.deletingPathExtension()
        } else {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("femm_scratch_\(Int.random(in: 0...Int.max))")
        }
        solver.run(doc: doc, tempPath: base.path)
    }

    private func openLuaConsole() {
        if luaConsoleWindow == nil {
            luaConsoleWindow = LuaConsoleWindowController(model: luaConsole)
        }
        luaConsoleWindow?.show(document: doc)
    }
}
