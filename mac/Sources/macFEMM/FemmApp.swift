// FemmApp.swift — Entry point. One window per document.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct FemmApp: App {
    @StateObject private var appState = AppState()

    init() {
        // `swift run` launches an unbundled binary; force it to be a regular
        // foreground GUI app so text fields can receive key events.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            RootView(appState: appState)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.async {
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { appState.document?.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(appState.document?.canUndo != true)
            }
            CommandGroup(replacing: .newItem) {
                Menu("New") {
                    Button("Magnetics Problem") { appState.new(.magnetics) }
                        .keyboardShortcut("n", modifiers: [.command])
                    Button("Electrostatics Problem") { appState.new(.electrostatics) }
                    Button("Heat Flow Problem") { appState.new(.heat) }
                    Button("Current Flow Problem") { appState.new(.current) }
                }
                Button("Open…") { appState.openDialog() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { appState.saveCurrent() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(appState.document == nil)
            }
        }
    }
}

final class AppState: ObservableObject {
    @Published var document: FemmDocument?

    init() {
        // Point libfemm_core at the solver binaries bundled inside the .app,
        // unless the environment has already set FEMM_BIN. Dev builds running
        // from `swift build` (no bundle) fall through to the upward walk for
        // build/ that libfemm_core does on its own.
        if getenv("FEMM_BIN") == nil {
            let macOS = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
            if FileManager.default.fileExists(atPath: macOS.path) {
                setenv("FEMM_BIN", macOS.path, 1)
            }
        }
        // Default: a fresh magnetics doc so the window isn't empty.
        document = FemmDocument(physics: .magnetics)
    }

    func new(_ physics: Physics) {
        document = FemmDocument(physics: physics)
    }

    func openDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let exts = ["fem", "fee", "feh", "fec"]
        panel.allowedContentTypes = exts.compactMap {
            UTType(filenameExtension: $0)
        }
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func saveCurrent() {
        guard let doc = document else { return }
        if let url = doc.fileURL {
            try? doc.save(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "Untitled.\(doc.snapshot.physics.fileExt)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? doc.save(to: url)
        }
    }

    func open(url: URL) {
        do {
            let d = try FemmDocument(url: url)
            document = d
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}

struct RootView: View {
    @ObservedObject var appState: AppState
    var body: some View {
        if let d = appState.document {
            ContentView(doc: d).id(ObjectIdentifier(d))
        } else {
            Text("No document").foregroundStyle(.secondary)
        }
    }
}
