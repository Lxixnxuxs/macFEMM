import SwiftUI
import AppKit
import FemmCore

final class LuaConsoleModel: ObservableObject {
    weak var document: FemmDocument?
    private var session: OpaquePointer?

    @Published var input: String = ""
    @Published var output: String = ""

    init() {
        var out: OpaquePointer?
        if femm_lua_session_new(&out) == FEMM_OK {
            session = out
        } else {
            output = String(cString: femm_last_error_message())
        }
    }

    deinit {
        if let session { femm_lua_session_free(session) }
    }

    func evaluate() {
        run(input, clearInputOnSuccess: false)
    }

    func clearInput() {
        input = ""
    }

    func clearOutput() {
        guard let session else {
            output = ""
            return
        }
        femm_lua_clear_output(session)
        output = ""
    }

    func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "lua")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let session, let document else { return }
        setActive(session: session, document: document)
        let status = url.path.withCString { femm_lua_eval_file(session, $0) }
        finish(status: status, session: session, document: document)
    }

    private func run(_ code: String, clearInputOnSuccess: Bool) {
        guard let session else { return }
        guard let document else {
            output += "No active document.\n"
            return
        }
        setActive(session: session, document: document)
        let status = code.withCString { femm_lua_eval(session, $0) }
        finish(status: status, session: session, document: document)
        if status == FEMM_OK && clearInputOnSuccess { input = "" }
    }

    private func setActive(session: OpaquePointer, document: FemmDocument) {
        if let path = document.fileURL?.path {
            path.withCString {
                femm_lua_session_set_active(session, document.raw, document.rawResult, $0)
            }
        } else {
            femm_lua_session_set_active(session, document.raw, document.rawResult, nil)
        }
    }

    private func finish(status: femm_status_t, session: OpaquePointer, document: FemmDocument) {
        var newDoc: OpaquePointer?
        var physics = FEMM_PHYSICS_MAGNETICS
        var docPath: UnsafePointer<CChar>?
        if femm_lua_take_replacement_doc(session, &newDoc, &physics, &docPath) != 0, let newDoc {
            let path = docPath.map { String(cString: $0) }
            document.adoptLuaDocument(newDoc, path: path)
        }

        var newResult: OpaquePointer?
        var resultPath: UnsafePointer<CChar>?
        if femm_lua_take_replacement_result(session, &newResult, &resultPath) != 0, let newResult {
            document.adoptLuaResult(newResult)
        }

        if let text = femm_lua_output(session) {
            output = String(cString: text)
        }

        if status == FEMM_OK {
            document.refreshAfterLuaEvaluation()
        } else if let error = femm_lua_error(session), error.pointee != 0 {
            let message = String(cString: error)
            if !message.isEmpty {
                output += "--> \(message)\n"
            }
        }
    }
}

struct LuaConsolePanel: View {
    @ObservedObject var model: LuaConsoleModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output.isEmpty ? "" : model.output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                        .id("lua-output-end")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: model.output) { _, _ in
                    proxy.scrollTo("lua-output-end", anchor: .bottom)
                }
            }
            .frame(minHeight: 220)

            Divider()

            TextEditor(text: $model.input)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 110, idealHeight: 140)
                .padding(6)

            Divider()

            HStack(spacing: 8) {
                Button("Evaluate") { model.evaluate() }
                    .keyboardShortcut(.return, modifiers: [.command])
                Button("Clear Input") { model.clearInput() }
                Button("Clear Output") { model.clearOutput() }
                Spacer()
                Button("Open Script") { model.openScript() }
            }
            .padding(10)
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

final class LuaConsoleWindowController: NSObject, NSWindowDelegate {
    private let model: LuaConsoleModel
    private var panel: NSPanel?

    init(model: LuaConsoleModel) {
        self.model = model
        super.init()
    }

    func show(document: FemmDocument) {
        model.document = document
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "LUA Console"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: LuaConsolePanel(model: model))
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
