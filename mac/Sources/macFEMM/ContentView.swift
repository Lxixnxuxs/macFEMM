// ContentView.swift — Main window: tool palette, canvas, analyze button,
// inspector, and solver log.

import SwiftUI
import AppKit
import FemmCore

struct ContentView: View {
    @StateObject var doc: FemmDocument
    @ObservedObject var appState: AppState
    @StateObject var solver = SolverRun()
    @State private var viewport = Viewport()
    @State private var tool: Tool = .select
    @StateObject private var geometryEditor = GeometryEditorState()
    @State private var showSavePanel = false
    @State private var showProblemSheet = false
    @State private var viewMode: ViewMode = .preprocessor
    @State private var plotSettings = PlotSettings()
    @State private var pointQuery: PointQuery?
    @State private var postTool: PostTool = .query
    @State private var logExpanded = false
    @State private var geometryPanelExpanded = false
    @StateObject private var luaConsole = LuaConsoleModel()
    @StateObject private var integralAnalysis = ResultIntegralAnalysisModel()
    @State private var luaConsoleWindow: LuaConsoleWindowController?
    @State private var lineIntegralWindow: ResultIntegralWindowController?
    @State private var blockIntegralWindow: ResultIntegralWindowController?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                Group {
                    if viewMode == .preprocessor {
                        CanvasView(doc: doc, viewport: $viewport, tool: $tool,
                                   editor: geometryEditor)
                    } else {
                        PostCanvasView(doc: doc, viewport: $viewport,
                                       settings: $plotSettings, query: $pointQuery,
                                       postTool: $postTool,
                                       integralAnalysis: integralAnalysis,
                                       openLineIntegrals: openLineIntegrals,
                                       openBlockIntegrals: openBlockIntegrals)
                    }
                }
                .frame(minWidth: 500, idealWidth: 1130, minHeight: 300)
                if viewMode == .preprocessor {
                    GeometryRightPanel(doc: doc, isExpanded: $geometryPanelExpanded)
                }
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

            ToolbarItemGroup(placement: .primaryAction) {
                Button { openLuaConsole() } label: {
                    Label("Lua Console", systemImage: "terminal")
                        .labelStyle(.iconOnly)
                }
                .help("Open Lua Console")

                Button { showProblemSheet = true } label: {
                    Label("Simulation Settings", systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .help("Simulation Settings")

                Button {
                    analyze()
                } label: {
                    if solver.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(solver.running)
                .help("Run Solver")
            }
        }
        .onKeyPress(.delete) {
            doc.deleteSelected()
            return .handled
        }
        .onAppear {
            fitOnce()
            syncCommandContext()
        }
        .sheet(isPresented: $showProblemSheet) {
            ProblemDefinitionForm(doc: doc) { showProblemSheet = false }
        }
        .onChange(of: viewMode) { _, _ in syncCommandContext() }
        .onChange(of: postTool) { _, _ in syncCommandContext() }
        .onChange(of: doc.canUndo) { _, _ in syncCommandContext() }
        .onChange(of: doc.contour.count) { _, _ in syncCommandContext() }
        .onChange(of: doc.result.isEmpty) { _, isEmpty in
            if !isEmpty { viewMode = .postprocessor }
            if isEmpty && viewMode == .postprocessor { viewMode = .preprocessor }
            syncCommandContext()
        }
        .onChange(of: tool) { _, _ in
            geometryEditor.cancelTransientTools()
        }
        .onChange(of: doc.snapshot.physics) { _, physics in
            integralAnalysis.resetForPhysics(physics)
        }
    }

    private var titleText: String {
        let base = doc.fileURL?.lastPathComponent ?? "Untitled.\(doc.snapshot.physics.fileExt)"
        return doc.isDirty ? "• " + base : base
    }

    private func syncCommandContext() {
        let contourUndo = viewMode == .postprocessor && postTool == .contour && !doc.contour.isEmpty
        appState.updateCommandContext(viewMode: viewMode,
                                      postTool: postTool,
                                      canUndo: doc.canUndo || contourUndo)
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

    private func openLineIntegrals() {
        postTool = .contour
        if lineIntegralWindow == nil {
            lineIntegralWindow = ResultIntegralWindowController(kind: .line,
                                                                analysis: integralAnalysis)
        }
        integralAnalysis.computeLine(doc: doc)
        lineIntegralWindow?.show()
    }

    private func openBlockIntegrals() {
        postTool = .region
        if blockIntegralWindow == nil {
            blockIntegralWindow = ResultIntegralWindowController(kind: .block,
                                                                 analysis: integralAnalysis)
        }
        integralAnalysis.computeBlock(doc: doc)
        blockIntegralWindow?.show()
    }
}
